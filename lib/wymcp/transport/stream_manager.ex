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

  Only one active SSE stream per session is supported. A new GET request
  replaces the previous stream — the old StreamManager is shut down
  before the new one registers.

  ## Event IDs

  Each SSE event gets a monotonically increasing integer ID. Clients
  use `Last-Event-ID` on reconnection to indicate the last event they
  received. Full replay is out of scope — the ID is logged for
  debugging and the stream resumes from the current position.

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

  alias Wymcp.Transport.Stream, as: SSEStream
  alias Wymcp.Session

  @default_keepalive_interval :timer.seconds(15)

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
            conn: Plug.Conn.t(),
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
          optional(:conn) => Plug.Conn.t(),
          optional(:keepalive_interval) => pos_integer(),
          optional(:last_event_id) => String.t() | nil
        }

  @spec start_link(start_opts()) :: GenServer.on_start()
  def start_link(%{session_pid: nil}), do: {:error, :no_session}

  def start_link(%{conn: conn, session_pid: session_pid} = opts) do
    GenServer.start_link(__MODULE__, %{
      conn: conn,
      session_pid: session_pid,
      keepalive_interval: Map.get(opts, :keepalive_interval, @default_keepalive_interval),
      last_event_id: Map.get(opts, :last_event_id)
    })
  end

  @doc """
  Pushes a JSON-RPC message to the client as an SSE event.

  Returns `:ok` on success or `{:error, :disconnected}` if the chunk
  write fails (client has disconnected).
  """
  @spec push(pid(), map()) :: :ok | {:error, :disconnected}
  def push(pid, message) do
    GenServer.call(pid, {:push, message})
  end

  @doc """
  Gracefully shuts down the stream, closing the connection.
  """
  @spec shutdown(pid()) :: :ok
  def shutdown(pid) do
    GenServer.stop(pid, :normal)
  end

  # -- Callbacks --

  @impl GenServer
  def init(%{conn: conn, session_pid: session_pid} = opts) do
    ref = Process.monitor(session_pid)

    # conn is already opened (chunked) by the router's GET handler.
    # Send priming event so the client has an event ID for reconnection
    {conn, event_counter} = send_priming_event(conn, opts[:last_event_id])

    # Register with the session
    Session.register_stream(session_pid, self())

    keepalive_interval = opts[:keepalive_interval]
    timer = schedule_keepalive(keepalive_interval)

    if opts[:last_event_id] do
      Logger.info("SSE stream reconnected, last_event_id=#{opts[:last_event_id]}")
    end

    {:ok,
     %State{
       conn: conn,
       session_pid: session_pid,
       session_monitor: ref,
       keepalive_interval: keepalive_interval,
       keepalive_timer: timer,
       last_event_id: opts[:last_event_id],
       event_counter: event_counter
     }}
  end

  @impl GenServer
  def handle_call({:push, message}, _from, state) do
    event_id = "evt-#{state.event_counter + 1}"

    case SSEStream.push(state.conn, message, event_id) do
      {:ok, conn} ->
        {:reply, :ok, %{state | conn: conn, event_counter: state.event_counter + 1}}

      {:error, reason} ->
        Logger.debug("SSE push failed: #{inspect(reason)}, client likely disconnected")
        {:stop, :normal, {:error, :disconnected}, state}
    end
  end

  @impl GenServer
  def handle_info(:keepalive, state) do
    case SSEStream.push_keepalive(state.conn) do
      {:ok, conn} ->
        timer = schedule_keepalive(state.keepalive_interval)
        {:noreply, %{state | conn: conn, keepalive_timer: timer}}

      {:error, _reason} ->
        Logger.debug("SSE keepalive failed, client disconnected")
        Session.register_stream(state.session_pid, nil)
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

  @spec send_priming_event(Plug.Conn.t(), String.t() | nil) :: {Plug.Conn.t(), non_neg_integer()}
  defp send_priming_event(conn, last_event_id) do
    # Start event counter after the last known event, or from 0
    start_counter =
      case last_event_id do
        "evt-" <> n -> String.to_integer(n)
        _ -> 0
      end

    event_id = "evt-#{start_counter + 1}"

    case SSEStream.push_empty(conn, event_id) do
      {:ok, conn} -> {conn, start_counter + 1}
      {:error, _} -> {conn, start_counter}
    end
  end

  @spec schedule_keepalive(pos_integer()) :: reference()
  defp schedule_keepalive(interval) do
    Process.send_after(self(), :keepalive, interval)
  end
end
