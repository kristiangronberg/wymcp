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

  ## With OAuth discovery hints on the 401 challenge

      forward "/mcp", Wymcp.Router,
        tools: [MyApp.Tools.Events, MyApp.Tools.Tasks],
        auth: MyApp.McpAuth,
        www_authenticate: [
          resource_metadata: {MyAppWeb.Endpoint, :url, []},
          scope: "mcp"
        ]

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

  - `:tools` — list of modules implementing the `Wymcp.Tool` behaviour
    (required). `Wymcp.Help` is appended automatically: every server exposes
    the framework's introspection tool under the reserved name `help`, and no
    consumer tool may use that name (`init/1` raises).
  - `:auth` — module implementing the `Wymcp.Auth` behaviour (optional, defaults
    to `Wymcp.Auth.Noop`)
  - `:www_authenticate` — keyword list of RFC 6750 auth-params appended to the
    `Bearer` challenge in the 401 `WWW-Authenticate` header (optional; when
    absent the challenge is bare `Bearer`). Each `{key, value}` renders as
    `key="value"` with quoted-string escaping. A value may be a
    `{module, function, args}` tuple resolved per request — use this when the
    value is only known at runtime (e.g. a public URL from runtime config),
    since forward options are evaluated at compile time. Typical MCP use: an
    RFC 9728 `resource_metadata` pointer and a `scope` hint. If rendering an
    entry raises (e.g. a misconfigured MFA), the challenge degrades to bare
    `Bearer` for that request and an error naming this option is logged — the
    401 contract survives misconfiguration.
  - `:server` — module implementing the `Wymcp.Server` behaviour for session
    lifecycle hooks (optional, defaults to `nil`)
  - `:origin` — list of allowed Origin header values for DNS rebinding protection
    (optional, defaults to allowing all origins). A request with no Origin
    header passes the check even when an allowlist is configured — non-browser
    clients (curl, SDKs) do not send one
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

  POST requests run `Wymcp.Plugs.Pipeline`'s plug chain in order:
  `Wymcp.Plugs.OriginCheck`, JSON body parsing, `Wymcp.Plugs.Classify`,
  `Wymcp.Plugs.Auth`, `Wymcp.Plugs.Session`, `Wymcp.Plugs.Validate`,
  `Wymcp.Plugs.Dispatch`.

  ```mermaid
  flowchart TD
      subgraph Router
          R[Wymcp.Router] --> POST["POST / → Pipeline"]
          R --> GET["GET / → SSE stream"]
          R --> DELETE["DELETE / → terminate"]
      end
      subgraph External
          POST --> P[Plugs.Pipeline]
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
  alias Wymcp.Transport

  plug(:match)
  plug(:dispatch)

  def init(opts) do
    consumer_tools = Keyword.get(opts, :tools, [])
    validate_not_reinitialized!(consumer_tools)
    validate_reserved_tool_names!(consumer_tools)
    validate_unique_tool_names!(consumer_tools)

    tools = consumer_tools ++ [Wymcp.Help]
    opts = Keyword.put(opts, :tools, tools)

    validate_action_schemas!(tools)
    validate_server_module(Keyword.get(opts, :server))
    validate_www_authenticate!(Keyword.get(opts, :www_authenticate, []))
    super(opts)
  end

  # Only the framework's own module in the incoming list signals a
  # re-init — a consumer module whose name() is "help" gets the
  # reserved-name raise below instead. Must run before the reserved-name
  # scan, which would otherwise blame the injected Wymcp.Help itself.
  defp validate_not_reinitialized!(tools) do
    if Wymcp.Help in tools do
      raise ArgumentError,
            "Wymcp.Help found in the :tools option — these options have already been " <>
              "through Wymcp.Router.init/1. Initialize from the original options instead " <>
              "of re-initializing the returned ones."
    end

    :ok
  end

  defp validate_reserved_tool_names!(tools) do
    case Enum.find(tools, &Wymcp.Help.uses_reserved_name?/1) do
      nil ->
        :ok

      module ->
        raise ArgumentError,
              "Tool #{inspect(module)} uses the reserved name #{inspect(Wymcp.Help.name())}. " <>
                "The help tool is provided by Wymcp and injected into every server automatically."
    end
  end

  defp validate_action_schemas!(tools) do
    Enum.each(tools, &Wymcp.Tool.validate_actions!/1)
    :ok
  end

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

  defp validate_www_authenticate!(params) when is_list(params) do
    Enum.each(params, fn
      {key, value} when is_atom(key) and is_binary(value) ->
        :ok

      {key, {m, f, a}} when is_atom(key) and is_atom(m) and is_atom(f) and is_list(a) ->
        :ok

      entry ->
        raise ArgumentError,
              "invalid :www_authenticate entry #{inspect(entry)} — " <>
                "expected {atom, binary} or {atom, {module, function, args}}"
    end)

    :ok
  end

  defp validate_www_authenticate!(other) do
    raise ArgumentError,
          "invalid :www_authenticate option #{inspect(other)} — expected a keyword list"
  end

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
          {:ok, session_pid} -> open_stream(conn, session_pid)
          {:error, :not_found} -> session_not_found(conn)
        end

      [] ->
        missing_session_header(conn)

      [_, _ | _] ->
        duplicated_session_header(conn)
    end
  end

  delete "/" do
    case get_req_header(conn, "mcp-session-id") do
      [session_id] ->
        case Session.terminate_session(session_id) do
          :ok -> send_resp(conn, 200, "") |> halt()
          {:error, :not_found} -> session_not_found(conn)
        end

      [] ->
        missing_session_header(conn)

      [_, _ | _] ->
        duplicated_session_header(conn)
    end
  end

  defp missing_session_header(conn) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(400, JSON.encode!(%{error: "Missing mcp-session-id header"}))
    |> halt()
  end

  defp duplicated_session_header(conn) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(
      400,
      JSON.encode!(%{
        error: "Duplicated Mcp-Session-Id header. Send exactly one Mcp-Session-Id header."
      })
    )
    |> halt()
  end

  defp open_stream(conn, session_pid) do
    Session.touch(session_pid)

    case Transport.Stream.serve(conn, session_pid) do
      {:ok, conn} ->
        conn

      {:error, :session_gone} ->
        # The session died between lookup and registration — the same
        # condition as a lookup miss, answered one step ahead of the
        # 200 commit.
        session_not_found(conn)
    end
  end

  defp session_not_found(conn) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(404, JSON.encode!(%{error: "Session not found"}))
    |> halt()
  end

  match(_, do: send_resp(conn, 404, "Not found"))
end
