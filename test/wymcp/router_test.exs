defmodule Wymcp.RouterTest do
  use ExUnit.Case, async: true

  @moduledoc """
  Integration tests for the Wymcp.Router.

  These tests exercise the full pipeline: JSON parsing -> auth -> session ->
  validation -> dispatch -> method handler -> response. Each test sends a raw
  JSON-RPC request and asserts on the HTTP response.

  Tests that require a session (tools/list, tools/call, notifications) must
  initialize first to get a session ID, then include it in subsequent requests.
  Session-exempt methods (initialize, ping) work without a session header.
  """

  import ExUnit.CaptureLog
  import Plug.Test
  import Plug.Conn

  defmodule TestTool do
    use Wymcp.Tool

    def name, do: "test_tool"
    def description, do: "A test tool"

    def actions do
      %{
        ping: %{
          description: "Returns ok",
          properties: %{},
          required: [],
          defaults: %{}
        }
      }
    end

    def run_action(:ping, _data, _ctx), do: {:ok, %{status: "ok"}}
  end

  defmodule AnnotatedTestTool do
    use Wymcp.Tool

    def name, do: "annotated_test"
    def title, do: "Annotated Test"
    def description, do: "Tool with annotations"

    def annotations do
      %{"readOnlyHint" => true, "openWorldHint" => false}
    end

    def actions do
      %{
        ping: %{description: "Ping", properties: %{}, required: [], defaults: %{}}
      }
    end

    def run_action(:ping, _data, _ctx), do: {:ok, %{ok: true}}
  end

  defmodule DuplicateTool do
    use Wymcp.Tool

    def name, do: "test_tool"
    def description, do: "Has same name as TestTool"

    def actions do
      %{
        noop: %{
          description: "Does nothing",
          properties: %{},
          required: [],
          defaults: %{}
        }
      }
    end

    def run_action(:noop, _data, _ctx), do: {:ok, %{}}
  end

  defmodule FailAuth do
    @behaviour Wymcp.Auth

    @impl Wymcp.Auth
    def authenticate(_conn), do: {:error, "Unauthorized"}
  end

  defmodule CrashAuth do
    @behaviour Wymcp.Auth

    @impl true
    def authenticate(_conn), do: raise("auth exploded")
  end

  defp call_router(body, opts \\ []) do
    router_opts = Keyword.merge([tools: [TestTool]], opts)
    init_opts = Wymcp.Router.init(router_opts)

    conn(:post, "/", JSON.encode!(body))
    |> put_req_header("content-type", "application/json")
    |> Wymcp.Router.call(init_opts)
  end

  defp initialize(opts \\ []) do
    body = %{
      "jsonrpc" => "2.0",
      "id" => 0,
      "method" => "initialize",
      "params" => %{
        "protocolVersion" => "2025-11-25",
        "capabilities" => %{},
        "clientInfo" => %{"name" => "test", "version" => "1.0"}
      }
    }

    conn = call_router(body, opts)
    [session_id] = get_resp_header(conn, "mcp-session-id")

    # Complete the handshake so session is :ready
    notify_body = %{"jsonrpc" => "2.0", "method" => "notifications/initialized"}
    call_with_session(notify_body, session_id, opts)

    session_id
  end

  defp call_with_session(body, session_id, opts \\ []) do
    router_opts = Keyword.merge([tools: [TestTool]], opts)
    init_opts = Wymcp.Router.init(router_opts)

    conn(:post, "/", JSON.encode!(body))
    |> put_req_header("content-type", "application/json")
    |> put_req_header("mcp-session-id", session_id)
    |> put_req_header("mcp-protocol-version", "2025-11-25")
    |> Wymcp.Router.call(init_opts)
  end

  describe "initialize" do
    test "returns server info, capabilities, and session ID header" do
      body = %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "initialize",
        "params" => %{
          "protocolVersion" => "2025-11-25",
          "capabilities" => %{"sampling" => %{}},
          "clientInfo" => %{"name" => "test", "version" => "1.0"}
        }
      }

      conn = call_router(body)
      resp = JSON.decode!(conn.resp_body)

      assert resp["result"]["protocolVersion"] == "2025-11-25"
      assert resp["result"]["capabilities"]["tools"] == %{"listChanged" => true}

      [session_id] = get_resp_header(conn, "mcp-session-id")
      assert is_binary(session_id)
      assert byte_size(session_id) > 0

      refute Map.has_key?(resp["result"], "instructions")
    end

    test "includes instructions when configured" do
      instructions = "Always call help before using a tool action."

      body = %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "initialize",
        "params" => %{
          "protocolVersion" => "2025-11-25",
          "capabilities" => %{},
          "clientInfo" => %{"name" => "test", "version" => "1.0"}
        }
      }

      conn = call_router(body, instructions: instructions)
      resp = JSON.decode!(conn.resp_body)

      assert resp["result"]["instructions"] == instructions
    end

    test "includes enriched server_info fields when configured" do
      server_info = %{
        title: "My Awesome Server",
        description: "A server that does great things",
        website_url: "https://example.com",
        icons: [%{url: "https://example.com/icon.png", media_type: "image/png"}]
      }

      body = %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "initialize",
        "params" => %{
          "protocolVersion" => "2025-11-25",
          "capabilities" => %{},
          "clientInfo" => %{"name" => "test", "version" => "1.0"}
        }
      }

      conn = call_router(body, server_info: server_info)
      resp = JSON.decode!(conn.resp_body)

      server_info_resp = resp["result"]["serverInfo"]
      assert server_info_resp["title"] == "My Awesome Server"
      assert server_info_resp["description"] == "A server that does great things"
      assert server_info_resp["websiteUrl"] == "https://example.com"

      assert [%{"url" => "https://example.com/icon.png", "mediaType" => "image/png"}] =
               server_info_resp["icons"]

      # name and version still present from app config
      assert server_info_resp["name"]
      assert server_info_resp["version"]
    end

    test "includes only provided server_info fields" do
      server_info = %{title: "Just A Title"}

      body = %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "initialize",
        "params" => %{
          "protocolVersion" => "2025-11-25",
          "capabilities" => %{},
          "clientInfo" => %{"name" => "test", "version" => "1.0"}
        }
      }

      conn = call_router(body, server_info: server_info)
      resp = JSON.decode!(conn.resp_body)

      server_info_resp = resp["result"]["serverInfo"]
      assert server_info_resp["title"] == "Just A Title"
      assert server_info_resp["name"]
      assert server_info_resp["version"]
      refute Map.has_key?(server_info_resp, "description")
      refute Map.has_key?(server_info_resp, "websiteUrl")
      refute Map.has_key?(server_info_resp, "icons")
    end

    @tag doc: """
         When the client requests a supported version, the server MUST
         echo it back in InitializeResult.protocolVersion. Returning a
         different (e.g. always-latest) value causes spec-strict clients
         like Zed to bail out with "Unsupported protocol version".
         """
    test "echoes the client's requested version when supported" do
      for requested <- ~w(2025-11-25 2025-06-18 2025-03-26) do
        body = %{
          "jsonrpc" => "2.0",
          "id" => 1,
          "method" => "initialize",
          "params" => %{
            "protocolVersion" => requested,
            "capabilities" => %{},
            "clientInfo" => %{"name" => "test", "version" => "1.0"}
          }
        }

        conn = call_router(body)
        resp = JSON.decode!(conn.resp_body)

        assert resp["result"]["protocolVersion"] == requested,
               "expected echo of #{requested}, got #{inspect(resp["result"]["protocolVersion"])}"
      end
    end

    @tag doc: """
         Per spec, when the client requests an unsupported version the
         server MUST respond with one it supports — not a JSON-RPC
         error. The client then decides whether to disconnect.
         """
    test "counter-proposes latest/0 when the requested version is unsupported" do
      body = %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "initialize",
        "params" => %{
          "protocolVersion" => "1999-01-01",
          "capabilities" => %{},
          "clientInfo" => %{"name" => "test", "version" => "1.0"}
        }
      }

      conn = call_router(body)
      resp = JSON.decode!(conn.resp_body)

      assert resp["result"]["protocolVersion"] == Wymcp.ProtocolVersion.latest()
      refute Map.has_key?(resp, "error")
      assert [_session_id] = get_resp_header(conn, "mcp-session-id")
    end

    @tag doc: """
         Per spec: when the server does not support the requested
         version, it MUST respond with one it does — not a JSON-RPC
         error. The session is created and pinned to the counter-proposed
         version; the client decides whether to disconnect.
         """
    test "counter-proposes latest/0 for unsupported protocol version" do
      body = %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "initialize",
        "params" => %{
          "protocolVersion" => "1999-01-01",
          "capabilities" => %{},
          "clientInfo" => %{"name" => "test", "version" => "1.0"}
        }
      }

      conn = call_router(body)
      resp = JSON.decode!(conn.resp_body)

      refute Map.has_key?(resp, "error")
      assert resp["result"]["protocolVersion"] == Wymcp.ProtocolVersion.latest()
      assert [_session_id] = get_resp_header(conn, "mcp-session-id")
    end
  end

  describe "ping" do
    test "returns empty result" do
      body = %{"jsonrpc" => "2.0", "id" => 2, "method" => "ping"}
      conn = call_router(body)
      resp = JSON.decode!(conn.resp_body)

      assert resp["result"] == %{}
    end
  end

  describe "tools/list" do
    test "returns registered tools with oneOf schema" do
      session_id = initialize()

      body = %{"jsonrpc" => "2.0", "id" => 3, "method" => "tools/list"}
      conn = call_with_session(body, session_id)
      resp = JSON.decode!(conn.resp_body)

      [tool] = resp["result"]["tools"]
      assert tool["name"] == "test_tool"
      assert is_list(tool["inputSchema"]["oneOf"])
    end
  end

  describe "tools/call" do
    test "executes the tool and returns result" do
      session_id = initialize()

      body = %{
        "jsonrpc" => "2.0",
        "id" => 4,
        "method" => "tools/call",
        "params" => %{
          "name" => "test_tool",
          "arguments" => %{"action" => "ping"}
        }
      }

      conn = call_with_session(body, session_id)
      resp = JSON.decode!(conn.resp_body)

      assert resp["result"]["isError"] == false
      content = resp["result"]["content"] |> hd() |> Map.get("text") |> JSON.decode!()
      assert content["status"] == "ok"
    end
  end

  describe "authentication" do
    test "returns 401 when auth module rejects the request" do
      body = %{"jsonrpc" => "2.0", "id" => 5, "method" => "tools/list"}
      conn = call_router(body, auth: FailAuth)

      assert conn.status == 401
      assert get_resp_header(conn, "www-authenticate") == ["Bearer"]
      resp = JSON.decode!(conn.resp_body)
      assert resp["error"]["code"] == -32600
    end

    test "passes through when no auth module is configured (defaults to Noop)" do
      body = %{"jsonrpc" => "2.0", "id" => 6, "method" => "ping"}
      conn = call_router(body)

      assert conn.status == 200
    end

    @tag capture_log: true
    test "auth module that raises returns 401" do
      body = %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "initialize",
        "params" => %{}
      }

      conn = call_router(body, auth: CrashAuth)

      assert conn.status == 401
      assert get_resp_header(conn, "www-authenticate") == ["Bearer"]
    end
  end

  describe "GET (SSE listener)" do
    @tag doc: """
         GET without a session header must return 400 — the client needs to
         initialize first (POST) to get a session ID, then open the SSE
         stream (GET) with that ID. A failure here means the router is not
         checking for the session header on GET.
         """
    test "returns 400 when no mcp-session-id header" do
      opts = Wymcp.Router.init(tools: [TestTool])
      conn = conn(:get, "/") |> Wymcp.Router.call(opts)
      assert conn.status == 400
    end

    @tag doc: """
         GET with an unknown session ID must return 404. The client should
         re-initialize if its session has expired.
         """
    test "returns 404 when session not found" do
      opts = Wymcp.Router.init(tools: [TestTool])

      conn =
        conn(:get, "/")
        |> put_req_header("mcp-session-id", "nonexistent")
        |> Wymcp.Router.call(opts)

      assert conn.status == 404
    end

    @tag doc: """
         GET with a valid session must open an SSE stream — the response
         should have status 200, content-type text/event-stream, and be in
         chunked state. Since Plug.Test doesn't support real chunked
         streaming, we run GET in a task and terminate the session to
         unblock it, then verify the response.
         """
    test "opens SSE stream for valid session" do
      session_id = initialize()
      opts = Wymcp.Router.init(tools: [TestTool])

      test_pid = self()

      task =
        Task.async(fn ->
          result_conn =
            conn(:get, "/")
            |> put_req_header("mcp-session-id", session_id)
            |> Wymcp.Router.call(opts)

          send(test_pid, {:stream_done, result_conn})
          result_conn
        end)

      # Give the stream time to start
      Process.sleep(100)

      # Terminate session — this kills the StreamManager via monitor
      Wymcp.Session.terminate_session(session_id)

      assert_receive {:stream_done, result_conn}, 2000
      assert result_conn.status == 200
      assert result_conn.state == :chunked

      {_, content_type} =
        Enum.find(result_conn.resp_headers, fn {k, _} -> k == "content-type" end)

      assert content_type =~ "text/event-stream"

      Task.await(task, 1000)
    end
  end

  describe "capability negotiation" do
    @tag doc: """
         When the client declares sampling support in its initialize
         request, the server must echo it back in the capabilities
         response. This tells the client that the server may send
         sampling/createMessage requests during tool execution.
         """
    test "advertises sampling when client declares sampling capability" do
      body = %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "initialize",
        "params" => %{
          "protocolVersion" => "2025-11-25",
          "capabilities" => %{"sampling" => %{}},
          "clientInfo" => %{"name" => "test", "version" => "1.0"}
        }
      }

      conn = call_router(body)
      resp = JSON.decode!(conn.resp_body)

      assert resp["result"]["capabilities"]["sampling"] == %{}
      assert resp["result"]["capabilities"]["tools"] == %{"listChanged" => true}
    end

    test "advertises elicitation when client declares elicitation capability" do
      body = %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "initialize",
        "params" => %{
          "protocolVersion" => "2025-11-25",
          "capabilities" => %{"elicitation" => %{}},
          "clientInfo" => %{"name" => "test", "version" => "1.0"}
        }
      }

      conn = call_router(body)
      resp = JSON.decode!(conn.resp_body)

      assert resp["result"]["capabilities"]["elicitation"] == %{}
      assert resp["result"]["capabilities"]["tools"] == %{"listChanged" => true}
    end

    @tag doc: """
         When the client does not declare sampling or elicitation, the
         server must not advertise them. Advertising unsupported capabilities
         would cause the server to push requests that the client ignores.
         """
    test "does not advertise sampling/elicitation when client omits them" do
      body = %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "initialize",
        "params" => %{
          "protocolVersion" => "2025-11-25",
          "capabilities" => %{},
          "clientInfo" => %{"name" => "test", "version" => "1.0"}
        }
      }

      conn = call_router(body)
      resp = JSON.decode!(conn.resp_body)

      refute Map.has_key?(resp["result"]["capabilities"], "sampling")
      refute Map.has_key?(resp["result"]["capabilities"], "elicitation")
      assert resp["result"]["capabilities"]["tools"] == %{"listChanged" => true}
    end
  end

  describe "tools/list title and annotations" do
    test "returns title and annotations in tool definitions" do
      session_id = initialize(tools: [AnnotatedTestTool])

      body = %{"jsonrpc" => "2.0", "id" => 3, "method" => "tools/list"}
      conn = call_with_session(body, session_id, tools: [AnnotatedTestTool])
      resp = JSON.decode!(conn.resp_body)

      [tool] = resp["result"]["tools"]
      assert tool["title"] == "Annotated Test"
      assert tool["annotations"]["readOnlyHint"] == true
      assert tool["annotations"]["openWorldHint"] == false
    end
  end

  describe "listChanged capability" do
    test "advertises listChanged in tools capability" do
      body = %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "initialize",
        "params" => %{
          "protocolVersion" => "2025-11-25",
          "capabilities" => %{},
          "clientInfo" => %{"name" => "test", "version" => "1.0"}
        }
      }

      conn = call_router(body)
      resp = JSON.decode!(conn.resp_body)

      assert resp["result"]["capabilities"]["tools"] == %{"listChanged" => true}
    end
  end

  describe "logging capability" do
    test "advertises logging capability" do
      body = %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "initialize",
        "params" => %{
          "protocolVersion" => "2025-11-25",
          "capabilities" => %{},
          "clientInfo" => %{"name" => "test", "version" => "1.0"}
        }
      }

      conn = call_router(body)
      resp = JSON.decode!(conn.resp_body)

      assert resp["result"]["capabilities"]["logging"] == %{}
    end
  end

  describe "logging/setLevel" do
    test "sets log level and returns empty result" do
      session_id = initialize()

      body = %{
        "jsonrpc" => "2.0",
        "id" => 10,
        "method" => "logging/setLevel",
        "params" => %{"level" => "warning"}
      }

      conn = call_with_session(body, session_id)
      resp = JSON.decode!(conn.resp_body)

      assert resp["result"] == %{}
    end

    test "returns error for invalid level" do
      session_id = initialize()

      body = %{
        "jsonrpc" => "2.0",
        "id" => 10,
        "method" => "logging/setLevel",
        "params" => %{"level" => "verbose"}
      }

      conn = call_with_session(body, session_id)
      resp = JSON.decode!(conn.resp_body)

      assert resp["error"]["code"] == -32602
    end
  end

  describe "version negotiation" do
    @tag doc: """
         When the client requests a supported but non-latest version, the
         server counter-proposes the latest. The client must then use the
         server's version. This test will need updating when a second
         protocol version is added — for now it verifies the mechanism
         exists by confirming the server always responds with the latest.
         """
    test "server responds with latest supported version" do
      body = %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "initialize",
        "params" => %{
          "protocolVersion" => "2025-11-25",
          "capabilities" => %{},
          "clientInfo" => %{"name" => "test", "version" => "1.0"}
        }
      }

      conn = call_router(body)
      resp = JSON.decode!(conn.resp_body)

      assert resp["result"]["protocolVersion"] == "2025-11-25"
    end

    test "counter-proposes latest/0 for an unsupported version" do
      body = %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "initialize",
        "params" => %{
          "protocolVersion" => "2024-01-01",
          "capabilities" => %{},
          "clientInfo" => %{"name" => "test", "version" => "1.0"}
        }
      }

      conn = call_router(body)
      resp = JSON.decode!(conn.resp_body)

      refute Map.has_key?(resp, "error")
      assert resp["result"]["protocolVersion"] == Wymcp.ProtocolVersion.latest()
    end
  end

  describe "routing" do
    test "PUT returns 404" do
      opts = Wymcp.Router.init(tools: [])

      conn =
        conn(:put, "/")
        |> put_req_header("content-type", "application/json")
        |> Wymcp.Router.call(opts)

      assert conn.status == 404
    end
  end

  describe "DELETE (session termination)" do
    test "terminates an active session" do
      session_id = initialize()
      opts = Wymcp.Router.init(tools: [TestTool])

      conn =
        conn(:delete, "/")
        |> put_req_header("mcp-session-id", session_id)
        |> Wymcp.Router.call(opts)

      assert conn.status == 200
      # Give Registry time to deregister after supervisor termination
      Process.sleep(10)
      assert {:error, :not_found} = Wymcp.Session.lookup(session_id)
    end

    test "returns 404 for unknown session" do
      opts = Wymcp.Router.init(tools: [])

      conn =
        conn(:delete, "/")
        |> put_req_header("mcp-session-id", "bogus")
        |> Wymcp.Router.call(opts)

      assert conn.status == 404
    end
  end

  describe "session-aware routing" do
    @tag doc: """
         Non-exempt requests without Mcp-Session-Id must be rejected with
         400 per the MCP spec. The sessionless fallback has been removed.
         """
    test "non-initialize requests without session are rejected with 400" do
      body = %{"jsonrpc" => "2.0", "id" => 1, "method" => "tools/list"}
      conn = call_router(body)

      assert conn.status == 400
      resp = JSON.decode!(conn.resp_body)
      assert resp["error"]["code"] == -32600
      assert resp["error"]["data"]["error"] =~ "Missing Mcp-Session-Id"
    end

    @tag doc: """
         Stale session IDs fall through to sessionless mode instead of
         returning 404. This prevents Claude Desktop from breaking when
         sessions expire. The response succeeds using compile-time tools.
         """
    test "stale session ID falls through to sessionless mode" do
      body = %{"jsonrpc" => "2.0", "id" => 1, "method" => "tools/list"}

      router_opts = [tools: [TestTool]]
      init_opts = Wymcp.Router.init(router_opts)

      conn =
        conn(:post, "/", JSON.encode!(body))
        |> put_req_header("content-type", "application/json")
        |> put_req_header("mcp-session-id", "bogus")
        |> Wymcp.Router.call(init_opts)

      assert conn.status == 200
      resp = JSON.decode!(conn.resp_body)
      assert is_list(resp["result"]["tools"])
    end

    test "stale session includes warning in tools/list response" do
      body = %{"jsonrpc" => "2.0", "id" => 1, "method" => "tools/list"}

      router_opts = [tools: [TestTool]]
      init_opts = Wymcp.Router.init(router_opts)

      conn =
        conn(:post, "/", JSON.encode!(body))
        |> put_req_header("content-type", "application/json")
        |> put_req_header("mcp-session-id", "expired-session")
        |> Wymcp.Router.call(init_opts)

      assert conn.status == 200
      resp = JSON.decode!(conn.resp_body)
      assert is_list(resp["result"]["tools"])
      assert [warning] = resp["result"]["_meta"]["warnings"]
      assert warning =~ "Session not found"
    end

    test "stale session ID allows tools/call in sessionless mode" do
      body = %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "tools/call",
        "params" => %{
          "name" => "test_tool",
          "arguments" => %{"action" => "ping"}
        }
      }

      router_opts = [tools: [TestTool]]
      init_opts = Wymcp.Router.init(router_opts)

      conn =
        conn(:post, "/", JSON.encode!(body))
        |> put_req_header("content-type", "application/json")
        |> put_req_header("mcp-session-id", "stale-id")
        |> Wymcp.Router.call(init_opts)

      assert conn.status == 200
      resp = JSON.decode!(conn.resp_body)
      assert resp["result"]["content"]
    end

    test "stale session includes warning in tools/call response" do
      body = %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "tools/call",
        "params" => %{
          "name" => "test_tool",
          "arguments" => %{"action" => "ping"}
        }
      }

      router_opts = [tools: [TestTool]]
      init_opts = Wymcp.Router.init(router_opts)

      conn =
        conn(:post, "/", JSON.encode!(body))
        |> put_req_header("content-type", "application/json")
        |> put_req_header("mcp-session-id", "expired-session")
        |> Wymcp.Router.call(init_opts)

      assert conn.status == 200
      resp = JSON.decode!(conn.resp_body)
      assert [warning] = resp["result"]["_meta"]["warnings"]
      assert warning =~ "Session not found"
    end
  end

  describe "malformed requests" do
    test "malformed JSON returns parse error" do
      opts = Wymcp.Router.init(tools: [TestTool])

      conn =
        conn(:post, "/", "{not valid json}")
        |> put_req_header("content-type", "application/json")
        |> Wymcp.Router.call(opts)

      body = JSON.decode!(conn.resp_body)

      assert conn.status == 400
      assert body["error"]["code"] == -32700
      assert body["error"]["message"] =~ "Parse error"
    end

    test "empty body returns error" do
      opts = Wymcp.Router.init(tools: [TestTool])

      conn =
        conn(:post, "/", "")
        |> put_req_header("content-type", "application/json")
        |> Wymcp.Router.call(opts)

      body = JSON.decode!(conn.resp_body)

      assert conn.status in [400, 404]
      assert body["error"] != nil
    end
  end

  describe "duplicate tool names" do
    test "raises on duplicate tool names at init" do
      assert_raise ArgumentError, ~r/Duplicate tool name "test_tool"/, fn ->
        Wymcp.Router.init(tools: [TestTool, DuplicateTool])
      end
    end
  end

  describe "empty tools list" do
    test "tools/list returns empty array when no tools registered" do
      session_id = initialize(tools: [])

      body = %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "tools/list",
        "params" => %{}
      }

      conn = call_with_session(body, session_id, tools: [])
      resp = JSON.decode!(conn.resp_body)
      assert resp["result"]["tools"] == []
    end

    test "tools/call returns method_not_found when no tools registered" do
      session_id = initialize(tools: [])

      body = %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "tools/call",
        "params" => %{"name" => "anything", "arguments" => %{}}
      }

      conn = call_with_session(body, session_id, tools: [])
      resp = JSON.decode!(conn.resp_body)
      assert resp["error"]["code"] == -32601
    end
  end

  describe "server option" do
    defmodule TestMcpServer do
      @moduledoc false
      use Wymcp.Server
    end

    @tag doc: """
         The :server option is passed through Router.init/1 to the pipeline.
         When set, Methods.Initialize includes it in the Session.start_session
         opts so the session knows which server module to call. A failure here
         means the option is being dropped somewhere in the init chain.
         """
    test "accepts :server option without error" do
      opts = Wymcp.Router.init(tools: [], server: TestMcpServer)
      assert is_list(opts)
    end

    test "works without :server option" do
      opts = Wymcp.Router.init(tools: [])
      assert is_list(opts)
    end

    @tag doc: """
         Verifies end-to-end that the :server module reaches the session.
         The test initializes a session through the router and checks that
         the session's state includes the server module.
         """
    @tag doc: """
         When a :server module doesn't implement the Wymcp.Server behaviour,
         Router.init/1 should log a warning but not crash. This allows duck-
         typed modules and avoids hard failures at startup.
         """
    test "warns when server module doesn't implement Wymcp.Server behaviour" do
      log =
        capture_log(fn ->
          Wymcp.Router.init(tools: [], server: String)
        end)

      assert log =~ "does not implement"
    end

    test "server module is stored in session state after initialize" do
      router_opts = Wymcp.Router.init(tools: [], server: TestMcpServer)

      init_conn =
        conn(
          :post,
          "/",
          JSON.encode!(%{
            "jsonrpc" => "2.0",
            "id" => 1,
            "method" => "initialize",
            "params" => %{
              "protocolVersion" => "2025-11-25",
              "capabilities" => %{},
              "clientInfo" => %{"name" => "test", "version" => "1.0"}
            }
          })
        )
        |> put_req_header("content-type", "application/json")
        |> Wymcp.Router.call(router_opts)

      assert init_conn.status == 200
      [session_id] = get_resp_header(init_conn, "mcp-session-id")
      state = Wymcp.Session.get_state(session_id)
      assert state.server == TestMcpServer
    end
  end

  describe "null request id" do
    test "handles request with null id" do
      session_id = initialize()

      body = %{
        "jsonrpc" => "2.0",
        "id" => nil,
        "method" => "tools/call",
        "params" => %{"name" => "nonexistent", "arguments" => %{}}
      }

      conn = call_with_session(body, session_id)
      resp = JSON.decode!(conn.resp_body)
      assert resp["id"] == nil
      assert resp["error"]["code"] == -32601
    end
  end
end
