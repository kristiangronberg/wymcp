defmodule Wymcp.Router do
  @moduledoc """
  Plug router for the Wymcp MCP server.

  ## Usage in a Phoenix router

      forward "/mcp", Wymcp.Router,
        tools: [MyApp.Tools.Events, MyApp.Tools.Tasks]

  ## With authentication

      forward "/mcp", Wymcp.Router,
        tools: [MyApp.Tools.Events, MyApp.Tools.Tasks],
        auth: MyApp.McpAuth

  ## With origin allowlist (DNS rebinding protection)

      forward "/mcp", Wymcp.Router,
        tools: [MyApp.Tools.Events, MyApp.Tools.Tasks],
        origin: ["http://localhost:4000"]

  ## With server callbacks

      forward "/mcp", Wymcp.Router,
        tools: [MyApp.Tools.Events, MyApp.Tools.Tasks],
        server: MyApp.McpServer

  ## With server info and instructions

      forward "/mcp", Wymcp.Router,
        tools: [MyApp.Tools.Events],
        instructions: "Search docs before answering questions.",
        server_info: %{
          title: "My App MCP",
          description: "Project management tools",
          website_url: "https://myapp.example.com"
        }

  ## Options

  - `:tools` — list of modules implementing the `Wymcp.Tool` behaviour (required)
  - `:auth` — module implementing the `Wymcp.Auth` behaviour (optional, defaults
    to `Wymcp.Auth.Noop`)
  - `:server` — module implementing the `Wymcp.Server` behaviour for session
    lifecycle hooks (optional, defaults to `nil`)
  - `:origin` — list of allowed Origin header values for DNS rebinding protection
    (optional, defaults to allowing all origins)
  - `:instructions` — a string included in the initialize response that guides
    how an LLM should interact with this server's tools (optional)
  - `:server_info` — a map of optional server identity fields displayed by MCP
    clients. Supported keys: `:title` (human-readable name), `:description`,
    `:website_url`, and `:icons`. Each icon is a map with `:src` (required
    URL or `data:` URI) and the optional keys `:mime_type` (e.g. `"image/png"`),
    `:sizes` (list of `"WxH"` strings or `"any"`), and `:theme` (`"light"` or
    `"dark"`). Any other key in an icon map is dropped and a warning is
    logged. These fields are merged with `name` and `version` from
    application config (optional).

  ```mermaid
  flowchart TD
      subgraph Router
          R[Wymcp.Router] --> POST["POST / → Pipeline"]
          R --> GET["GET / → SSE stream"]
          R --> DELETE["DELETE / → terminate"]
      end
      subgraph External
          POST --> P[Plugs.Pipeline]
          GET --> SM[Transport.StreamManager]
          GET --> S[Session]
          GET --> ST[Transport.Stream]
          DELETE --> S
      end
  ```
  """

  use Plug.Router, copy_opts_to_assign: :wymcp

  require Logger

  import Plug.Conn

  alias Wymcp.Plugs.Pipeline
  alias Wymcp.Session

  plug(:match)
  plug(:dispatch)

  @spec init(keyword()) :: keyword()
  def init(opts) do
    tools = Keyword.get(opts, :tools, [])
    validate_unique_tool_names!(tools)
    validate_server_module(Keyword.get(opts, :server))
    super(opts)
  end

  @spec validate_unique_tool_names!([module()]) :: :ok
  defp validate_unique_tool_names!(tools) do
    names = Enum.map(tools, & &1.name())

    case names -- Enum.uniq(names) do
      [] ->
        :ok

      duplicates ->
        raise ArgumentError,
              "Duplicate tool name #{inspect(hd(duplicates))} found in Wymcp.Router tools list. " <>
                "Each tool must have a unique name."
    end
  end

  @spec validate_server_module(module() | nil) :: :ok
  defp validate_server_module(nil), do: :ok

  defp validate_server_module(module) when is_atom(module) do
    behaviours =
      module.module_info(:attributes)
      |> Keyword.get_values(:behaviour)
      |> List.flatten()

    unless Wymcp.Server in behaviours do
      Logger.warning(
        "Server module #{inspect(module)} does not implement the Wymcp.Server behaviour. " <>
          "It may not respond to init/2 or terminate/2 callbacks."
      )
    end

    :ok
  end

  post("/", do: Pipeline.call(conn, Pipeline.init([])))

  get "/" do
    case get_req_header(conn, "mcp-session-id") do
      [session_id] ->
        case Session.lookup(session_id) do
          {:ok, session_pid} ->
            Session.touch(session_pid)
            last_event_id = List.first(get_req_header(conn, "last-event-id"))

            # Open SSE stream here so the router holds the chunked conn
            chunked_conn = Wymcp.Transport.Stream.open(conn)

            opts = %{
              conn: chunked_conn,
              session_pid: session_pid,
              last_event_id: last_event_id
            }

            case Wymcp.Transport.StreamManager.start_link(opts) do
              {:ok, stream_pid} ->
                ref = Process.monitor(stream_pid)

                receive do
                  {:DOWN, ^ref, :process, ^stream_pid, _reason} -> :ok
                end

                chunked_conn

              {:error, reason} ->
                Logger.warning("Failed to start SSE stream: #{inspect(reason)}")

                conn
                |> put_resp_content_type("application/json")
                |> send_resp(500, JSON.encode!(%{error: "Failed to open stream"}))
                |> halt()
            end

          {:error, :not_found} ->
            conn
            |> put_resp_content_type("application/json")
            |> send_resp(404, JSON.encode!(%{error: "Session not found"}))
            |> halt()
        end

      [] ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(400, JSON.encode!(%{error: "Missing mcp-session-id header"}))
        |> halt()
    end
  end

  delete "/" do
    case get_req_header(conn, "mcp-session-id") do
      [session_id] ->
        case Session.terminate_session(session_id) do
          :ok ->
            send_resp(conn, 200, "") |> halt()

          {:error, :not_found} ->
            send_resp(conn, 404, JSON.encode!(%{error: "Session not found"})) |> halt()
        end

      [] ->
        send_resp(conn, 404, JSON.encode!(%{error: "Missing session ID"})) |> halt()
    end
  end

  match(_, do: send_resp(conn, 404, "Not found"))
end
