defmodule Wymcp.Methods.RuntimeToolsTest do
  use ExUnit.Case, async: true

  @moduledoc """
  Tests that tools/list and tools/call see runtime-registered tools.

  When a session has runtime tools registered (via Session.register_tool/2),
  both tools/list and tools/call must see them. Runtime tools are merged
  with compile-time tools, with runtime taking precedence on name collision.

  All non-exempt requests require a valid session — the sessionless fallback
  has been removed. Without a session, the request is rejected before reaching
  tools/list or tools/call.
  """

  import Plug.Test
  import Plug.Conn

  alias Wymcp.Session

  defmodule DynamicTool do
    @moduledoc false
    use Wymcp.Tool

    @impl true
    def name, do: "dynamic"

    @impl true
    def description, do: "A dynamically registered tool"

    @impl true
    def actions do
      %{
        ping: %{
          description: "Ping",
          properties: %{},
          required: [],
          defaults: %{}
        }
      }
    end

    @impl Wymcp.Tool
    def run_action(:ping, _data, _ctx) do
      {:ok, %{pong: true}}
    end
  end

  describe "tools/list with runtime tools" do
    @tag doc: """
         After a runtime tool is registered on the session, tools/list
         must include it alongside compile-time tools. A failure means
         tools/list is only reading the compile-time list from router opts
         and ignoring the session's runtime_tools.
         """
    test "includes runtime tools in the listing" do
      router_opts = Wymcp.Router.init(tools: [])

      # Initialize and get session
      {session_id, headers} = initialize_session(router_opts)
      {:ok, pid} = Session.lookup(session_id)

      # Register a runtime tool
      Session.register_tool(pid, DynamicTool)

      # List tools
      list_conn =
        post_json(
          %{
            "jsonrpc" => "2.0",
            "id" => 3,
            "method" => "tools/list"
          },
          headers
        )
        |> Wymcp.Router.call(router_opts)

      assert list_conn.status == 200
      body = JSON.decode!(list_conn.resp_body)
      tool_names = Enum.map(body["result"]["tools"], & &1["name"])
      assert "dynamic" in tool_names
    end
  end

  describe "tools/call with runtime tools" do
    @tag doc: """
         A runtime-registered tool must be callable via tools/call. A failure
         means tools/call's tool lookup only searches compile-time tools.
         """
    test "can call a runtime-registered tool" do
      router_opts = Wymcp.Router.init(tools: [])

      {session_id, headers} = initialize_session(router_opts)
      {:ok, pid} = Session.lookup(session_id)
      Session.register_tool(pid, DynamicTool)

      call_conn =
        post_json(
          %{
            "jsonrpc" => "2.0",
            "id" => 4,
            "method" => "tools/call",
            "params" => %{"name" => "dynamic", "arguments" => %{"action" => "ping"}}
          },
          headers
        )
        |> Wymcp.Router.call(router_opts)

      assert call_conn.status == 200
      body = JSON.decode!(call_conn.resp_body)
      assert body["result"]["content"] != nil
      refute body["result"]["isError"]
    end
  end

  # -- Helpers --

  @spec initialize_session(keyword()) :: {String.t(), [{String.t(), String.t()}]}
  defp initialize_session(router_opts) do
    init_conn =
      post_json(%{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "initialize",
        "params" => %{
          "protocolVersion" => "2025-11-25",
          "capabilities" => %{},
          "clientInfo" => %{"name" => "test", "version" => "1.0"}
        }
      })
      |> Wymcp.Router.call(router_opts)

    [session_id] = get_resp_header(init_conn, "mcp-session-id")
    headers = [{"mcp-session-id", session_id}, {"mcp-protocol-version", "2025-11-25"}]

    # Send notifications/initialized to mark session ready
    post_json(
      %{"jsonrpc" => "2.0", "method" => "notifications/initialized"},
      headers
    )
    |> Wymcp.Router.call(router_opts)

    {session_id, headers}
  end

  @spec post_json(map(), [{String.t(), String.t()}]) :: Plug.Conn.t()
  defp post_json(body, headers \\ []) do
    conn = conn(:post, "/", JSON.encode!(body))
    conn = put_req_header(conn, "content-type", "application/json")
    Enum.reduce(headers, conn, fn {k, v}, c -> put_req_header(c, k, v) end)
  end
end
