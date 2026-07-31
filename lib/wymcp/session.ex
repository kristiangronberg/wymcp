defmodule Wymcp.Session do
  @moduledoc """
  GenServer that holds state for a single MCP session.

  A session is created during the `initialize` handshake and lives until
  the client disconnects, sends DELETE, or the idle timeout expires. It
  stores the negotiated protocol version, client and server capabilities,
  server configuration, and per-session assigns.

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
  message routing between the SSE stream process and spawned tool tasks.
  A GenServer gives us a single serialization point for that coordination.

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
          S --> SM[Transport.StreamManager]
          S --> TEL[Telemetry]
          S -->|"server.init/2, server.terminate/2"| SV(Consumer Server)
      end
  ```

  ```mermaid
  stateDiagram-v2
      [*] --> Initializing : start_session/1

      Initializing --> Ready : mark_ready/1
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

  ## Related Modules

  See: `Wymcp.Context`

  ## Tests

  See: `Wymcp.SessionTest`
  """

  use GenServer

  alias Wymcp.ProtocolVersion

  @default_idle_timeout :timer.minutes(30)

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
            idle_timer_ref: reference() | nil,
            pending_requests: %{
              optional(term()) => %{method: String.t(), started_at: integer()}
            },
            pending_server_requests: %{
              optional(term()) => {GenServer.from(), reference()}
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
  Registers (or clears) the SSE stream process for this session.

  A StreamManager calls this from its `init/1` to associate itself with
  the session. The session monitors the stream pid — if the stream dies,
  the session clears the reference via the :DOWN handler. Registering a
  new pid while another stream is registered stops the old manager first,
  closing its connection: only one active SSE stream per session, so a
  reconnecting client does not leave a zombie stream behind. The old
  manager is *asked* to stop rather than killed — it exits `:normal`, the
  one reason its link to the GET request process that started it does not
  carry fatally, so that request still finishes its response.

  Pass `nil` to explicitly clear the stream (e.g. on graceful close).
  """
  def register_stream(pid, stream_pid) do
    GenServer.call(pid, {:register_stream, stream_pid})
  end

  @doc """
  Pushes a JSON-RPC message to the client via the SSE stream.

  Returns `{:error, :no_stream}` if no stream is currently registered.
  This is the function that sampling/elicitation (Plan 4) will call to
  send server-initiated requests to the client.
  """
  def push_event(pid, message) do
    GenServer.call(pid, {:push_event, message})
  end

  @doc """
  Pushes a server-initiated request to the client via SSE and blocks
  until the client POSTs back a response.

  This is the mechanism behind `Context.sample/3` and `Context.elicit/4`.
  The caller is blocked via GenServer's deferred reply pattern — the
  `handle_call` returns `:noreply` and stores the caller's `from`
  reference. When `deliver_response/3` arrives with the matching
  request_id, the GenServer replies to the stored `from`.

  Returns `{:error, :no_stream}` immediately when no SSE stream is
  connected — or when one is registered but has not yet received its conn
  (the router's start→attach window). A stream whose write fails answers
  `{:error, :disconnected}`, equally immediately. `{:error, :timeout}`
  therefore means what it says: the request reached the client and no
  response came back within `timeout` milliseconds.
  """
  def await_client_response(pid, request_id, message, timeout) do
    GenServer.call(pid, {:await_client_response, request_id, message, timeout}, timeout + 1000)
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

  def handle_call({:register_stream, nil}, _from, state) do
    if state.stream_monitor_ref, do: Process.demonitor(state.stream_monitor_ref, [:flush])
    {:reply, :ok, %{state | stream_pid: nil, stream_monitor_ref: nil}}
  end

  def handle_call({:register_stream, stream_pid}, _from, state) when is_pid(stream_pid) do
    if Process.alive?(stream_pid) do
      if state.stream_monitor_ref, do: Process.demonitor(state.stream_monitor_ref, [:flush])
      stop_replaced_stream(state.stream_pid, stream_pid)
      ref = Process.monitor(stream_pid)
      {:reply, :ok, %{state | stream_pid: stream_pid, stream_monitor_ref: ref}}
    else
      # A dead pid here is a poison message: the manager's own register
      # call timed out (its start_link answered :ignore and it exited), but
      # a timed-out GenServer.call leaves the request in this mailbox, so
      # it still gets dequeued. Acting on it would stop the healthy current
      # stream and end with a nil stream_pid — leave the registration
      # untouched instead. In the live flow the manager is blocked in this
      # very call, so alive-at-dispatch cannot regress to dead-at-handling
      # except through that abandonment.
      {:reply, :ok, state}
    end
  end

  def handle_call({:push_event, _message}, _from, %{stream_pid: nil} = state) do
    {:reply, {:error, :no_stream}, state}
  end

  def handle_call({:push_event, message}, _from, %{stream_pid: stream_pid} = state) do
    result = GenServer.call(stream_pid, {:push, message})
    {:reply, result, state}
  end

  def handle_call({:await_client_response, request_id, message, timeout}, from, state) do
    case state.stream_pid do
      nil ->
        {:reply, {:error, :no_stream}, state}

      stream_pid ->
        # Mirrors push_event/2: whatever the stream answers is the caller's
        # answer. A manager registered but not yet attached says
        # {:error, :no_stream}; a broken socket says {:error, :disconnected}.
        # Both are immediate and true, whereas storing the request and
        # scheduling a timeout would make an undelivered request look like a
        # client that never answered.
        case GenServer.call(stream_pid, {:push, message}) do
          :ok ->
            timer_ref = Process.send_after(self(), {:server_request_timeout, request_id}, timeout)
            pending = Map.put(state.pending_server_requests, request_id, {from, timer_ref})
            {:noreply, %{state | pending_server_requests: pending}}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end
    end
  end

  @impl GenServer
  def handle_cast(:touch, state) do
    {:noreply, reset_idle_timeout(state)}
  end

  def handle_cast({:deliver_response, request_id, result_or_error}, state) do
    case Map.pop(state.pending_server_requests, request_id) do
      {nil, _state} ->
        # Unknown request_id — already timed out or never existed
        {:noreply, state}

      {{from, timer_ref}, pending} ->
        _ = Process.cancel_timer(timer_ref)
        GenServer.reply(from, result_or_error)
        {:noreply, %{state | pending_server_requests: pending}}
    end
  end

  @impl GenServer
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{stream_monitor_ref: ref} = state) do
    {:noreply, %{state | stream_pid: nil, stream_monitor_ref: nil}}
  end

  def handle_info({:server_request_timeout, request_id}, state) do
    case Map.pop(state.pending_server_requests, request_id) do
      {nil, _state} ->
        # Already delivered — ignore
        {:noreply, state}

      {{from, _timer_ref}, pending} ->
        GenServer.reply(from, {:error, :timeout})
        {:noreply, %{state | pending_server_requests: pending}}
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
    message = %{
      "jsonrpc" => "2.0",
      "method" => "notifications/tools/list_changed"
    }

    GenServer.call(stream_pid, {:push, message})
    :ok
  end

  # Asking, not killing. The old manager is linked to the GET request process
  # that started it (StreamManager.start_link/1), and an untrappable
  # Process.exit(old_pid, :kill) propagates :killed across that link, tearing
  # the request process down before it can finish its response (probed).
  # The cast is also the only non-blocking option: a synchronous
  # GenServer.stop/1 from inside this handle_call stalls the session whenever
  # the old manager is itself blocked in a call or a chunk write. The old
  # monitor is already flushed, so the manager's DOWN cannot clear the new
  # registration.
  defp stop_replaced_stream(nil, _new_pid), do: :ok
  defp stop_replaced_stream(same_pid, same_pid), do: :ok
  defp stop_replaced_stream(old_pid, _new_pid), do: GenServer.cast(old_pid, :replaced)

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
  # path, not the session. The name/0 call also forces the module load (BEAM
  # loads lazily) before validate_actions!/1 reads actions/0.
  defp validate_registerable!(tool_module) do
    if tool_module.name() == Wymcp.Help.name() do
      raise ArgumentError,
            "Tool #{inspect(tool_module)} uses the reserved name #{inspect(Wymcp.Help.name())}. " <>
              "The help tool is provided by Wymcp and cannot be replaced at runtime."
    end

    Wymcp.Tool.validate_actions!(tool_module)
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
