defmodule Wymcp.Methods.ToolsCallOutputSchemaTest do
  use ExUnit.Case, async: true

  @moduledoc """
  Tests for structured tool output via `output_schema/0`.

  The MCP spec allows tools to declare an `outputSchema` — a JSON Schema
  describing the structure of the tool's response. When a tool declares
  `output_schema/0`, two things change:

  1. `definition/0` includes an `"outputSchema"` key so clients know
     structured output is available.
  2. `tools/call` validates the tool's response against the schema and
     includes `"structuredContent"` in the result alongside `"content"`.

  Tools without `output_schema/0` behave exactly as before — no
  `"outputSchema"` in the definition, no `"structuredContent"` in results.
  """

  import Plug.Test
  import Plug.Conn

  defmodule StructuredTool do
    @moduledoc false
    use Wymcp.Tool

    @impl true
    def name, do: "structured"

    @impl true
    def description, do: "A tool with output schema"

    @impl true
    def output_schema do
      %{
        "type" => "object",
        "properties" => %{
          "count" => %{"type" => "integer"},
          "label" => %{"type" => "string"}
        },
        "required" => ["count", "label"]
      }
    end

    @impl true
    def actions do
      %{
        run: %{
          description: "Run the tool",
          properties: %{},
          required: [],
          defaults: %{}
        }
      }
    end

    @impl Wymcp.Tool
    def run_action(:run, _data, _ctx) do
      {:ok, %{count: 42, label: "test"}}
    end
  end

  defmodule PlainTool do
    @moduledoc false
    use Wymcp.Tool

    @impl true
    def name, do: "plain"

    @impl true
    def description, do: "A tool without output schema"

    @impl true
    def actions do
      %{
        run: %{
          description: "Run the tool",
          properties: %{},
          required: [],
          defaults: %{}
        }
      }
    end

    @impl Wymcp.Tool
    def run_action(:run, _data, _ctx) do
      {:ok, %{result: "hello"}}
    end
  end

  describe "output_schema in definition/0" do
    @tag doc: """
         When a tool implements output_schema/0, its definition must include
         the "outputSchema" key so clients can discover structured output
         support via tools/list. Tools without output_schema/0 must NOT
         include the key — its absence signals text-only output.
         """
    test "includes outputSchema when tool declares output_schema/0" do
      defn = StructuredTool.definition()
      assert defn["outputSchema"] == StructuredTool.output_schema()
    end

    test "omits outputSchema when tool does not declare output_schema/0" do
      defn = PlainTool.definition()
      refute Map.has_key?(defn, "outputSchema")
    end
  end

  @router_opts Wymcp.Router.init(tools: [StructuredTool, PlainTool])

  describe "structuredContent in tools/call response" do
    @tag doc: """
         When a tool with output_schema/0 returns {:ok, data}, the response
         must include both "content" (text serialization) and
         "structuredContent" (the raw structured data).
         """
    test "returns structuredContent for tool with output_schema" do
      session_id = initialize(@router_opts)
      conn = call_tool(@router_opts, "structured", %{"action" => "run"}, session_id)
      resp = JSON.decode!(conn.resp_body)
      result = resp["result"]

      assert result["content"] != nil
      assert result["structuredContent"] == %{"count" => 42, "label" => "test"}
    end

    test "does not return structuredContent for tool without output_schema" do
      session_id = initialize(@router_opts)
      conn = call_tool(@router_opts, "plain", %{"action" => "run"}, session_id)
      resp = JSON.decode!(conn.resp_body)
      result = resp["result"]

      assert result["content"] != nil
      refute Map.has_key?(result, "structuredContent")
    end

    @tag doc: """
         structuredContent is a 2025-06-18 field. For 2025-03-26
         sessions it must be omitted, but the text content block
         (which carries the same JSON as a stringified payload) must
         remain so the client still has the data.
         """
    test "omits structuredContent for 2025-03-26 sessions but keeps text content" do
      session_id = initialize_with_version("2025-03-26")

      call_body = %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "tools/call",
        "params" => %{"name" => "structured", "arguments" => %{"action" => "run"}}
      }

      conn = call_with_session(call_body, session_id)
      resp = JSON.decode!(conn.resp_body)

      refute Map.has_key?(resp["result"], "structuredContent")
      assert [%{"type" => "text"} | _] = resp["result"]["content"]
    end

    test "includes structuredContent for 2025-06-18 and 2025-11-25 sessions" do
      for version <- ~w(2025-06-18 2025-11-25) do
        session_id = initialize_with_version(version)

        call_body = %{
          "jsonrpc" => "2.0",
          "id" => 1,
          "method" => "tools/call",
          "params" => %{"name" => "structured", "arguments" => %{"action" => "run"}}
        }

        conn = call_with_session(call_body, session_id)
        resp = JSON.decode!(conn.resp_body)

        assert Map.has_key?(resp["result"], "structuredContent"),
               "expected structuredContent for #{version}"
      end
    end
  end

  describe "tools/list field gating by negotiated version" do
    @tag doc: """
         outputSchema was introduced in 2025-06-18. A 2025-03-26 client
         does not know the field; sending it can cause strict clients
         to reject the tool definition. The text-content fallback in
         tools/call (the JSON-stringified payload) preserves all the
         information for the client to consume.
         """
    test "omits outputSchema from tools/list when negotiated version is 2025-03-26" do
      session_id = initialize_with_version("2025-03-26")

      list_body = %{"jsonrpc" => "2.0", "id" => 1, "method" => "tools/list"}
      conn = call_with_session(list_body, session_id)
      resp = JSON.decode!(conn.resp_body)

      [structured_def] = Enum.filter(resp["result"]["tools"], &(&1["name"] == "structured"))

      refute Map.has_key?(structured_def, "outputSchema"),
             "expected outputSchema to be stripped for 2025-03-26 session"
    end

    test "includes outputSchema for 2025-06-18 and 2025-11-25 sessions" do
      for version <- ~w(2025-06-18 2025-11-25) do
        session_id = initialize_with_version(version)

        list_body = %{"jsonrpc" => "2.0", "id" => 1, "method" => "tools/list"}
        conn = call_with_session(list_body, session_id)
        resp = JSON.decode!(conn.resp_body)

        [structured_def] = Enum.filter(resp["result"]["tools"], &(&1["name"] == "structured"))

        assert Map.has_key?(structured_def, "outputSchema"),
               "expected outputSchema for #{version} session"
      end
    end
  end

  defp initialize_with_version(version) do
    body = %{
      "jsonrpc" => "2.0",
      "id" => 0,
      "method" => "initialize",
      "params" => %{
        "protocolVersion" => version,
        "capabilities" => %{},
        "clientInfo" => %{"name" => "test", "version" => "1.0"}
      }
    }

    conn =
      :post
      |> conn("/", JSON.encode!(body))
      |> put_req_header("content-type", "application/json")
      |> Wymcp.Router.call(@router_opts)

    [session_id] = get_resp_header(conn, "mcp-session-id")
    session_id
  end

  defp call_with_session(body, session_id) do
    :post
    |> conn("/", JSON.encode!(body))
    |> put_req_header("content-type", "application/json")
    |> put_req_header("mcp-session-id", session_id)
    |> Wymcp.Router.call(@router_opts)
  end

  defp initialize(router_opts) do
    init_body = %{
      "jsonrpc" => "2.0",
      "id" => 0,
      "method" => "initialize",
      "params" => %{
        "protocolVersion" => "2025-11-25",
        "capabilities" => %{},
        "clientInfo" => %{"name" => "test", "version" => "1.0"}
      }
    }

    init_conn =
      conn(:post, "/", JSON.encode!(init_body))
      |> put_req_header("content-type", "application/json")
      |> Wymcp.Router.call(router_opts)

    [session_id] = get_resp_header(init_conn, "mcp-session-id")

    notify_body = %{"jsonrpc" => "2.0", "method" => "notifications/initialized"}

    conn(:post, "/", JSON.encode!(notify_body))
    |> put_req_header("content-type", "application/json")
    |> put_req_header("mcp-session-id", session_id)
    |> put_req_header("mcp-protocol-version", "2025-11-25")
    |> Wymcp.Router.call(router_opts)

    session_id
  end

  defp call_tool(router_opts, name, arguments, session_id) do
    body = %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => "tools/call",
      "params" => %{"name" => name, "arguments" => arguments}
    }

    conn(:post, "/", JSON.encode!(body))
    |> put_req_header("content-type", "application/json")
    |> put_req_header("mcp-session-id", session_id)
    |> put_req_header("mcp-protocol-version", "2025-11-25")
    |> Wymcp.Router.call(router_opts)
  end
end
