defmodule Wymcp.ResponseTest do
  use ExUnit.Case, async: true

  import Plug.Test
  import Plug.Conn

  alias Wymcp.Response

  describe "send_json/2" do
    test "sends a JSON response with 200 status and correct content-type" do
      conn =
        conn(:post, "/")
        |> Response.send_json(%{"jsonrpc" => "2.0", "id" => 1, "result" => %{}})

      assert conn.status == 200
      assert get_resp_header(conn, "content-type") |> hd() =~ "application/json"
      assert JSON.decode!(conn.resp_body) == %{"jsonrpc" => "2.0", "id" => 1, "result" => %{}}
    end

    test "preserves an already-set status" do
      conn =
        conn(:post, "/")
        |> put_status(400)
        |> Response.send_json(%{"error" => "bad"})

      assert conn.status == 400
    end

    test "halts the connection" do
      conn =
        conn(:post, "/")
        |> Response.send_json(%{"ok" => true})

      assert conn.halted
    end
  end

  describe "send_plain_error/3" do
    test "sends the flat plain-JSON error object with the given status" do
      conn =
        conn(:post, "/")
        |> Response.send_plain_error(403, "Origin not allowed: http://evil.example")

      assert conn.status == 403

      assert JSON.decode!(conn.resp_body) ==
               %{"error" => "Origin not allowed: http://evil.example"}
    end

    test "sets the JSON content type" do
      conn = conn(:post, "/") |> Response.send_plain_error(400, "bad")

      assert get_resp_header(conn, "content-type") |> hd() =~ "application/json"
    end

    test "halts the connection" do
      conn = conn(:post, "/") |> Response.send_plain_error(401, "nope")

      assert conn.halted
    end
  end

  describe "send_rejection/4" do
    test "assembles the JSON-RPC dialect's -32600 envelope and halts" do
      conn =
        conn(:post, "/")
        |> Map.put(:body_params, %{"id" => 7, "method" => "tools/list"})
        |> assign(:wymcp_message_type, :request)
        |> Response.send_rejection(400, "Nope")

      assert conn.halted
      assert conn.status == 400

      assert JSON.decode!(conn.resp_body) == %{
               "jsonrpc" => "2.0",
               "id" => 7,
               "error" => %{
                 "code" => -32600,
                 "message" => "Invalid Request",
                 "data" => %{"error" => "Nope"}
               }
             }
    end

    @tag doc: """
         The sender derives the id itself (spec D4): no caller passes one, so
         no caller can choose otherwise. A failure with the id present means
         the derivation was moved back out to the call sites — the bug this
         topic exists to make unrepeatable.
         """
    test "derives a null id from a non-request message" do
      conn =
        conn(:post, "/")
        |> Map.put(:body_params, %{"jsonrpc" => "2.0", "id" => 7, "result" => %{}})
        |> assign(:wymcp_message_type, :response)
        |> Response.send_rejection(400, "Nope")

      assert JSON.decode!(conn.resp_body)["id"] == nil
    end

    test "sends the plain-JSON dialect's flat object, which carries no id" do
      conn =
        conn(:get, "/")
        |> Response.send_rejection(401, "Nope", :plain_json)

      assert conn.halted
      assert conn.status == 401
      assert JSON.decode!(conn.resp_body) == %{"error" => "Nope"}
    end
  end

  describe "rejection_id/1" do
    @tag doc: """
         The rule's two poles. A JSON-RPC response message carries an id the
         *server* minted for its own outstanding request, and echoing it back
         inside an error envelope offers a strict client a second, conflicting
         answer to that request; a genuine request's id is the one that must
         survive. A failure here means the positive :request clause was lost
         or widened and the 0.9.0 id collision is back.
         """
    test "answers the body id for a request and nil for a response message" do
      response =
        conn(:post, "/")
        |> Map.put(:body_params, %{"id" => 42, "result" => %{}})
        |> assign(:wymcp_message_type, :response)

      request =
        conn(:post, "/")
        |> Map.put(:body_params, %{"id" => 42, "method" => "tools/list"})
        |> assign(:wymcp_message_type, :request)

      assert Response.rejection_id(response) == nil
      assert Response.rejection_id(request) == 42
    end

    @tag doc: """
         conn.body_params is a %Plug.Conn.Unfetched{} wherever Plug.Parsers
         never ran, and its Access callbacks raise. The :request assign below
         is load-bearing: inverting the rule left the body read reachable only
         from that clause, so an unassigned conn exits through the catch-all
         and never touches Map.get/3 — which is what this test exists to pin.
         A failure here means the implementation reached for
         conn.body_params["id"] instead. The two forms genuinely discriminate:
         on that struct Access raises ArgumentError where Map.get/3 answers
         nil.
         """
    test "answers nil on a conn whose body was never parsed" do
      unparsed = conn(:get, "/") |> assign(:wymcp_message_type, :request)

      assert Response.rejection_id(unparsed) == nil
      assert Response.rejection_id(conn(:get, "/")) == nil
    end

    @tag doc: """
         The inverted rule's whole point (spec D1). Wymcp.Plugs.Classify tags
         :unknown when it cannot tell a request from a response — a truncated
         client answer, `{"jsonrpc":"2.0","id":42}`, lands here. That id may
         have been minted by the server, so it must not come back. A failure
         means the rule regressed to "everything except :response", which
         leaks the server-minted id on exactly the bodies where request and
         response are indistinguishable by construction.
         """
    test "answers nil for an unclassifiable body carrying an id" do
      unknown =
        conn(:post, "/")
        |> Map.put(:body_params, %{"jsonrpc" => "2.0", "id" => 42})
        |> assign(:wymcp_message_type, :unknown)

      assert Response.rejection_id(unknown) == nil
    end
  end
end
