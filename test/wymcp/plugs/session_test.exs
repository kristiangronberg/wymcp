defmodule Wymcp.Plugs.SessionTest do
  use ExUnit.Case, async: true

  @moduledoc """
  Tests for the session lookup plug.

  The session plug extracts the Mcp-Session-Id header, looks up the
  session GenServer, resets the idle timer, and stores the pid in
  conn.assigns. Initialize and ping requests are exempt — they don't
  require a session header.

  Non-exempt requests without a valid session header are rejected with
  HTTP 400 (JSON-RPC -32600 invalid_request). This follows the MCP spec:
  "Servers that require a session ID SHOULD respond to requests without
  an MCP-Session-Id header with HTTP 400 Bad Request."

  Non-exempt messages *with* a session header that the registry does
  not recognise are rejected with HTTP 404. This follows the MCP
  2025-11-25 spec, Streamable HTTP / Session Management clauses 3 and
  4: a server MAY terminate a session at any time and MUST then
  respond to requests carrying that ID with 404; the client MUST start
  a new session by issuing a fresh InitializeRequest. A
  server-restart-wiped registry is, from the spec's perspective, an
  instance of clause 3 — there is no "I never saw this ID" branch
  distinct from "I terminated this ID".

  The 404 body branches on JSON-RPC message kind, since JSON-RPC 2.0
  forbids responding to notifications and to responses:

    * Request (`id` present, message-kind not `:response`) — body is
      `{"jsonrpc":"2.0","id":<id>,"error":{"code":-32001,"message":
      "Session terminated"}}`, matching the TypeScript SDK exactly
      (no `data` field).
    * Notification (no `id`) — HTTP 404 with empty body.
    * Response message (`wymcp_message_type == :response`) — HTTP 404
      with empty body.

  After session lookup, the plug validates the MCP-Protocol-Version
  header against the version negotiated during initialize. Missing or
  mismatched headers are rejected with 400. This applies to both
  request messages (via resolve_session) and response messages (via
  resolve_session_for_response).
  """

  import Plug.Test
  import Plug.Conn

  alias Wymcp.Plugs.Session, as: SessionPlug
  alias Wymcp.Session

  test "passes through initialize requests without session header" do
    conn =
      conn(:post, "/")
      |> Map.put(:body_params, %{"method" => "initialize"})
      |> SessionPlug.call(SessionPlug.init([]))

    refute conn.halted
  end

  test "passes through ping requests without session header" do
    conn =
      conn(:post, "/")
      |> Map.put(:body_params, %{"method" => "ping"})
      |> SessionPlug.call(SessionPlug.init([]))

    refute conn.halted
  end

  test "assigns session pid when valid session ID is present" do
    {:ok, pid, session_id} =
      Session.start_session(%{
        client_capabilities: %{},
        client_info: %{"name" => "test", "version" => "1.0"},
        protocol_version: "2025-11-25",
        tools: [],
        auth: nil
      })

    Session.mark_ready(pid)

    conn =
      conn(:post, "/")
      |> put_req_header("mcp-session-id", session_id)
      |> put_req_header("mcp-protocol-version", "2025-11-25")
      |> Map.put(:body_params, %{"method" => "tools/list"})
      |> SessionPlug.call(SessionPlug.init([]))

    refute conn.halted
    assert conn.assigns[:wymcp_session_pid] == pid
    assert conn.assigns[:wymcp_session_id] == session_id
  end

  @tag doc: """
       Non-exempt requests without Mcp-Session-Id must be rejected with
       400. The MCP spec says: servers that require a session ID SHOULD
       respond with HTTP 400 Bad Request. A failure here means the plug
       is still falling through sessionless.
       """
  test "rejects non-exempt requests without session header with 400" do
    conn =
      conn(:post, "/")
      |> Map.put(:body_params, %{"method" => "tools/list", "id" => 1})
      |> SessionPlug.call(SessionPlug.init([]))

    assert conn.halted
    assert conn.status == 400
    body = JSON.decode!(conn.resp_body)
    assert body["error"]["code"] == -32600
    assert body["error"]["data"]["error"] =~ "Missing Mcp-Session-Id"
  end

  @tag doc: """
       Per MCP 2025-11-25 (Streamable HTTP / Session Management, clauses
       3 and 4), a request bearing an unrecognised Mcp-Session-Id MUST
       be answered with HTTP 404. The body uses JSON-RPC code -32001 and
       message "Session terminated" — matching the TypeScript SDK
       exactly (packages/server/src/server/streamableHttp.ts, where the
       SDK throws `new McpError(-32001, "Session terminated")` with no
       data field). Failure here means we have regressed to the old
       silent fallthrough or drifted off the SDK wire shape.
       """
  test "responds 404 with -32001 'Session terminated' for stale-session request" do
    conn =
      conn(:post, "/")
      |> put_req_header("mcp-session-id", "bogus")
      |> Map.put(:body_params, %{"method" => "tools/list", "id" => 1})
      |> SessionPlug.call(SessionPlug.init([]))

    assert conn.status == 404
    assert conn.halted

    body = JSON.decode!(conn.resp_body)
    assert body["jsonrpc"] == "2.0"
    assert body["id"] == 1
    assert body["error"]["code"] == -32001
    assert body["error"]["message"] == "Session terminated"
    refute Map.has_key?(body["error"], "data")
    refute Map.has_key?(conn.assigns, :wymcp_session_pid)
    refute Map.has_key?(conn.assigns, :wymcp_session_warning)
  end

  @tag doc: """
       JSON-RPC 2.0 forbids responding to notifications. The MCP spec
       still requires HTTP 404 for the stale-session signal, so the
       reconciliation is: 404 status + empty body + no JSON-RPC
       envelope. Returning an envelope with id:null would itself be a
       JSON-RPC violation.
       """
  test "responds 404 with empty body for stale-session notification" do
    conn =
      conn(:post, "/")
      |> put_req_header("mcp-session-id", "bogus")
      |> Map.put(:body_params, %{"method" => "notifications/initialized"})
      |> SessionPlug.call(SessionPlug.init([]))

    assert conn.status == 404
    assert conn.halted
    assert conn.resp_body == ""
    refute Map.has_key?(conn.assigns, :wymcp_session_pid)
  end

  @tag doc: """
       Response messages (client-to-server answers to server-initiated
       requests) carry an `id` referring to a request the server already
       sent. Replying to a response with another JSON-RPC error would
       itself be a JSON-RPC violation — you do not respond to responses.
       HTTP 404 alone is the right signal, with empty body.
       """
  test "responds 404 with empty body for stale-session response message" do
    conn =
      conn(:post, "/")
      |> put_req_header("mcp-session-id", "bogus")
      |> Map.put(:body_params, %{
        "jsonrpc" => "2.0",
        "id" => 42,
        "result" => %{"role" => "assistant"}
      })
      |> assign(:wymcp_message_type, :response)
      |> SessionPlug.call(SessionPlug.init([]))

    assert conn.status == 404
    assert conn.halted
    assert conn.resp_body == ""
    refute Map.has_key?(conn.assigns, :wymcp_session_pid)
  end

  @tag doc: """
       tools/list and tools/call are lifecycle-exempt because clients
       (via mcp-remote) send them concurrently with notifications/initialized.
       The session may still be :initializing when they arrive.
       """
  test "allows tools/list when session is still initializing" do
    {:ok, _pid, session_id} =
      Session.start_session(%{
        client_capabilities: %{},
        client_info: %{"name" => "test", "version" => "1.0"},
        protocol_version: "2025-11-25",
        tools: [],
        auth: nil
      })

    conn =
      conn(:post, "/")
      |> put_req_header("mcp-session-id", session_id)
      |> put_req_header("mcp-protocol-version", "2025-11-25")
      |> Map.put(:body_params, %{"method" => "tools/list", "id" => 1})
      |> SessionPlug.call(SessionPlug.init([]))

    refute conn.halted
  end

  test "allows notifications/initialized when session is still initializing" do
    {:ok, _pid, session_id} =
      Session.start_session(%{
        client_capabilities: %{},
        client_info: %{"name" => "test", "version" => "1.0"},
        protocol_version: "2025-11-25",
        tools: [],
        auth: nil
      })

    conn =
      conn(:post, "/")
      |> put_req_header("mcp-session-id", session_id)
      |> put_req_header("mcp-protocol-version", "2025-11-25")
      |> Map.put(:body_params, %{"method" => "notifications/initialized"})
      |> SessionPlug.call(SessionPlug.init([]))

    refute conn.halted
  end

  @tag doc: """
       JSON-RPC responses (client answers to server-initiated requests
       like sampling/createMessage) must pass through the session plug
       like any other non-exempt message — they carry a session header
       and need the session pid resolved. But they must not be checked
       against the session-exempt methods list (they have no method).
       """
  test "resolves session for response messages" do
    {:ok, pid, session_id} =
      Session.start_session(%{
        client_capabilities: %{},
        client_info: %{"name" => "test", "version" => "1.0"},
        protocol_version: "2025-11-25",
        tools: [],
        auth: nil
      })

    Session.mark_ready(pid)

    conn =
      conn(:post, "/")
      |> put_req_header("mcp-session-id", session_id)
      |> put_req_header("mcp-protocol-version", "2025-11-25")
      |> Map.put(:body_params, %{
        "jsonrpc" => "2.0",
        "id" => 42,
        "result" => %{"role" => "assistant"}
      })
      |> assign(:wymcp_message_type, :response)
      |> SessionPlug.call(SessionPlug.init([]))

    refute conn.halted
    assert conn.assigns[:wymcp_session_pid] == pid
  end

  test "rejects response messages without session header with 400" do
    conn =
      conn(:post, "/")
      |> Map.put(:body_params, %{
        "jsonrpc" => "2.0",
        "id" => 42,
        "result" => %{"role" => "assistant"}
      })
      |> assign(:wymcp_message_type, :response)
      |> SessionPlug.call(SessionPlug.init([]))

    assert conn.halted
    assert conn.status == 400
  end

  test "allows tools/list when session is ready" do
    {:ok, pid, session_id} =
      Session.start_session(%{
        client_capabilities: %{},
        client_info: %{"name" => "test", "version" => "1.0"},
        protocol_version: "2025-11-25",
        tools: [],
        auth: nil
      })

    Session.mark_ready(pid)

    conn =
      conn(:post, "/")
      |> put_req_header("mcp-session-id", session_id)
      |> put_req_header("mcp-protocol-version", "2025-11-25")
      |> Map.put(:body_params, %{"method" => "tools/list", "id" => 2})
      |> SessionPlug.call(SessionPlug.init([]))

    refute conn.halted
  end

  describe "MCP-Protocol-Version header validation" do
    @tag doc: """
         The MCP spec (2025-11-25) requires clients to send the
         MCP-Protocol-Version header on all requests after initialize.
         However, major clients (Claude Desktop) omit it, so missing
         header is allowed through. Only a wrong value is rejected.
         """
    test "allows request with missing MCP-Protocol-Version header" do
      {:ok, _pid, session_id} = start_ready_session()

      conn =
        conn(:post, "/")
        |> put_req_header("mcp-session-id", session_id)
        |> Map.put(:body_params, %{"method" => "tools/list", "id" => 1})
        |> SessionPlug.call(SessionPlug.init([]))

      refute conn.halted
    end

    @tag doc: """
         When the client sends a version that differs from the negotiated
         one, the server must reject with 400. This prevents a client from
         switching protocol mid-session.
         """
    test "rejects request with mismatched MCP-Protocol-Version header" do
      {:ok, _pid, session_id} = start_ready_session()

      conn =
        conn(:post, "/")
        |> put_req_header("mcp-session-id", session_id)
        |> put_req_header("mcp-protocol-version", "2024-01-01")
        |> Map.put(:body_params, %{"method" => "tools/list", "id" => 1})
        |> SessionPlug.call(SessionPlug.init([]))

      assert conn.halted
      assert conn.status == 400
      body = JSON.decode!(conn.resp_body)
      assert body["error"]["code"] == -32600
      assert body["error"]["data"]["error"] =~ "MCP-Protocol-Version"
    end

    test "passes request with correct MCP-Protocol-Version header" do
      {:ok, _pid, session_id} = start_ready_session()

      conn =
        conn(:post, "/")
        |> put_req_header("mcp-session-id", session_id)
        |> put_req_header("mcp-protocol-version", "2025-11-25")
        |> Map.put(:body_params, %{"method" => "tools/list", "id" => 1})
        |> SessionPlug.call(SessionPlug.init([]))

      refute conn.halted
    end

    @tag doc: """
         Response messages (client answers to server-initiated requests)
         go through resolve_session_for_response. Missing header is
         allowed (client compatibility), but wrong value is rejected.
         """
    test "allows response message with missing MCP-Protocol-Version header" do
      {:ok, _pid, session_id} = start_ready_session()

      conn =
        conn(:post, "/")
        |> put_req_header("mcp-session-id", session_id)
        |> Map.put(:body_params, %{
          "jsonrpc" => "2.0",
          "id" => 42,
          "result" => %{"role" => "assistant"}
        })
        |> assign(:wymcp_message_type, :response)
        |> SessionPlug.call(SessionPlug.init([]))

      refute conn.halted
    end

    test "passes response message with correct MCP-Protocol-Version header" do
      {:ok, _pid, session_id} = start_ready_session()

      conn =
        conn(:post, "/")
        |> put_req_header("mcp-session-id", session_id)
        |> put_req_header("mcp-protocol-version", "2025-11-25")
        |> Map.put(:body_params, %{
          "jsonrpc" => "2.0",
          "id" => 42,
          "result" => %{"role" => "assistant"}
        })
        |> assign(:wymcp_message_type, :response)
        |> SessionPlug.call(SessionPlug.init([]))

      refute conn.halted
    end
  end

  defp start_ready_session do
    {:ok, pid, session_id} =
      Session.start_session(%{
        client_capabilities: %{},
        client_info: %{"name" => "test", "version" => "1.0"},
        protocol_version: "2025-11-25",
        tools: [],
        auth: nil
      })

    Session.mark_ready(pid)
    {:ok, pid, session_id}
  end

  describe "MCP-Protocol-Version header (pre-2025-06-18 sessions)" do
    @router_opts Wymcp.Router.init(tools: [])

    @tag doc: """
         Sessions negotiated to 2025-03-26 must not be 400'd for
         omitting the MCP-Protocol-Version header. The header is a
         2025-06-18 feature; older clients have no way to send it.
         """
    test "ping after init succeeds without the header for 2025-03-26 sessions" do
      session_id = initialize_with_version("2025-03-26")

      ping_body = %{"jsonrpc" => "2.0", "id" => 99, "method" => "ping"}

      conn =
        :post
        |> conn("/", JSON.encode!(ping_body))
        |> put_req_header("content-type", "application/json")
        |> put_req_header("mcp-session-id", session_id)
        |> Wymcp.Router.call(@router_opts)

      assert conn.status == 200
      resp = JSON.decode!(conn.resp_body)
      assert resp["result"] == %{}
    end

    @tag doc: """
         For 2025-03-26 sessions, even an explicit (incorrect) header
         must NOT trigger a mismatch error — the header is not part of
         that revision's contract.
         """
    test "follow-up succeeds even with stale header for 2025-03-26 sessions" do
      session_id = initialize_with_version("2025-03-26")

      list_body = %{"jsonrpc" => "2.0", "id" => 99, "method" => "tools/list"}

      conn =
        :post
        |> conn("/", JSON.encode!(list_body))
        |> put_req_header("content-type", "application/json")
        |> put_req_header("mcp-session-id", session_id)
        |> put_req_header("mcp-protocol-version", "2025-11-25")
        |> Wymcp.Router.call(@router_opts)

      assert conn.status == 200
    end

    test "mismatched header still rejected on 2025-06-18 sessions" do
      session_id = initialize_with_version("2025-06-18")

      list_body = %{"jsonrpc" => "2.0", "id" => 99, "method" => "tools/list"}

      conn =
        :post
        |> conn("/", JSON.encode!(list_body))
        |> put_req_header("content-type", "application/json")
        |> put_req_header("mcp-session-id", session_id)
        |> put_req_header("mcp-protocol-version", "2025-03-26")
        |> Wymcp.Router.call(@router_opts)

      assert conn.status == 400
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
  end
end
