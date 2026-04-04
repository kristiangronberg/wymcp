defmodule Wymcp.Methods.UnknownTest do
  use ExUnit.Case, async: true

  @moduledoc """
  Tests for the Wymcp.Methods.Unknown handler.

  Unknown handles any JSON-RPC method the server does not recognize. Per
  the JSON-RPC 2.0 spec, unrecognized methods must receive a -32601
  (Method not found) error response. The original request is included
  in the error's `data` field for debugging.
  """

  import Plug.Test

  alias Wymcp.Methods.Unknown

  test "returns method_not_found error with code -32601" do
    body = %{
      "jsonrpc" => "2.0",
      "id" => 42,
      "method" => "nonexistent/method",
      "params" => %{}
    }

    conn =
      conn(:post, "/")
      |> Map.put(:body_params, body)

    result = Unknown.run(conn)
    response = JSON.decode!(result.resp_body)

    assert response["jsonrpc"] == "2.0"
    assert response["id"] == 42
    assert response["error"]["code"] == -32601
    assert response["error"]["message"] == "Method not found"
  end

  test "includes the original request in error data" do
    body = %{
      "jsonrpc" => "2.0",
      "id" => 7,
      "method" => "tools/frobnicate",
      "params" => %{"foo" => "bar"}
    }

    conn =
      conn(:post, "/")
      |> Map.put(:body_params, body)

    result = Unknown.run(conn)
    response = JSON.decode!(result.resp_body)

    assert response["error"]["data"]["original_request"] == body
  end

  test "halts the connection" do
    body = %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => "nope"
    }

    conn =
      conn(:post, "/")
      |> Map.put(:body_params, body)

    result = Unknown.run(conn)
    assert result.halted
  end

  test "preserves the request id from the original request" do
    body = %{
      "jsonrpc" => "2.0",
      "id" => "string-id-99",
      "method" => "unknown"
    }

    conn =
      conn(:post, "/")
      |> Map.put(:body_params, body)

    result = Unknown.run(conn)
    response = JSON.decode!(result.resp_body)

    assert response["id"] == "string-id-99"
  end
end
