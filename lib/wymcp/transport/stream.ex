defmodule Wymcp.Transport.Stream do
  @moduledoc """
  The chunked SSE connection for one session, run as a receive loop by the
  GET request process that owns its socket; one active stream per session —
  a new GET replaces the old.

  ## Design decisions

  Every chunk write happens in the request process, because real adapters
  enforce socket ownership: Bandit raises when any process other than the
  request's own calls `Plug.Conn.chunk/2` (Plug.Test has no such check,
  which is how a separate writer process ever appeared to work). The stream
  is still a separate process from `Wymcp.Session` — the session must keep
  serving POSTs while the stream blocks — but that process is the GET
  request process itself, so the conn is never handed over.

  `serve/3` runs the stream's whole lifetime: register with the session,
  commit the 200, send the *priming event*, then serve pushes, keepalives,
  and replacement from the receive loop until the stream ends — the client
  disconnects (a chunk write fails), the session dies (monitored), or a new
  GET replaces this one. The final conn travels back up the plug stack like
  any other response. A registration failure answers `{:error,
  :session_gone}` before anything is committed, so the router still sends a
  clean 404; a priming write that fails ends the stream right there, before
  the loop and before a keepalive timer is armed.

  A disconnect is the only ending the session cannot see for itself. Ending
  the stream is not ending this process: the request process belongs to the
  adapter, which may keep it alive for the connection's next request, so no
  `:DOWN` reaches `Wymcp.Session`'s stream monitor and a registration left
  behind would make every later push wait out its caller's own call timeout
  before answering. Every failed write therefore goes through one funnel that
  tells the session (`Wymcp.Session.unregister_stream/2`, a cast — the
  loop must never wait on the session)
  and then closes. Replacement and session death need no such message: the
  session already holds the successor's pid in the first case and is gone
  in the second.

  The session reaches the loop only through this module's public API.
  `push/3` is a stream-answered push: the session hands the pre-encoded
  payload and a reply address to the loop and never blocks on the write —
  the loop answers the address with the push ack (`answer_push/2`): the
  pusher directly on a plain push, the session on a server-request round
  trip's push leg, nobody for a list-changed notification. `replace/1` is a
  plain send: asking, never killing, because the loop's process is serving
  a committed 200. The loop ends with a catch-all clause that drops unknown
  messages at debug level — it must never crash on a stray, and strays
  exist by construction (Plug.Test's adapter notifies the conn owner;
  ThousandIsland's read timer can fire mid-callback).

  ```mermaid
  sequenceDiagram
      participant Client
      participant Router as Router (GET /)
      participant Stream as Stream loop (request process)
      participant Session

      Client->>Router: GET / (Mcp-Session-Id)
      Router->>Session: lookup + touch
      Router->>Stream: serve(conn, session_pid)
      Stream->>Session: register_stream(self())
      Note over Session: asks a replaced old stream to stop
      alt registration fails (session died or timed out)
          Stream-->>Router: {:error, :session_gone}
          Router-->>Client: 404 (pre-commit)
      else registered
          Stream-->>Client: 200 chunked, priming event, keepalives
          Session->>Stream: push(json, reply_to) / replace
          Stream-->>Client: SSE events
          Note over Stream: answers reply_to with the push ack
          Stream-->>Router: final conn (stream ended)
      end
  ```

  ## Event IDs

  Each SSE event gets a monotonically increasing integer ID. Clients use
  `Last-Event-ID` on reconnection to indicate the last event they received.
  Full replay is out of scope — no missed events are re-sent; the counter
  resumes after the client's last seen event (`Last-Event-ID: evt-7` makes
  the priming event `evt-8`).

  The header is raw client input: an id that does not read as
  `evt-<non-negative integer>` is not an error — the resumption point is
  discarded with a warning log naming the raw value, and the counter
  resumes from 0. `evt-0` is a legitimate resumption point, not a discard.

  ```mermaid
  flowchart TD
      subgraph Stream
          ST[Transport.Stream] --> L["receive loop (push / replace / keepalive)"]
          ST --> PR["priming event"]
          ST --> K["keepalive timer"]
      end
      subgraph External
          ST -->|"register_stream / unregister_stream, monitors"| S[Session]
          L --> SSE[Transport.SSE]
      end
  ```
  """

  import Plug.Conn

  require Logger

  alias Wymcp.Session
  alias Wymcp.Transport.SSE

  defmodule State do
    @moduledoc false
    defstruct [
      :conn,
      :session_pid,
      :session_monitor,
      :keepalive_interval,
      :keepalive_timer,
      event_counter: 0
    ]

    @type t :: %__MODULE__{
            conn: Plug.Conn.t(),
            session_pid: pid(),
            session_monitor: reference(),
            keepalive_interval: pos_integer(),
            keepalive_timer: reference() | nil,
            event_counter: non_neg_integer()
          }
  end

  @type serve_opts :: %{
          optional(:keepalive_interval) => pos_integer()
        }

  @typedoc """
  Who awaits one push — the address the loop answers with the push ack.
  """
  @type reply_to :: {:caller, GenServer.from()} | {:ack, pid(), term()} | :none

  @default_keepalive_interval :timer.seconds(15)

  # Single owner of the event-id grammar; minted by event_id/1, parsed by
  # resume_counter/1 — change all three together or reconnects resume from 0.
  @event_id_prefix "evt-"

  @doc """
  Runs the SSE stream for `session_pid` in the calling process — the GET
  request process — and blocks until the stream ends.

  Returns `{:ok, conn}` with the final conn once the stream ends (client
  disconnect, session death, or replacement by a new GET). Returns
  `{:error, :session_gone}` before anything is committed when registering
  with the session fails — the session died between the router's lookup and
  registration, or the registration call timed out; the log distinguishes
  the two. The `Last-Event-ID` request header (first value wins) sets the
  resumption point.

  `opts` may carry `:keepalive_interval` in milliseconds (default 15 000);
  only tests override it.
  """
  def serve(%Plug.Conn{} = conn, session_pid, opts \\ %{}) when is_pid(session_pid) do
    session_monitor = Process.monitor(session_pid)

    case register(session_pid) do
      :ok ->
        {:ok, stream(conn, session_pid, session_monitor, opts)}

      {:error, :registration} ->
        Process.demonitor(session_monitor, [:flush])
        {:error, :session_gone}
    end
  end

  @doc """
  Hands one pre-encoded push to the stream loop — a stream-answered push:
  the caller never blocks here; the loop answers `reply_to` with the push
  ack after the chunk write.

  `{:caller, from}` answers a `GenServer.call`er directly via
  `GenServer.reply/2` (`Wymcp.Session` forwards the pusher's own `from`, so
  a late ack is dropped by the caller's reply alias); `{:ack, session_pid,
  tag}` sends `{:push_ack, tag, result}` to the session — the server-request
  round trip's push leg; `:none` expects no answer (list-changed
  notifications). The ack vocabulary: `:ok` — written; `{:error,
  :disconnected}` — the chunk write failed and the stream is closing, or
  the push was still queued when the stream closed (the close drain answers
  it). A push sent in the gap between registration and loop entry queues in
  the loop's mailbox and is answered after the priming event.
  """
  def push(stream_pid, json, reply_to) when is_pid(stream_pid) and is_binary(json) do
    send(stream_pid, {:push, reply_to, json})
    :ok
  end

  @doc """
  Asks the stream loop to end so a new GET can take over the session.

  A plain send — never blocks the caller, never kills: the loop's process
  is a request process serving a committed 200, and it finishes normally by
  returning its conn up the plug stack.
  """
  def replace(stream_pid) when is_pid(stream_pid) do
    send(stream_pid, :replaced)
    :ok
  end

  # -- Registration --

  defp register(session_pid) do
    Session.register_stream(session_pid, self())
  catch
    :exit, reason ->
      log_registration_failure(reason)
      # A timed-out register call leaves its request in the session's
      # mailbox, and this process — the adapter's connection process —
      # stays alive after the 404, so the session's dead-pid guard cannot
      # reject the stale register when it finally dequeues it: it would
      # register a process that runs no loop. This identity-guarded cast
      # queues behind that stale register (same sender, order preserved)
      # and clears the mis-registration right back out; a session that is
      # simply gone ignores casts.
      Session.unregister_stream(session_pid, self())
      {:error, :registration}
  end

  # A dead or dying session is registration's expected failure — the
  # router's lookup only proves the session was alive a moment ago — so
  # these four stay silent: :noproc (already gone), :normal (a clean stop),
  # :shutdown (DELETE, via DynamicSupervisor.terminate_child/2), and
  # {:shutdown, _} (the idle timer stops the session with
  # {:shutdown, :session_expired}). All four probed as GenServer.call exit
  # reasons on OTP 28.
  defp log_registration_failure({:noproc, _call}), do: :ok
  defp log_registration_failure({:normal, _call}), do: :ok
  defp log_registration_failure({:shutdown, _call}), do: :ok
  defp log_registration_failure({{:shutdown, _term}, _call}), do: :ok

  # Anything else — a call timeout from a session whose mailbox is backed
  # up, a session crash — is not "session gone". The client's 404 reads
  # "your session is gone, re-initialize" either way; only this line tells
  # the operator which it really was.
  defp log_registration_failure(reason) do
    Logger.warning("SSE stream registration failed: #{inspect(reason)}")
  end

  # -- The stream --

  defp stream(conn, session_pid, session_monitor, opts) do
    keepalive_interval = Map.get(opts, :keepalive_interval, @default_keepalive_interval)
    last_event_id = List.first(get_req_header(conn, "last-event-id"))
    resumption = resume_counter(last_event_id)
    log_resumption(resumption, last_event_id)

    state = %State{
      conn: open(conn),
      session_pid: session_pid,
      session_monitor: session_monitor,
      keepalive_interval: keepalive_interval
    }

    case send_priming_event(state, resumption) do
      {:ok, state} ->
        loop(%{state | keepalive_timer: schedule_keepalive(keepalive_interval)})

      {:error, state} ->
        # No loop and no timer to arm: the client is already gone. Same
        # ending as a failed push, one write earlier.
        disconnect(state, "priming event")
    end
  end

  defp open(conn) do
    conn
    |> put_resp_content_type("text/event-stream")
    |> put_resp_header("cache-control", "no-cache")
    |> send_chunked(200)
  end

  defp loop(%State{session_monitor: session_monitor} = state) do
    receive do
      {:push, reply_to, json} ->
        handle_push(state, reply_to, json)

      :keepalive ->
        handle_keepalive(state)

      :replaced ->
        Logger.debug("SSE stream replaced by a new GET, closing")
        close(state)

      {:DOWN, ^session_monitor, :process, _pid, reason} ->
        Logger.debug("Session terminated (#{inspect(reason)}), closing SSE stream")
        close(state)

      {:plug_conn, :sent} ->
        # Plug.Test's adapter notifies the conn's owner on send_chunked —
        # under a test this is our own mailbox. No real adapter sends it.
        loop(state)

      :read_timeout ->
        # ThousandIsland's read timer, armed before the plug callback and
        # only flushed after it returns — consuming it here is equivalent.
        loop(state)

      {:EXIT, _pid, :normal} ->
        # The adapter's connection process traps exits, so even a linked
        # process's normal exit arrives as a message. Nothing to do —
        # Bandit's own handler ignores these the same way.
        loop(state)

      {:EXIT, _pid, reason} ->
        # The trap also turns a supervisor's shutdown signal (deploy,
        # ThousandIsland.stop/2) into a message. Treat it as the end of
        # the stream: hand the conn back so the response completes,
        # instead of holding the supervisor's shutdown timeout open and
        # being brutally killed mid-stream.
        Logger.debug("SSE stream closing: adapter exit signal (#{inspect(reason)})")
        close(state)

      other ->
        Logger.debug("SSE stream dropping unexpected message: #{inspect(other)}")
        loop(state)
    end
  end

  defp handle_push(state, reply_to, json) do
    event_id = event_id(state.event_counter + 1)

    case write(state.conn, json, event_id) do
      {:ok, conn} ->
        answer_push(reply_to, :ok)
        loop(%{state | conn: conn, event_counter: state.event_counter + 1})

      {:error, reason} ->
        # Answer first: a plain pusher is blocked on this ack, and
        # disconnect/2 talks to the session before returning.
        answer_push(reply_to, {:error, :disconnected})
        disconnect(state, "push (#{inspect(reason)})")
    end
  end

  # The push ack goes to whoever awaits the push: the pusher directly on a
  # plain push, the session on a server-request round trip's push leg,
  # nobody for a fire-and-forget notification.
  defp answer_push({:caller, from}, result), do: GenServer.reply(from, result)

  defp answer_push({:ack, session_pid, tag}, result),
    do: send(session_pid, {:push_ack, tag, result})

  defp answer_push(:none, _result), do: :ok

  defp handle_keepalive(state) do
    case write_keepalive(state.conn) do
      {:ok, conn} ->
        timer = schedule_keepalive(state.keepalive_interval)
        loop(%{state | conn: conn, keepalive_timer: timer})

      {:error, reason} ->
        disconnect(state, "keepalive (#{inspect(reason)})")
    end
  end

  # Every failed write ends here. Ending the stream is not ending this
  # process — it is the adapter's connection process and may serve the
  # connection's next request — so the session's stream monitor never
  # fires and the registration would go stale, costing every later plain
  # push its caller's full call timeout against a mailbox nobody drains. A
  # cast, not a call: the loop must never wait on the session. A pid the
  # session no longer has registered is ignored on its side, so a
  # replacement that raced this message keeps its registration.
  defp disconnect(state, what) do
    Logger.debug("SSE stream closing: #{what} write failed, client disconnected")
    Session.unregister_stream(state.session_pid, self())
    close(state)
  end

  # The loop's single exit funnel. The request process outlives the stream
  # (Bandit may reuse it for the connection's next request), so the pending
  # keepalive timer is cancelled and the session monitor demonitored,
  # rather than left to fire — or land — in a later, unrelated request's
  # mailbox. The demonitor is a harmless no-op on the session-`:DOWN` exit
  # (that monitor has already fired and been consumed), which is why it
  # belongs in the funnel instead of in each branch.
  defp close(state) do
    _ = if state.keepalive_timer, do: Process.cancel_timer(state.keepalive_timer)
    flush_keepalive()
    Process.demonitor(state.session_monitor, [:flush])
    drain_pushes()
    state.conn
  end

  # cancel_timer/1 answers false for a timer that already fired — the
  # :keepalive is then already in the mailbox, and this process outlives
  # the stream, so without the flush a follow-up stream on the same
  # connection would consume it and run a second keepalive chain alongside
  # its own.
  defp flush_keepalive do
    receive do
      :keepalive -> :ok
    after
      0 -> :ok
    end
  end

  # Answer pushes still queued at close instead of leaving them for a
  # mailbox nobody drains: the ending reached this loop before they did,
  # so {:error, :disconnected} is the truthful answer, delivered now
  # rather than at the caller's push timeout. This is what keeps push/3's
  # queued-push promise on the one path that never enters the loop — a
  # priming write that fails with a push already dispatched into the gap.
  defp drain_pushes do
    receive do
      {:push, reply_to, _json} ->
        answer_push(reply_to, {:error, :disconnected})
        drain_pushes()
    after
      0 -> :ok
    end
  end

  defp send_priming_event(state, resumption) do
    start_counter =
      case resumption do
        {:resume, counter} -> counter
        _fresh_or_discard -> 0
      end

    event_id = event_id(start_counter + 1)

    case write_empty(state.conn, event_id) do
      {:ok, conn} -> {:ok, %{state | conn: conn, event_counter: start_counter + 1}}
      {:error, _reason} -> {:error, state}
    end
  end

  # -- Conn writes (only the loop and the priming path call these) --

  defp write(conn, json, event_id), do: chunk(conn, SSE.frame(json, event_id))

  defp write_empty(conn, event_id), do: chunk(conn, SSE.frame_empty(event_id))

  defp write_keepalive(conn), do: chunk(conn, ":keepalive\n\n")

  # -- Event-id grammar --

  defp event_id(counter), do: @event_id_prefix <> Integer.to_string(counter)

  # Last-Event-ID is raw client input; never assume the suffix is numeric.
  # :fresh (no header) and :discard (malformed header) both resume from 0 —
  # the shapes differ so the discard can be logged as the operator signal
  # it is (a proxy mangling the header), while a well-formed `evt-0` stays
  # a normal reconnect. Detection keys on parse failure, never counter == 0.
  defp resume_counter(nil), do: :fresh

  defp resume_counter(@event_id_prefix <> suffix) do
    case Integer.parse(suffix) do
      {value, ""} when value >= 0 -> {:resume, value}
      _ -> :discard
    end
  end

  defp resume_counter(_last_event_id), do: :discard

  defp log_resumption(:fresh, _header), do: :ok

  defp log_resumption({:resume, _counter}, header) do
    Logger.info("SSE stream reconnected, last_event_id=#{header}")
  end

  defp log_resumption(:discard, header) do
    Logger.warning("SSE resumption point discarded, malformed last-event-id=#{header}")
  end

  defp schedule_keepalive(interval) do
    Process.send_after(self(), :keepalive, interval)
  end
end
