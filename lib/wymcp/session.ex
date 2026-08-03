defmodule Wymcp.Session do
  @moduledoc """
  GenServer that holds state for a single MCP session.

  A session is one client connection's state — the negotiated protocol
  version, client and server capabilities, tools, per-session assigns, log
  level, and pending requests — created during the `initialize` handshake.
  It ends at DELETE, idle timeout, or crash, and an ended session is never
  restarted (`restart: :temporary`): `lookup/1` answers
  `{:error, :not_found}`, the wire answers 404 with the `-32001` "Session
  terminated" error, and the client re-initializes. Restarting would
  resurrect the id with empty state — live-but-wrong; gone-means-gone keeps
  the 404 contract honest.

  ## Assigns

  Tools can store per-session state via assigns — a map of arbitrary
  key-value pairs that persists across requests within the session.
  Tools update assigns by returning `{:ok, content, assigns_updates}`
  from their `run/2` callback, and read them via `ctx.assigns`.

  ## Idle timeout

  Sessions automatically terminate after a configurable idle period
  (default: 30 minutes). Every incoming request resets the timer. This
  prevents orphaned sessions from accumulating when clients disconnect
  without sending DELETE.

  ## Design decisions

  Each session is a standalone GenServer rather than an ETS table or
  Agent because sampling and elicitation require the session to coordinate
  message routing between the SSE stream process and the pushing request
  processes. A GenServer gives us a single serialization point for that
  coordination.

  Session IDs are 32-byte URL-safe base64 strings generated with
  `:crypto.strong_rand_bytes/1`. The MCP spec requires session IDs to
  contain only visible ASCII characters (0x21–0x7E).

  ```mermaid
  flowchart TD
      subgraph Session
          S[Wymcp.Session] --> ST[State struct]
          S --> IT["idle timeout"]
          S --> MT["merge_tools/1"]
      end
      subgraph External
          S --> R[Registry]
          S --> DS[DynamicSupervisor]
          S --> TS[Transport.Stream]
          S --> TEL[Telemetry]
          S -->|"server.init/2, server.terminate/2"| SV(Consumer Server)
      end
  ```

  ```mermaid
  stateDiagram-v2
      [*] --> Initializing : start_session/1

      Initializing --> Ready : mark_ready/1
      Initializing --> [*] : terminate (idle timeout / DELETE / crash)
      Ready --> [*] : terminate (idle timeout / DELETE / crash)

      note right of Initializing
          Session created during initialize.
          Awaiting notifications/initialized
          handshake to transition to Ready.
      end note

      note right of Ready
          Idle timer resets on every
          request via touch/1. Expires
          after 30 min (configurable).
      end note
  ```

  ## Pushes

  The session never blocks on a socket write. `push/3` and
  `await_client_response/4` JSON-encode the payload in the caller's own
  process (an unencodable payload answers `{:error, :unencodable}` right
  there), and the handlers hand the pre-encoded payload plus a reply
  address to the stream loop (`Wymcp.Transport.Stream.push/3`) — a
  stream-answered push. The loop answers a plain push's caller directly;
  the server-request round trip's push leg acks the session instead, which
  runs one small state machine per pending request — two clocks, so a
  wedged stream fails fast (the ack window) while a slow client gets its
  full response timeout:

  ```mermaid
  stateDiagram-v2
      [*] --> AckPending : await_client_response (push handed to loop)
      AckPending --> AwaitingResponse : push ack :ok — client timer armed
      AckPending --> [*] : error ack / ack window expiry / stream :DOWN or unregister — caller answered
      AckPending --> [*] : early deliver_response — caller answered, late ack dropped
      AwaitingResponse --> [*] : deliver_response / server_request_timeout — caller answered
  ```
  """

  use GenServer, restart: :temporary

  require Logger

  alias Wymcp.ProtocolVersion
  alias Wymcp.Transport

  @default_idle_timeout :timer.minutes(30)

  # The ack window: how long the session waits for the loop's push ack on a
  # server-request round trip before answering {:error, :timeout}. A chunk
  # write can legitimately block on TCP backpressure from a slow-but-alive
  # client, so multi-second is deliberate — a fail-fast value would kill
  # healthy round trips under load. Doubles as the CEILING: the :ack_window
  # opt may only shrink this (init/1 refuses a larger one), because
  # await_client_response/4 sizes its outer safety net from this constant
  # in the caller's process, where session state is unreachable. Only tests
  # pass the opt (the :session_idle_timeout precedent).
  @default_ack_window :timer.seconds(5)

  @tools_list_changed_json JSON.encode!(%{
                             "jsonrpc" => "2.0",
                             "method" => "notifications/tools/list_changed"
                           })

  defmodule State do
    @moduledoc false
    defstruct [
      :session_id,
      :protocol_version,
      :client_capabilities,
      :client_info,
      :tools,
      :auth,
      :server,
      :idle_timeout,
      :ack_window,
      :idle_timer_ref,
      :stream_pid,
      :stream_monitor_ref,
      :log_level,
      status: :initializing,
      assigns: %{},
      pending_requests: %{},
      pending_server_requests: %{},
      runtime_tools: []
    ]

    @type t :: %__MODULE__{
            session_id: String.t(),
            protocol_version: String.t(),
            client_capabilities: map(),
            client_info: map(),
            tools: [module()],
            auth: module() | nil,
            server: module() | nil,
            status: :initializing | :ready,
            assigns: map(),
            idle_timeout: pos_integer(),
            ack_window: pos_integer(),
            idle_timer_ref: reference() | nil,
            pending_requests: %{
              optional(term()) => %{method: String.t(), started_at: integer()}
            },
            # {:ack_pending, from, ack_ref, ack_timer, client_timeout} while
            # the push leg is unanswered; {:awaiting_response, from, ack_ref,
            # timer_ref} once the ack armed the client clock. Both carry the
            # attempt's ack_ref, which every timer and ack message pins.
            pending_server_requests: %{
              optional(term()) =>
                {:ack_pending, GenServer.from(), reference(), reference(), pos_integer()}
                | {:awaiting_response, GenServer.from(), reference(), reference()}
            },
            log_level: String.t() | nil,
            runtime_tools: [module()],
            stream_pid: pid() | nil,
            stream_monitor_ref: reference() | nil
          }
  end

  def start_link({session_id, opts}) do
    GenServer.start_link(__MODULE__, {session_id, opts},
      name: {:via, Registry, {Wymcp.Session.Registry, session_id}}
    )
  end

  @doc """
  Starts a session under the session supervisor and returns
  `{:ok, pid, session_id}` — a three-element tuple, not the usual
  `{:ok, pid}`: the generated session id is the value the transport
  layer must echo in the `Mcp-Session-Id` response header.
  """
  def start_session(opts) do
    session_id = generate_session_id()

    case DynamicSupervisor.start_child(
           Wymcp.Session.Supervisor,
           {__MODULE__, {session_id, opts}}
         ) do
      {:ok, pid} -> {:ok, pid, session_id}
      {:error, reason} -> {:error, reason}
    end
  end

  def lookup(session_id) do
    case Registry.lookup(Wymcp.Session.Registry, session_id) do
      [{pid, _}] -> {:ok, pid}
      [] -> {:error, :not_found}
    end
  end

  @doc """
  Returns the session's full state struct. Accepts a pid or a session-id
  binary. Unlike the `get_X/1` convention this raises on an unknown
  session id instead of returning an error tuple — every caller runs
  after session resolution, where a missing session is a bug.
  """
  def get_state(pid) when is_pid(pid), do: GenServer.call(pid, :get_state)

  def get_state(session_id) when is_binary(session_id) do
    case lookup(session_id) do
      {:ok, pid} -> get_state(pid)
      {:error, :not_found} -> raise "Session not found: #{session_id}"
    end
  end

  def put_assigns(pid, assigns) when is_map(assigns) do
    GenServer.call(pid, {:put_assigns, assigns})
  end

  def touch(pid) do
    GenServer.cast(pid, :touch)
  end

  def mark_ready(pid) do
    GenServer.call(pid, :mark_ready)
  end

  def ready?(pid) do
    GenServer.call(pid, :ready?)
  end

  def protocol_version(pid) do
    GenServer.call(pid, :protocol_version)
  end

  @doc """
  Returns the protocol version that should drive serialization for the
  current request.

  Resolution order:

  1. The session pid stored in `conn.assigns[:wymcp_session_pid]` (the
     authoritative case — pinned at `initialize` time on the session).
  2. The `MCP-Protocol-Version` request header. After
     `Wymcp.Plugs.Session` enforces session presence on non-exempt
     methods, this branch is reached only by `Methods.Initialize`
     itself, where no session pid exists yet. Honoured only when the
     header value is in `Wymcp.ProtocolVersion.supported/0`.
  3. `Wymcp.ProtocolVersion.latest/0` as a last resort.

  This is the single resolver consulted by `Methods.Initialize`,
  `Methods.ToolsList`, `Methods.ToolsCall`, and `Wymcp.Context.elicit/4`.
  Adding a fourth call site? Use this function — do not re-derive.
  """
  def negotiated_version(%Plug.Conn{} = conn) do
    case conn.assigns[:wymcp_session_pid] do
      pid when is_pid(pid) -> protocol_version(pid)
      _ -> version_from_header(conn)
    end
  end

  @doc """
  Registers a tool module on the session at runtime.

  Runtime tools are merged with compile-time tools (those passed via
  `:tools` in router opts) and take precedence on name collision.
  Registering the same tool twice replaces the previous registration.

  The typical place to call this is inside your server's `c:Wymcp.Server.init/2` callback, where
  `assigns.session_pid` is pre-seeded:

      defmodule MyApp.McpServer do
        use Wymcp.Server

        @impl Wymcp.Server
        def init(_client_info, assigns) do
          user = assigns[:user]

          if :admin in user.roles do
            Wymcp.Session.register_tool(assigns.session_pid, MyApp.Tools.AdministerUsers)
          end

          {:ok, assigns}
        end
      end

  Tools can also be registered later in response to runtime events — for
  example, a tool that grants elevated access after a confirmation step.

  Validates at registration, exactly as `Wymcp.Router.init/1` validates
  compile-time tools at boot: raises `ArgumentError` if the module claims
  the reserved tool name `help` or if any action schema is malformed
  (`Wymcp.Tool.validate_actions!/1`) — a bad runtime tool fails here, in
  the registering code path, not at its first request.

  The raise propagates to the caller. On the `c:Wymcp.Server.init/2` path
  above, that means the session is refused: wymcp catches it at its own
  call site, logs it with the stacktrace, terminates the session, and
  answers `notifications/initialized` with a JSON-RPC `internal_error` —
  the same treatment `init/2` returning `{:error, reason}` gets. Registering
  from anywhere else, the `ArgumentError` is yours to handle.
  """
  def register_tool(pid, tool_module) do
    validate_registerable!(tool_module)
    GenServer.call(pid, {:register_tool, tool_module})
  end

  @doc """
  Removes a runtime-registered tool by name.

  Has no effect on compile-time tools — those are always present. Only
  tools added via `register_tool/2` can be removed. Returns `:ok` even
  if no tool with the given name was registered.

      # Revoke admin access mid-session
      Wymcp.Session.unregister_tool(session_pid, "administer_users")
  """
  def unregister_tool(pid, tool_name) do
    GenServer.call(pid, {:unregister_tool, tool_name})
  end

  @doc """
  Returns the merged list of compile-time and runtime tools. Runtime tools
  take precedence when a name collision occurs — compile-time tools with
  the same name are excluded from the result.
  """
  def get_tools(pid) do
    GenServer.call(pid, :get_tools)
  end

  @log_levels ~w(debug info notice warning error critical alert emergency)

  def set_log_level(pid, level) do
    GenServer.call(pid, {:set_log_level, level})
  end

  @doc """
  Registers the SSE stream process for this session.

  The stream calls this from its own GET request process
  (`Wymcp.Transport.Stream.serve/3`) before the 200 commits. The session
  monitors the stream pid — if the stream's process dies, the session
  clears the registration via the :DOWN handler; a stream that ends
  without its process dying (a disconnect discovered by a failed write)
  says so through `unregister_stream/2`. Registering a new pid while
  another stream is registered asks the old one to stop first, closing its
  connection: only one active SSE stream per session, so a reconnecting
  client does not leave a zombie stream behind.
  """
  def register_stream(pid, stream_pid) when is_pid(stream_pid) do
    GenServer.call(pid, {:register_stream, stream_pid})
  end

  @doc """
  Clears the stream registration when the stream reports its own close.

  `Wymcp.Transport.Stream` calls this when a chunk write fails: the client
  is gone, but the loop runs in the adapter's connection process, which
  outlives the stream (Bandit may reuse it for the connection's next
  request), so the session's stream monitor never fires. Without this the
  registration goes stale and every later plain push waits out its
  caller's full call timeout against a mailbox nobody drains.

  A cast, never a call: the loop must never wait on the session — in the
  paths that reach this function the session's mailbox is by definition
  running behind. A pid that is no longer the registered one is ignored —
  a replacement that registered in the meantime keeps the registration it
  just took.
  """
  def unregister_stream(pid, stream_pid) when is_pid(stream_pid) do
    GenServer.cast(pid, {:unregister_stream, stream_pid})
  end

  @doc """
  Sends a JSON-RPC message to the client over the stream — a
  stream-answered push: the message is JSON-encoded here, in the caller's
  own process, handed to the stream loop together with this call's reply
  reference, and the loop answers the caller directly after the chunk
  write. The session itself never blocks on the write.

  The reply vocabulary, in full: `:ok` — written; `{:error, :unencodable}`
  — the payload cannot be JSON-encoded (answered synchronously, with a
  `Logger.warning` naming the session); `{:error, :no_stream}` — no SSE
  stream is registered; `{:error, :disconnected}` — the chunk write failed
  and the stream is closing (pushes still queued at close get the same
  answer from the drain); `{:error, :timeout}` — no push ack within
  `timeout`, i.e. a wedged stream or one that crashed without draining;
  `{:error, :no_session}` — the session is dead. Under
  `restart: :temporary` a crashed session is a gone session, so every call
  exit except the caller's own `{:timeout, _}` reads as gone.

  `timeout` defaults to `GenServer.call/3`'s own 5 000 ms; only tests pass
  it.
  """
  def push(pid, message, timeout \\ 5_000) when is_pid(pid) do
    with {:ok, json} <- encode_payload(pid, message) do
      call_session(pid, {:push, json}, timeout)
    end
  end

  @doc """
  Pushes a server-initiated request to the client via SSE and blocks the
  caller until the client POSTs back a response — the server-request round
  trip behind `Wymcp.Context.sample/3` and `Wymcp.Context.elicit/4`.

  The payload is JSON-encoded here, in the caller's own process
  (`{:error, :unencodable}` on failure), then handed to the stream loop
  with an ack address. The push leg runs on its own clock — the session's
  private ack window (~5 s): a push ack of `:ok` arms the client-response
  timer with `timeout`, so an `{:error, :timeout}` arriving only after the
  full `timeout` means what it says — the request reached the client and no
  response came back in time — while a wedged stream answers the same tuple
  within the ack window instead. The push leg's other failures are
  immediate: `{:error, :no_stream}` (no stream registered),
  `{:error, :disconnected}` (the write failed, or the stream closed with
  the push still queued), `{:error, :stream_down}` (the stream died while
  the ack was pending). A dead session answers `{:error, :no_session}`
  instead of exiting. When `deliver_response/3` arrives with the matching
  request_id, the caller receives the client's result or error verbatim.

  `request_id` must be unique among the session's in-flight server requests
  (`Wymcp.Context` mints a random one per call). Reusing one that is still
  pending supersedes the earlier entry: the earlier caller stops being
  answered through the round trip and falls back to its own outer safety
  net, answering `{:error, :timeout}` once that expires — and because
  responses route by `request_id`, the client's answer to the earlier,
  already-delivered request is handed to the later caller.
  """
  def await_client_response(pid, request_id, message, timeout)
      when is_pid(pid) and is_integer(timeout) and timeout > 0 do
    with {:ok, json} <- encode_payload(pid, message) do
      # The outer call is a safety net sized once, above both inner clocks
      # (ack window + client timeout + margin). It uses the compile-time
      # default window because session state is unreachable from here —
      # which is why init/1 refuses an :ack_window above that default, so
      # the session's own clocks always expire inside this net. One known
      # hole: the net's clock starts at send, the session's at dequeue, so
      # a session stalled past the 1 s margin expires this net first — the
      # caller reads {:error, :timeout} early and a late client answer is
      # dropped by the caller's dead reply alias.
      call_session(
        pid,
        {:await_client_response, request_id, json, timeout},
        timeout + @default_ack_window + 1_000
      )
    end
  end

  @doc """
  Delivers a client response to a pending server-initiated request.

  Called by `Methods.DeliverResponse` when the router receives a JSON-RPC
  response (has "id" + "result"/"error", no "method"). Matches the
  response's request_id against `pending_server_requests` and unblocks
  the waiting caller.

  Silently ignores responses for unknown request_ids (the request may
  have already timed out).
  """
  def deliver_response(pid, request_id, result_or_error) do
    GenServer.cast(pid, {:deliver_response, request_id, result_or_error})
  end

  def track_request(pid, request_id, method) do
    GenServer.call(pid, {:track_request, request_id, method})
  end

  def complete_request(pid, request_id) do
    GenServer.call(pid, {:complete_request, request_id})
  end

  def terminate_session(session_id) do
    case lookup(session_id) do
      {:ok, pid} ->
        _ = DynamicSupervisor.terminate_child(Wymcp.Session.Supervisor, pid)
        :ok

      {:error, :not_found} ->
        {:error, :not_found}
    end
  end

  # -- Callbacks --

  @impl GenServer
  def init({session_id, opts}) do
    Process.flag(:trap_exit, true)
    idle_timeout = Map.get(opts, :session_idle_timeout, @default_idle_timeout)

    state = %State{
      session_id: session_id,
      protocol_version: opts.protocol_version,
      client_capabilities: opts.client_capabilities,
      client_info: opts.client_info,
      tools: opts.tools,
      auth: opts.auth,
      server: Map.get(opts, :server),
      idle_timeout: idle_timeout,
      ack_window: ack_window(opts),
      idle_timer_ref: schedule_idle_timeout(idle_timeout)
    }

    {:ok, state}
  end

  @impl GenServer
  def handle_call(:get_state, _from, state) do
    {:reply, state, state}
  end

  def handle_call({:put_assigns, new_assigns}, _from, state) do
    state = %{state | assigns: Map.merge(state.assigns, new_assigns)}
    {:reply, :ok, state}
  end

  def handle_call(:mark_ready, _from, state) do
    {:reply, :ok, %{state | status: :ready}}
  end

  def handle_call(:ready?, _from, state) do
    {:reply, state.status == :ready, state}
  end

  def handle_call(:protocol_version, _from, state) do
    {:reply, state.protocol_version, state}
  end

  def handle_call({:track_request, request_id, method}, _from, state) do
    info = %{method: method, started_at: System.monotonic_time(:millisecond)}
    state = %{state | pending_requests: Map.put(state.pending_requests, request_id, info)}
    {:reply, :ok, state}
  end

  def handle_call({:complete_request, request_id}, _from, state) do
    state = %{state | pending_requests: Map.delete(state.pending_requests, request_id)}
    {:reply, :ok, state}
  end

  def handle_call({:register_tool, tool_module}, _from, state) do
    runtime_tools =
      state.runtime_tools
      |> Enum.reject(&(&1.name() == tool_module.name()))
      |> then(&[tool_module | &1])

    state = %{state | runtime_tools: runtime_tools}
    notify_tools_list_changed(state)
    {:reply, :ok, state}
  end

  def handle_call({:unregister_tool, tool_name}, _from, state) do
    runtime_tools = Enum.reject(state.runtime_tools, &(&1.name() == tool_name))
    state = %{state | runtime_tools: runtime_tools}
    notify_tools_list_changed(state)
    {:reply, :ok, state}
  end

  def handle_call({:set_log_level, level}, _from, state) when level in @log_levels do
    {:reply, :ok, %{state | log_level: level}}
  end

  def handle_call({:set_log_level, _level}, _from, state) do
    {:reply, {:error, :invalid_level}, state}
  end

  def handle_call(:get_tools, _from, state) do
    {:reply, merge_tools(state), state}
  end

  def handle_call({:register_stream, stream_pid}, _from, state) when is_pid(stream_pid) do
    if Process.alive?(stream_pid) do
      if state.stream_monitor_ref, do: Process.demonitor(state.stream_monitor_ref, [:flush])
      stop_replaced_stream(state.stream_pid, stream_pid)
      ref = Process.monitor(stream_pid)
      {:reply, :ok, %{state | stream_pid: stream_pid, stream_monitor_ref: ref}}
    else
      # A dead pid here is a poison message: GET1's register call timed
      # out (a busy session) and GET1's process died; GET2 registered and
      # is streaming — and this session then dequeues GET1's stale queued
      # register, because a timed-out GenServer.call leaves its request in
      # the target's mailbox. Acting on it would stop GET2's live stream
      # and register a corpse — leave the registration untouched instead.
      # Accepted residue: a stale register whose sender is *still alive*
      # slips this guard — under Bandit the sender is the adapter's
      # connection process, which normally survives its 404 — briefly
      # stopping a live stream and registering a process that runs no
      # loop. Wymcp.Transport.Stream pairs every failed registration with
      # an unregister_stream cast queued behind that very message (same
      # sender, order preserved), so the mis-registration clears itself
      # immediately and the stopped client recovers through normal SSE
      # reconnection.
      {:reply, :ok, state}
    end
  end

  def handle_call({:push, _json}, _from, %{stream_pid: nil} = state) do
    {:reply, {:error, :no_stream}, state}
  end

  def handle_call({:push, json}, from, %{stream_pid: stream_pid} = state) do
    # Stream-answered push: the loop answers the caller's own reply
    # reference (late acks are dropped by the caller's alias), so this
    # handler is done the moment the payload is handed over. A
    # disconnected stream clears its registration through the loop's
    # unregister_stream cast — the loop sends the pusher's ack first, so
    # a pusher reacting instantly to {:error, :disconnected} can race one
    # more push ahead of that cast; it is forwarded to the closed loop
    # and costs its caller the full call timeout, once, until the cast
    # lands.
    Transport.Stream.push(stream_pid, json, {:caller, from})
    {:noreply, state}
  end

  def handle_call({:await_client_response, request_id, json, timeout}, from, state) do
    case state.stream_pid do
      nil ->
        {:reply, {:error, :no_stream}, state}

      stream_pid ->
        ack_ref = make_ref()

        ack_timer =
          Process.send_after(self(), {:push_ack_timeout, request_id, ack_ref}, state.ack_window)

        Transport.Stream.push(stream_pid, json, {:ack, self(), {request_id, ack_ref}})
        # A reused request_id supersedes the earlier entry here (documented
        # at await_client_response/4). Every timer and ack of the superseded
        # attempt carries ITS ack_ref, so they all miss this entry and drop
        # instead of answering the wrong caller or hitting a
        # differently-shaped tuple.
        entry = {:ack_pending, from, ack_ref, ack_timer, timeout}
        pending = Map.put(state.pending_server_requests, request_id, entry)
        {:noreply, %{state | pending_server_requests: pending}}
    end
  end

  @impl GenServer
  def handle_cast(:touch, state) do
    {:noreply, reset_idle_timeout(state)}
  end

  def handle_cast({:deliver_response, request_id, result_or_error}, state) do
    case Map.pop(state.pending_server_requests, request_id) do
      {nil, _pending} ->
        # Unknown request_id — already timed out or never existed
        {:noreply, state}

      {{:ack_pending, from, _ack_ref, ack_timer, _timeout}, pending} ->
        # The response arrived before the push ack: delivery is proven, so
        # answer now; the late ack drops in its own stale clause.
        _ = Process.cancel_timer(ack_timer)
        GenServer.reply(from, result_or_error)
        {:noreply, %{state | pending_server_requests: pending}}

      {{:awaiting_response, from, _ack_ref, timer_ref}, pending} ->
        _ = Process.cancel_timer(timer_ref)
        GenServer.reply(from, result_or_error)
        {:noreply, %{state | pending_server_requests: pending}}
    end
  end

  def handle_cast({:unregister_stream, stream_pid}, %{stream_pid: stream_pid} = state) do
    # The loop's drain answers every push that reached its mailbox, and
    # those acks arrive ahead of this cast (same sender, order preserved) —
    # so an entry still ack-pending here was forwarded after the drain,
    # into a mailbox nobody reads. Answer it now, in the disconnect
    # vocabulary; waiting would only relabel the same failure
    # {:error, :timeout} a full ack window later.
    state = answer_ack_pending(state, {:error, :disconnected})
    {:noreply, clear_stream(state)}
  end

  def handle_cast({:unregister_stream, _stale_pid}, state), do: {:noreply, state}

  @impl GenServer
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{stream_monitor_ref: ref} = state) do
    state = answer_ack_pending(state, {:error, :stream_down})
    {:noreply, %{state | stream_pid: nil, stream_monitor_ref: nil}}
  end

  def handle_info({:server_request_timeout, request_id, ack_ref}, state) do
    case state.pending_server_requests do
      %{^request_id => {:awaiting_response, from, ^ack_ref, _timer_ref}} ->
        GenServer.reply(from, {:error, :timeout})
        pending = Map.delete(state.pending_server_requests, request_id)
        {:noreply, %{state | pending_server_requests: pending}}

      _ ->
        # Already answered (deliver_response got here first), or this timer
        # belongs to a superseded attempt under a reused request_id — the
        # pin makes both cases the same drop, silently, the way
        # :push_ack_timeout drops. Everything else in the mailbox keeps
        # crashing the session (D5).
        {:noreply, state}
    end
  end

  def handle_info({:push_ack, {request_id, ack_ref} = tag, result}, state) do
    case state.pending_server_requests do
      %{^request_id => {:ack_pending, from, ^ack_ref, ack_timer, timeout}} ->
        _ = Process.cancel_timer(ack_timer)
        {:noreply, resolve_push_ack(result, tag, from, timeout, state)}

      _ ->
        # Stale by name (D5): the entry was already answered — an early
        # deliver_response, the ack window, or a stream :DOWN got there
        # first — or it belongs to an attempt a reused request_id
        # superseded, which the ack_ref pin excludes. Everything else in
        # the mailbox keeps crashing the session.
        Logger.debug("Session dropping stale push ack for request #{inspect(request_id)}")
        {:noreply, state}
    end
  end

  def handle_info({:push_ack_timeout, request_id, ack_ref}, state) do
    case state.pending_server_requests do
      %{^request_id => {:ack_pending, from, ^ack_ref, _ack_timer, _timeout}} ->
        GenServer.reply(from, {:error, :timeout})
        pending = Map.delete(state.pending_server_requests, request_id)
        {:noreply, %{state | pending_server_requests: pending}}

      _ ->
        # The ack won the race (cancel_timer fired after this message was
        # queued) or the entry is already answered — nothing pending.
        {:noreply, state}
    end
  end

  def handle_info(:session_expired, state) do
    Wymcp.Telemetry.emit(:session, :expired, %{}, %{session_id: state.session_id})
    {:stop, {:shutdown, :session_expired}, state}
  end

  @impl GenServer
  def terminate(reason, %State{server: server, assigns: assigns}) when not is_nil(server) do
    server.terminate(reason, assigns)
    :ok
  end

  def terminate(_reason, _state), do: :ok

  # -- Notifications --

  defp notify_tools_list_changed(%{stream_pid: nil}), do: :ok

  defp notify_tools_list_changed(%{stream_pid: stream_pid}) do
    Transport.Stream.push(stream_pid, @tools_list_changed_json, :none)
    :ok
  end

  # Asking, not killing — and never blocking. replace/1 is a plain send: a
  # synchronous stop from inside this handle_call would stall the session
  # whenever the old stream is blocked in a chunk write. The old monitor is
  # already flushed, so the old stream's DOWN cannot clear the new
  # registration.
  defp stop_replaced_stream(nil, _new_pid), do: :ok
  defp stop_replaced_stream(same_pid, same_pid), do: :ok
  defp stop_replaced_stream(old_pid, _new_pid), do: Transport.Stream.replace(old_pid)

  # A push ack of :ok proves the write: arm the client-response clock. An
  # error ack is the round trip's immediate answer. The ack tag the loop
  # echoed — {request_id, ack_ref} — rides on the client-response timer and
  # stays in the entry, so a superseded attempt's timeout drops on the pin
  # instead of answering a stranger.
  defp resolve_push_ack(:ok, {request_id, ack_ref}, from, timeout, state) do
    timer_ref =
      Process.send_after(self(), {:server_request_timeout, request_id, ack_ref}, timeout)

    entry = {:awaiting_response, from, ack_ref, timer_ref}
    pending = Map.put(state.pending_server_requests, request_id, entry)
    %{state | pending_server_requests: pending}
  end

  defp resolve_push_ack({:error, reason}, {request_id, _ack_ref}, from, _timeout, state) do
    GenServer.reply(from, {:error, reason})
    %{state | pending_server_requests: Map.delete(state.pending_server_requests, request_id)}
  end

  # A gone stream can never ack — dead (the :DOWN handler, reason
  # :stream_down) or self-reportedly closed (the unregister cast, reason
  # :disconnected): answer every ack-pending round trip now instead of
  # letting each ack window expire. Entries whose client timer is already
  # armed survive — their push was written, so the client can still POST
  # its response (mirrors the old :DOWN behavior of leaving
  # pending_server_requests untouched).
  defp answer_ack_pending(state, reason) do
    {ack_pending, kept} =
      Map.split_with(state.pending_server_requests, fn {_id, entry} ->
        match?({:ack_pending, _from, _ack_ref, _timer, _timeout}, entry)
      end)

    Enum.each(ack_pending, fn {_id, {:ack_pending, from, _ack_ref, ack_timer, _timeout}} ->
      _ = Process.cancel_timer(ack_timer)
      GenServer.reply(from, reason)
    end)

    %{state | pending_server_requests: kept}
  end

  # Demonitor as well as clear: handle_info/2 has three explicit clauses
  # and no catch-all, so a DOWN arriving later — the connection process
  # does die eventually — with a ref this state no longer knows would
  # crash the session on a function_clause.
  defp clear_stream(state) do
    if state.stream_monitor_ref, do: Process.demonitor(state.stream_monitor_ref, [:flush])
    %{state | stream_pid: nil, stream_monitor_ref: nil}
  end

  # -- Idle timeout --

  defp schedule_idle_timeout(timeout) do
    Process.send_after(self(), :session_expired, timeout)
  end

  defp reset_idle_timeout(state) do
    _ = if state.idle_timer_ref, do: Process.cancel_timer(state.idle_timer_ref)
    %{state | idle_timer_ref: schedule_idle_timeout(state.idle_timeout)}
  end

  defp merge_tools(%State{tools: compile_tools, runtime_tools: runtime_tools}) do
    runtime_names = MapSet.new(runtime_tools, & &1.name())
    filtered_compile = Enum.reject(compile_tools, &(&1.name() in runtime_names))
    runtime_tools ++ filtered_compile
  end

  # Runs in the caller's process so a bad module fails the registering code
  # path, not the session. The predicate's name/0 call also forces the
  # module load (BEAM loads lazily) before validate_actions!/1 reads
  # actions/0.
  defp validate_registerable!(tool_module) do
    if Wymcp.Help.uses_reserved_name?(tool_module) do
      raise ArgumentError,
            "Tool #{inspect(tool_module)} uses the reserved name #{inspect(Wymcp.Help.name())}. " <>
              "The help tool is provided by Wymcp and cannot be replaced at runtime."
    end

    Wymcp.Tool.validate_actions!(tool_module)
  end

  # D4: a dead session answers tuples, never exits. The caller's own
  # timeout is the one exit that does not mean "gone" — everything else
  # (:noproc, :normal, {:shutdown, _}, a crash reason) does, because under
  # restart: :temporary a crashed session IS a gone session.
  defp call_session(pid, request, timeout) do
    GenServer.call(pid, request, timeout)
  catch
    :exit, {:timeout, _call} -> {:error, :timeout}
    :exit, _reason -> {:error, :no_session}
  end

  # Encoding runs in the pusher's own process so a bad payload fails the
  # misbehaving caller's stack, costs the session nothing, and cannot
  # reach the stream. The rescue is deliberately broad: JSON.encode!
  # raises Protocol.UndefinedError for unencodable terms, but
  # FunctionClauseError for improper lists and ErlangError for invalid
  # UTF-8 (all three probed) — any raise from a pure encode of a
  # caller-supplied term means exactly "unencodable".
  defp encode_payload(pid, message) do
    {:ok, JSON.encode!(message)}
  rescue
    exception ->
      Logger.warning(
        "Push payload not JSON-encodable (#{inspect(exception.__struct__)}), " <>
          "session=#{inspect(pid)}: #{inspect(message, limit: 20, printable_limit: 200)}"
      )

      {:error, :unencodable}
  end

  # The ack window may only be shrunk. await_client_response/4 sizes its
  # outer GenServer.call safety net from @default_ack_window, in the
  # caller's process — it cannot read this session's value without an extra
  # round trip — so a larger window would let the caller's own call expire
  # BEFORE the session's ack timer fires, answering {:error, :timeout} for
  # a reason the vocabulary reserves for a wedged stream. Refusing at init
  # keeps the two clocks orderable by construction instead of by comment
  # (given the net's 1 s margin covers the send-to-dequeue delay — see the
  # comment at await_client_response/4's call site).
  defp ack_window(opts) do
    case Map.get(opts, :ack_window, @default_ack_window) do
      window when is_integer(window) and window > 0 and window <= @default_ack_window ->
        window

      other ->
        raise ArgumentError,
              ":ack_window must be a positive integer of at most " <>
                "#{@default_ack_window} ms (await_client_response/4 sizes its outer " <>
                "safety net from that default), got: #{inspect(other)}"
    end
  end

  defp generate_session_id do
    :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
  end

  # -- Version negotiation --

  defp version_from_header(conn) do
    case Plug.Conn.get_req_header(conn, "mcp-protocol-version") do
      [version] ->
        if ProtocolVersion.supported?(version),
          do: version,
          else: ProtocolVersion.latest()

      _ ->
        ProtocolVersion.latest()
    end
  end
end
