defmodule Wymcp.Plugs.SessionTest do
  use ExUnit.Case, async: true

  import Plug.Test
  import Plug.Conn

  alias Wymcp.Plugs.Session, as: SessionPlug
  alias Wymcp.Session
  alias Wymcp.Testing

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
      Session.start_session(Testing.build_session_opts())

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
      |> assign(:wymcp_message_type, :request)
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
       A notification has no id by construction, so the rejection-id rule
       gives none and the 404 carries no envelope. The MCP spec still requires
       the 404 status for the stale-session signal, so the reconciliation is
       404 + empty body. An id-less envelope would be spec-legal here; empty
       is the choice, because the status already names the one next action.
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
       A response message's `id` refers to a request the server already sent,
       so the rejection-id rule gives nil and the 404 carries no envelope.
       Echoing that id would be the actual JSON-RPC violation — a second
       answer to an outstanding request. HTTP 404 alone is the right signal.
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
       Spec D2 — the hole the topic closes. A truncated client answer,
       `{"jsonrpc":"2.0","id":42}`, tags :unknown, so under the old branch
       condition (`== :response or is_nil(request_id)`) it met a dead session
       and got the server-minted id back inside a -32001 envelope. The 404 now
       carries an envelope exactly when the rule yields an id. A failure with a
       JSON body here means the branch condition was rewritten back to reading
       the body's id directly.
       """
  test "responds 404 with empty body for a stale-session unclassifiable message" do
    conn =
      conn(:post, "/")
      |> put_req_header("mcp-session-id", "bogus")
      |> Map.put(:body_params, %{"jsonrpc" => "2.0", "id" => 42})
      |> assign(:wymcp_message_type, :unknown)
      |> SessionPlug.call(SessionPlug.init([]))

    assert conn.status == 404
    assert conn.halted
    assert conn.resp_body == ""
  end

  @tag doc: """
       The other side of D2: a real request meeting a dead session still gets
       the SDK-matching envelope with its id. Pinned beside the empty-body case
       because the two together are the branch — a change that empties both is
       as wrong as one that fills both.
       """
  test "a stale-session request keeps its id in the -32001 envelope" do
    conn =
      conn(:post, "/")
      |> put_req_header("mcp-session-id", "bogus")
      |> Map.put(:body_params, %{"jsonrpc" => "2.0", "id" => 7, "method" => "tools/list"})
      |> assign(:wymcp_message_type, :request)
      |> SessionPlug.call(SessionPlug.init([]))

    assert conn.status == 404
    body = JSON.decode!(conn.resp_body)
    assert body["id"] == 7
    assert body["error"]["code"] == -32001
  end

  @tag doc: """
       tools/list and tools/call are lifecycle-exempt because clients
       (via mcp-remote) send them concurrently with notifications/initialized.
       The session may still be :initializing when they arrive.
       """
  test "allows tools/list when session is still initializing" do
    {:ok, _pid, session_id} =
      Session.start_session(Testing.build_session_opts())

    conn =
      conn(:post, "/")
      |> put_req_header("mcp-session-id", session_id)
      |> put_req_header("mcp-protocol-version", "2025-11-25")
      |> Map.put(:body_params, %{"method" => "tools/list", "id" => 1})
      |> SessionPlug.call(SessionPlug.init([]))

    refute conn.halted
  end

  @tag doc: """
       The lifecycle gate's 400. resources/list is neither session-exempt nor
       lifecycle-exempt, so it is refused while the session is still
       :initializing. Asserting the echoed id pins send_rejection/4's
       derivation at this call site: the branch has no other coverage anywhere
       in the suite, so a mistyped status or a lost derivation would otherwise
       ship green. The explicit :request assign is load-bearing — without it
       the fixture rides the rule's catch-all and pins nothing.
       """
  test "rejects a non-exempt method with 400 while the session is still initializing" do
    {:ok, _pid, session_id} = Session.start_session(Testing.build_session_opts())

    conn =
      conn(:post, "/")
      |> put_req_header("mcp-session-id", session_id)
      |> put_req_header("mcp-protocol-version", "2025-11-25")
      |> Map.put(:body_params, %{"method" => "resources/list", "id" => 5})
      |> assign(:wymcp_message_type, :request)
      |> SessionPlug.call(SessionPlug.init([]))

    assert conn.halted
    assert conn.status == 400
    body = JSON.decode!(conn.resp_body)
    assert body["id"] == 5
    assert body["error"]["code"] == -32600
    assert body["error"]["data"]["error"] =~ "Session not yet initialized"
  end

  test "allows notifications/initialized when session is still initializing" do
    {:ok, _pid, session_id} =
      Session.start_session(Testing.build_session_opts())

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
      Session.start_session(Testing.build_session_opts())

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
      Session.start_session(Testing.build_session_opts())

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

    @tag doc: """
         Spec D4 reaching the mismatch 400: protocol_version_mismatch/1 IS
         reachable on the response path (resolve_session_for_response/1 →
         check_protocol_version/2), so a client answering a server-initiated
         call while sending a stale version header used to get the server's own
         id back. The two spec rules compose here: 400 for the bad header
         (spec.md's G2), id-less body for the message kind (D1, delivered by
         the sender's arity drop). A failure means this site was left off the
         rule again — it has been the last holdout twice.
         """
    test "a response message's mismatch 400 carries a null id" do
      {:ok, _pid, session_id} = start_ready_session()

      conn =
        conn(:post, "/")
        |> put_req_header("mcp-session-id", session_id)
        |> put_req_header("mcp-protocol-version", "2024-01-01")
        |> Map.put(:body_params, %{"jsonrpc" => "2.0", "id" => 42, "result" => %{}})
        |> assign(:wymcp_message_type, :response)
        |> SessionPlug.call(SessionPlug.init([]))

      assert conn.status == 400
      assert JSON.decode!(conn.resp_body)["id"] == nil
    end

    @tag doc: """
         The request path keeps its id — the branch survey C1 found already
         tested twice (session_test.exs and the router-driven describe below),
         but where neither test asserted body["id"]. This adds the id
         assertion to a tested branch; it is not first coverage of the branch.
         """
    test "a request's mismatch 400 keeps its id" do
      {:ok, _pid, session_id} = start_ready_session()

      conn =
        conn(:post, "/")
        |> put_req_header("mcp-session-id", session_id)
        |> put_req_header("mcp-protocol-version", "2024-01-01")
        |> Map.put(:body_params, %{"jsonrpc" => "2.0", "id" => 7, "method" => "tools/list"})
        |> assign(:wymcp_message_type, :request)
        |> SessionPlug.call(SessionPlug.init([]))

      assert conn.status == 400
      assert JSON.decode!(conn.resp_body)["id"] == 7
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
      Session.start_session(Testing.build_session_opts())

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
