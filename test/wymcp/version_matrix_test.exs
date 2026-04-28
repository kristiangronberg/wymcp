defmodule Wymcp.VersionMatrixTest do
  use ExUnit.Case, async: true

  @moduledoc """
  Integration matrix: for every supported protocol version, walk
  initialize → tools/list → tools/call and assert the response shape
  matches what that version expects.

  Each test runs once per version. The version is interpolated into
  the `describe` heading so a failing run prints:

      Wymcp.VersionMatrixTest [protocol version 2025-03-26]
        * test initialize echoes the requested version (FAILED)

  This makes "which version regressed" obvious without inspecting the
  assertion.

  ## Per-version expectations

  - `2025-03-26` (floor): no `MCP-Protocol-Version` header required;
    `outputSchema`, tool `title`, and `structuredContent` MUST NOT
    appear; `serverInfo` extensions are stripped.
  - `2025-06-18`: header required on follow-ups; `outputSchema`,
    `title`, and `structuredContent` SHOULD appear when tools declare
    them; `serverInfo` extensions are kept.
  - `2025-11-25`: same as 06-18 from wymcp's perspective (tasks and
    URL elicitation are out of scope).
  """

  import Plug.Test
  import Plug.Conn

  defmodule MatrixTool do
    @moduledoc false
    use Wymcp.Tool

    @impl true
    def name, do: "matrix"

    @impl true
    def description, do: "A tool used by the version matrix"

    @impl Wymcp.Tool
    def title, do: "Matrix Tool"

    @impl true
    def output_schema do
      %{
        "type" => "object",
        "properties" => %{"value" => %{"type" => "string"}},
        "required" => ["value"]
      }
    end

    @impl true
    def actions do
      %{
        run: %{description: "Run", properties: %{}, required: [], defaults: %{}}
      }
    end

    @impl Wymcp.Tool
    def run_action(:run, _data, _ctx), do: {:ok, %{value: "ok"}}
  end

  @router_opts Wymcp.Router.init(
                 tools: [MatrixTool],
                 server_info: %{
                   title: "Matrix Server",
                   description: "for the version matrix",
                   website_url: "https://example.test"
                 }
               )

  for version <- ~w(2025-11-25 2025-06-18 2025-03-26) do
    describe "protocol version #{version}" do
      @describetag protocol_version: version

      test "initialize echoes the requested version" do
        version = unquote(version)
        conn = init_call(version)
        resp = JSON.decode!(conn.resp_body)

        assert resp["result"]["protocolVersion"] == version
        assert [_session_id] = get_resp_header(conn, "mcp-session-id")
      end

      test "initialize gates serverInfo extensions on the version" do
        version = unquote(version)
        conn = init_call(version)
        resp = JSON.decode!(conn.resp_body)
        server_info = resp["result"]["serverInfo"]

        if Wymcp.ProtocolVersion.supports_server_info_extensions?(version) do
          assert server_info["title"] == "Matrix Server"
          assert server_info["description"] == "for the version matrix"
          assert server_info["websiteUrl"] == "https://example.test"
        else
          refute Map.has_key?(server_info, "title")
          refute Map.has_key?(server_info, "description")
          refute Map.has_key?(server_info, "websiteUrl")
          refute Map.has_key?(server_info, "icons")
        end
      end

      test "tools/list returns the matrix tool" do
        version = unquote(version)
        session_id = init_session(version)

        conn =
          call_with_session(session_id, version, %{
            "jsonrpc" => "2.0",
            "id" => 1,
            "method" => "tools/list"
          })

        resp = JSON.decode!(conn.resp_body)
        assert [defn] = resp["result"]["tools"]
        assert defn["name"] == "matrix"
      end

      test "tools/list outputSchema and title gating matches the version" do
        version = unquote(version)
        session_id = init_session(version)

        conn =
          call_with_session(session_id, version, %{
            "jsonrpc" => "2.0",
            "id" => 1,
            "method" => "tools/list"
          })

        resp = JSON.decode!(conn.resp_body)
        [defn] = resp["result"]["tools"]

        if Wymcp.ProtocolVersion.supports_output_schema?(version) do
          assert Map.has_key?(defn, "outputSchema"),
                 "expected outputSchema for #{version}"

          assert Map.has_key?(defn, "title"),
                 "expected title for #{version}"
        else
          refute Map.has_key?(defn, "outputSchema"),
                 "expected outputSchema to be stripped for #{version}"

          refute Map.has_key?(defn, "title"),
                 "expected title to be stripped for #{version}"
        end
      end

      test "tools/call structuredContent gating matches the version" do
        version = unquote(version)
        session_id = init_session(version)

        conn =
          call_with_session(session_id, version, %{
            "jsonrpc" => "2.0",
            "id" => 2,
            "method" => "tools/call",
            "params" => %{"name" => "matrix", "arguments" => %{"action" => "run"}}
          })

        resp = JSON.decode!(conn.resp_body)
        assert [%{"type" => "text"} | _] = resp["result"]["content"]

        if Wymcp.ProtocolVersion.supports_output_schema?(version) do
          assert Map.has_key?(resp["result"], "structuredContent"),
                 "expected structuredContent for #{version}"
        else
          refute Map.has_key?(resp["result"], "structuredContent"),
                 "expected structuredContent to be stripped for #{version}"
        end
      end
    end
  end

  # -- Helpers --

  defp init_call(version) do
    body = %{
      "jsonrpc" => "2.0",
      "id" => 0,
      "method" => "initialize",
      "params" => %{
        "protocolVersion" => version,
        "capabilities" => %{},
        "clientInfo" => %{"name" => "matrix", "version" => "1.0"}
      }
    }

    :post
    |> conn("/", JSON.encode!(body))
    |> put_req_header("content-type", "application/json")
    |> Wymcp.Router.call(@router_opts)
  end

  defp init_session(version) do
    conn = init_call(version)
    [session_id] = get_resp_header(conn, "mcp-session-id")

    notify_body = %{"jsonrpc" => "2.0", "method" => "notifications/initialized"}

    _ =
      :post
      |> conn("/", JSON.encode!(notify_body))
      |> put_req_header("content-type", "application/json")
      |> put_req_header("mcp-session-id", session_id)
      |> maybe_put_protocol_header(version)
      |> Wymcp.Router.call(@router_opts)

    session_id
  end

  defp call_with_session(session_id, version, body) do
    :post
    |> conn("/", JSON.encode!(body))
    |> put_req_header("content-type", "application/json")
    |> put_req_header("mcp-session-id", session_id)
    |> maybe_put_protocol_header(version)
    |> Wymcp.Router.call(@router_opts)
  end

  defp maybe_put_protocol_header(conn, version) do
    if Wymcp.ProtocolVersion.supports_protocol_version_header?(version) do
      put_req_header(conn, "mcp-protocol-version", version)
    else
      conn
    end
  end
end
