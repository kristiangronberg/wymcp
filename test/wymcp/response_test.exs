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

  describe "send_error/5" do
    test "assembles the JSON-RPC dialect's -32600 envelope and halts" do
      conn = Response.send_error(conn(:post, "/"), 400, 7, "Nope")

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

    test "sends the plain-JSON dialect's flat object and ignores the request id" do
      conn = Response.send_error(conn(:get, "/"), 401, 7, "Nope", :plain_json)

      assert conn.halted
      assert conn.status == 401
      assert JSON.decode!(conn.resp_body) == %{"error" => "Nope"}
    end
  end

  describe "rejection_id/1" do
    @tag doc: """
         The id rule for a rejection envelope (spec D5). A JSON-RPC response
         message carries an id the *server* minted for its own outstanding
         request; echoing it back inside an error envelope offers a strict
         client a second, conflicting answer to that request. A failure here
         means the :response guard was lost and the 0.9.0 id collision is back.
         """
    test "answers nil for a response message and the body id otherwise" do
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
         Runs on the GET/DELETE routes, where Plug.Parsers never ran and
         conn.body_params is a %Plug.Conn.Unfetched{} whose Access callbacks
         raise. A failure here means the implementation reached for
         conn.body_params["id"] instead of Map.get/3.
         """
    test "answers nil on a conn whose body was never parsed" do
      assert Response.rejection_id(conn(:get, "/")) == nil
    end
  end
end
