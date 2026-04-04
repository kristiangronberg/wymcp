defmodule Wymcp.ResponseTest do
  use ExUnit.Case, async: true

  @moduledoc """
  Tests for the Wymcp.Response module.

  Response is the lowest-level output module — it takes a Plug.Conn and a map,
  encodes the map as JSON, and sends it. It preserves any previously-set status
  code (e.g., 400 for validation errors) rather than blindly overwriting with 200.
  The connection is halted after sending to prevent downstream plugs from
  double-sending.
  """

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
end
