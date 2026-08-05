defmodule Wymcp.Plugs.SingletonHeadersTest do
  @moduledoc """
  The plug is called directly with an explicitly-built conn: on POST it runs
  after Plug.Parsers and Wymcp.Plugs.Classify, so the tests that exercise the
  rejection envelope set :body_params and :wymcp_message_type by hand rather
  than routing a request. The plain-JSON tests deliberately leave
  :body_params unfetched — that is the real GET/DELETE shape.
  """

  use ExUnit.Case, async: true

  import Plug.Test
  import Plug.Conn

  alias Wymcp.Plugs.SingletonHeaders

  @json_rpc SingletonHeaders.init([])
  @plain_json SingletonHeaders.init(error_dialect: :plain_json)

  describe "reject policy" do
    @tag doc: """
         get_req_header/2 returns every value of a repeated header — the
         pre-0.9.0 single-element case head crashed with CaseClauseError (a
         500) on a duplicated Mcp-Session-Id. Duplication must be a clean 400
         naming the header, and it must fail closed: no first-value-wins, even
         when both values are the same registered session id. Relocated here
         from session_test.exs when Plugs.Session lost its duplicate arm.
         """
    test "rejects a duplicated Mcp-Session-Id with 400 in the JSON-RPC dialect" do
      conn =
        conn(:post, "/")
        |> put_req_header("mcp-session-id", "abc")
        |> prepend_req_headers([{"mcp-session-id", "abc"}])
        |> Map.put(:body_params, %{"method" => "tools/list", "id" => 1})
        |> assign(:wymcp_message_type, :request)
        |> SingletonHeaders.call(@json_rpc)

      assert conn.halted
      assert conn.status == 400
      body = JSON.decode!(conn.resp_body)
      assert body["id"] == 1
      assert body["error"]["code"] == -32600

      assert body["error"]["data"]["error"] ==
               "Duplicated Mcp-Session-Id header. Send exactly one Mcp-Session-Id header."
    end

    @tag doc: """
         Totality is checked before value comparison: a duplicated
         MCP-Protocol-Version is a 400 even when one of the values matches the
         version negotiated at initialize. Relocated here from
         session_test.exs; the check runs before any session pid resolves, so
         it no longer sees the negotiated version at all.
         """
    test "rejects a duplicated MCP-Protocol-Version even when a value would match" do
      conn =
        conn(:post, "/")
        |> put_req_header("mcp-protocol-version", "2025-11-25")
        |> prepend_req_headers([{"mcp-protocol-version", "2025-11-25"}])
        |> Map.put(:body_params, %{"method" => "tools/list", "id" => 1})
        |> assign(:wymcp_message_type, :request)
        |> SingletonHeaders.call(@json_rpc)

      assert conn.halted
      assert conn.status == 400

      assert JSON.decode!(conn.resp_body)["error"]["data"]["error"] ==
               "Duplicated MCP-Protocol-Version header. Send exactly one MCP-Protocol-Version header."
    end

    @tag doc: """
         The rejection of a JSON-RPC *response* message carries a null id, not
         the id the client echoed: that id was minted by the server for its own
         outstanding sampling/elicitation request, and answering it with an
         error envelope offers a strict client a second, conflicting answer.
         Relocated from session_test.exs, where this case pinned the opposite
         (the echoed id) before the fix.
         """
    test "rejects a duplicated header on a response message with a null id" do
      conn =
        conn(:post, "/")
        |> put_req_header("mcp-session-id", "abc")
        |> prepend_req_headers([{"mcp-session-id", "abc"}])
        |> Map.put(:body_params, %{
          "jsonrpc" => "2.0",
          "id" => 42,
          "result" => %{"role" => "assistant"}
        })
        |> assign(:wymcp_message_type, :response)
        |> SingletonHeaders.call(@json_rpc)

      assert conn.halted
      assert conn.status == 400
      body = JSON.decode!(conn.resp_body)
      assert body["id"] == nil

      assert body["error"]["data"]["error"] ==
               "Duplicated Mcp-Session-Id header. Send exactly one Mcp-Session-Id header."
    end

    @tag doc: """
         The GET/DELETE shape: no body was ever parsed, so conn.body_params is
         a %Plug.Conn.Unfetched{} whose Access callbacks raise. A failure here
         is most likely the rejection reaching for conn.body_params["id"].
         """
    test "rejects in the plain-JSON dialect on a conn with no parsed body" do
      conn =
        conn(:get, "/")
        |> put_req_header("mcp-session-id", "abc")
        |> prepend_req_headers([{"mcp-session-id", "def"}])
        |> SingletonHeaders.call(@plain_json)

      assert conn.halted
      assert conn.status == 400

      assert JSON.decode!(conn.resp_body) == %{
               "error" =>
                 "Duplicated Mcp-Session-Id header. Send exactly one Mcp-Session-Id header."
             }
    end

    test "passes a request carrying one value of each singleton header" do
      conn =
        conn(:post, "/")
        |> put_req_header("mcp-session-id", "abc")
        |> put_req_header("mcp-protocol-version", "2025-11-25")
        |> SingletonHeaders.call(@json_rpc)

      refute conn.halted
    end

    test "passes a request carrying none of the singleton headers" do
      conn = SingletonHeaders.call(conn(:post, "/"), @json_rpc)

      refute conn.halted
    end

    @tag doc: """
         The @singleton_headers table's order is wire-visible: a request
         duplicating two reject-class headers is answered for whichever row
         comes first. Reordering the attribute silently changes which header
         the operator is told about, so the order is pinned here. The halt also
         means the degrade row never ran — no :wymcp_last_event_id assign.
         """
    test "answers for the first table row when two reject-class headers are duplicated" do
      conn =
        conn(:post, "/")
        |> put_req_header("mcp-session-id", "abc")
        |> prepend_req_headers([{"mcp-session-id", "abc"}])
        |> put_req_header("mcp-protocol-version", "2025-11-25")
        |> prepend_req_headers([{"mcp-protocol-version", "2025-11-25"}])
        |> put_req_header("last-event-id", "evt-1")
        |> Map.put(:body_params, %{"method" => "tools/list", "id" => 1})
        |> SingletonHeaders.call(@json_rpc)

      assert conn.status == 400

      assert JSON.decode!(conn.resp_body)["error"]["data"]["error"] =~
               "Duplicated Mcp-Session-Id"

      refute Map.has_key?(conn.assigns, :wymcp_last_event_id)
    end
  end

  describe "degrade policy" do
    test "assigns :missing when no Last-Event-ID header is present" do
      conn = SingletonHeaders.call(conn(:get, "/"), @plain_json)

      refute conn.halted
      assert conn.assigns[:wymcp_last_event_id] == :missing
    end

    test "assigns {:ok, value} for a single Last-Event-ID header" do
      conn =
        conn(:get, "/")
        |> put_req_header("last-event-id", "evt-7")
        |> SingletonHeaders.call(@plain_json)

      refute conn.halted
      assert conn.assigns[:wymcp_last_event_id] == {:ok, "evt-7"}
    end

    @tag doc: """
         Degrade, not reject: a duplicated Last-Event-ID is a resumption hint,
         not a routing fact, so the request proceeds and the stream discards
         the hint. Before this check existed, List.first/1 silently picked one
         of the two values.
         """
    test "assigns :duplicated for a repeated Last-Event-ID header and does not halt" do
      conn =
        conn(:get, "/")
        |> put_req_header("last-event-id", "evt-7")
        |> prepend_req_headers([{"last-event-id", "evt-3"}])
        |> SingletonHeaders.call(@plain_json)

      refute conn.halted
      assert conn.assigns[:wymcp_last_event_id] == :duplicated
    end
  end
end
