defmodule Wymcp.Transport.StreamManager do
  @moduledoc """
  GenServer that owns a chunked SSE connection for a single MCP session.

  Each StreamManager holds open a `Plug.Conn` in chunked transfer mode
  and sends SSE-formatted events when the session pushes messages. A
  keepalive timer prevents proxies and load balancers from closing idle
  connections.

  ## Design decisions

  The StreamManager runs as a separate process from the Session GenServer.
  This is necessary because the SSE connection is a long-lived blocking
  operation — if it lived inside the Session, the session could not
  process POST requests while holding the connection open. The separate
  process also allows the keepalive timer to fire independently.

  Mutual monitoring ensures cleanup: the StreamManager monitors the
  session (shuts down if the session dies), and the session monitors
  the StreamManager (clears its stream reference if the stream dies).

  Startup is two-phase. `start_link/1` runs the fallible, conn-less phase:
  `init/1` monitors the session and registers with it via
  `Wymcp.Session.register_stream/2` — before the router has committed an
  HTTP status. A session dying in that window surfaces as `:ignore` from
  `start_link/1` (not a non-`:normal` init exit, which would kill the
  linked request process), and the router answers a clean 404 instead of
  crashing a committed response. On `{:ok, pid}` the router sends the 200
  (`Wymcp.Transport.Stream.open/1`) and hands the chunked conn over with
  `attach/2`, which sends the priming event and starts the keepalive
  timer. A push arriving between registration and attach answers
  `{:error, :no_stream}` — and the session forwards that to a waiting
  `Wymcp.Context.sample/3` or `Wymcp.Context.elicit/4` immediately,
  rather than letting it wait out its timeout.

  Only one active SSE stream per session is supported. A new GET request
  replaces the previous stream: when the new manager registers, the
  session asks the old one to stop (a `:replaced` cast answered with
  `{:stop, :normal, …}`, so the old GET request process can still finish
  its response) and the old connection closes.

  ```mermaid
  sequenceDiagram
      participant Client
      participant Router as Router (GET /)
      participant Manager as StreamManager
      participant Session

      Client->>Router: GET / (Mcp-Session-Id)
      Router->>Session: lookup + touch
      Router->>Manager: start_link(session_pid, last_event_id)
      Manager->>Session: register_stream(self())
      Note over Session: asks a replaced old manager to stop
      alt session died before registration
          Manager-->>Router: :ignore
          Router-->>Client: 404 (pre-commit)
      else registered
          Manager-->>Router: {:ok, pid}
          Router-->>Client: 200, chunked (SSE open)
          Router->>Manager: attach(chunked_conn)
          Manager-->>Client: priming event, then keepalives
      end
  ```

  ## Event IDs

  Each SSE event gets a monotonically increasing integer ID. Clients
  use `Last-Event-ID` on reconnection to indicate the last event they
  received. Full replay is out of scope — no missed events are re-sent;
  the counter resumes after the client's last seen event
  (`Last-Event-ID: evt-7` makes the priming event `evt-8`).

  The header is raw client input: an id that does not read as
  `evt-<non-negative integer>` is not an error — the resumption point is
  discarded with a warning log naming the raw value, and the counter
  resumes from 0. `evt-0` is a legitimate resumption point, not a discard.

  ```mermaid
  flowchart TD
      subgraph StreamManager
          SM[StreamManager] --> P["push/2"]
          SM --> K["keepalive timer"]
          SM --> PR["priming event"]
      end
      subgraph External
          SM --> S[Session]
          P --> ST[Transport.Stream]
          SM -->|monitors| S
      end
  ```

  ## Related Modules

  See: `Wymcp.Transport.Stream`, `Wymcp.Transport.SSE`, `Wymcp.Session`

  ## Tests

  See: `Wymcp.Transport.StreamManagerTest`
  """

  use GenServer

  require Logger

  alias Wymcp.Session
  alias Wymcp.Transport.Stream, as: SSEStream

  @default_keepalive_interval :timer.seconds(15)

  # Single owner of the event-id grammar; minted by event_id/1, parsed by
  # resume_counter/1 — change all three together or reconnects resume from 0.
  @event_id_prefix "evt-"

  defmodule State do
    @moduledoc false
    defstruct [
      :conn,
      :session_pid,
      :session_monitor,
      :keepalive_interval,
      :keepalive_timer,
      :last_event_id,
      event_counter: 0
    ]

    @type t :: %__MODULE__{
            conn: Plug.Conn.t() | nil,
            session_pid: pid(),
            session_monitor: reference(),
            keepalive_interval: pos_integer(),
            keepalive_timer: reference() | nil,
            last_event_id: String.t() | nil,
            event_counter: non_neg_integer()
          }
  end

  # -- Public API --

  @type start_opts :: %{
          required(:session_pid) => pid() | nil,
          optional(:keepalive_interval) => pos_integer(),
          optional(:last_event_id) => String.t() | nil
        }

  def start_link(%{session_pid: nil}), do: {:error, :no_session}

  def start_link(%{session_pid: session_pid} = opts) do
    GenServer.start_link(__MODULE__, %{
      session_pid: session_pid,
      keepalive_interval: Map.get(opts, :keepalive_interval, @default_keepalive_interval),
      last_event_id: Map.get(opts, :last_event_id)
    })
  end

  @doc """
  Pushes a JSON-RPC message to the client as an SSE event.

  Returns `:ok` on success, `{:error, :no_stream}` when the manager is
  registered but has not yet received its conn via `attach/2` (the
  router's start→attach window), or `{:error, :disconnected}` if the
  chunk write fails (client has disconnected).
  """
  def push(pid, message) do
    GenServer.call(pid, {:push, message})
  end

  @doc """
  Hands the committed chunked conn to a registered manager, which sends
  the priming event and starts keepalives.

  The manager may have died between `start_link/1` and this call (its
  session terminated in the gap). The 200 is already committed then, so
  the caught exit answers `{:error, :gone}` and the caller finishes its
  truncated response — the client reconnects, gets 404, and
  re-initializes per spec.
  """
  def attach(pid, %Plug.Conn{} = conn) do
    GenServer.call(pid, {:attach, conn})
  catch
    :exit, _reason -> {:error, :gone}
  end

  # -- Callbacks --

  @impl GenServer
  def init(%{session_pid: session_pid} = opts) do
    ref = Process.monitor(session_pid)

    # Phase one is fallible: the session can die between the router's
    # lookup and this registration (concurrent DELETE, or the idle timer —
    # touch/1 is a cast and can lose the race). Every exit from the call
    # becomes :ignore rather than {:stop, reason}: a non-:normal init exit
    # reason kills the linked GET request process before start_link/1
    # returns (probed on OTP 28), while :ignore exits :normal and gives
    # the router a clean return to answer a pre-commit 404 with. Only the
    # log distinguishes the expected race from an unexpected failure.
    try do
      Session.register_stream(session_pid, self())

      {:ok,
       %State{
         session_pid: session_pid,
         session_monitor: ref,
         keepalive_interval: opts.keepalive_interval,
         last_event_id: opts.last_event_id
       }}
    catch
      :exit, reason ->
        log_registration_failure(reason)
        :ignore
    end
  end

  @impl GenServer
  def handle_call({:attach, conn}, _from, state) do
    resumption = resume_counter(state.last_event_id)
    log_resumption(resumption, state.last_event_id)
    {conn, event_counter} = send_priming_event(conn, resumption)
    timer = schedule_keepalive(state.keepalive_interval)

    {:reply, :ok, %{state | conn: conn, keepalive_timer: timer, event_counter: event_counter}}
  end

  def handle_call({:push, _message}, _from, %State{conn: nil} = state) do
    {:reply, {:error, :no_stream}, state}
  end

  def handle_call({:push, message}, _from, state) do
    event_id = event_id(state.event_counter + 1)

    case SSEStream.push(state.conn, message, event_id) do
      {:ok, conn} ->
        {:reply, :ok, %{state | conn: conn, event_counter: state.event_counter + 1}}

      {:error, reason} ->
        Logger.debug("SSE push failed: #{inspect(reason)}, client likely disconnected")
        {:stop, :normal, {:error, :disconnected}, state}
    end
  end

  @impl GenServer
  def handle_cast(:replaced, state) do
    Logger.debug("SSE stream replaced by a new GET, closing")
    {:stop, :normal, state}
  end

  @impl GenServer
  def handle_info(:keepalive, state) do
    case SSEStream.push_keepalive(state.conn) do
      {:ok, conn} ->
        timer = schedule_keepalive(state.keepalive_interval)
        {:noreply, %{state | conn: conn, keepalive_timer: timer}}

      {:error, _reason} ->
        Logger.debug("SSE keepalive failed, client disconnected")
        {:stop, :normal, state}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{session_monitor: ref} = state) do
    Logger.debug("Session terminated (#{inspect(reason)}), closing SSE stream")
    {:stop, :normal, state}
  end

  @impl GenServer
  def terminate(_reason, state) do
    _ = if state.keepalive_timer, do: Process.cancel_timer(state.keepalive_timer)
    :ok
  end

  # -- Private --

  defp send_priming_event(conn, resumption) do
    start_counter =
      case resumption do
        {:resume, counter} -> counter
        _fresh_or_discard -> 0
      end

    event_id = event_id(start_counter + 1)

    case SSEStream.push_empty(conn, event_id) do
      {:ok, conn} -> {conn, start_counter + 1}
      {:error, _} -> {conn, start_counter}
    end
  end

  defp event_id(counter), do: @event_id_prefix <> Integer.to_string(counter)

  # Last-Event-ID is raw client input; never assume the suffix is numeric.
  # :fresh (no header) and :discard (malformed header) both resume from 0 —
  # the shapes differ so attach can log the discard as the operator signal
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

  # A dead or dying session is phase one's expected failure — the router's
  # lookup only proves the session was alive a moment ago — so these four
  # stay silent: :noproc (already gone), :normal (a clean stop), :shutdown
  # (DELETE, via DynamicSupervisor.terminate_child/2), and {:shutdown, _}
  # (the idle timer stops the session with {:shutdown, :session_expired}).
  # All four probed as GenServer.call exit reasons on OTP 28.
  defp log_registration_failure({:noproc, _call}), do: :ok
  defp log_registration_failure({:normal, _call}), do: :ok
  defp log_registration_failure({:shutdown, _call}), do: :ok
  defp log_registration_failure({{:shutdown, _term}, _call}), do: :ok

  # Anything else — a call timeout from a session whose mailbox is backed up,
  # a session crash — is not "session gone". It still answers :ignore, since a
  # non-:normal init exit would kill the linked request process, but it says
  # so: the client's 404 reads "your session is gone, re-initialize" either
  # way, and only this line tells the operator which it really was.
  defp log_registration_failure(reason) do
    Logger.warning("SSE stream registration failed: #{inspect(reason)}")
  end

  defp schedule_keepalive(interval) do
    Process.send_after(self(), :keepalive, interval)
  end
end
