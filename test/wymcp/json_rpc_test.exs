defmodule Wymcp.JsonRpcTest do
  use ExUnit.Case, async: true

  @moduledoc """
  Tests for the Wymcp.JsonRpc module.

  JsonRpc provides two categories of functionality:
  1. Response envelope construction (success_response, error_response) — pure
     functions that build JSON-RPC 2.0 compliant maps
  2. MCP schema validation — validates incoming requests against the MCP protocol
     JSON Schema (2020-12 dialect) shipped in priv/schema.json, using JSV

  The error codes follow the JSON-RPC 2.0 specification:
  - -32700: Parse error
  - -32600: Invalid Request
  - -32601: Method not found
  - -32602: Invalid params
  - -32603: Internal error
  """

  alias Wymcp.JsonRpc

  describe "success_response/2" do
    test "wraps result in JSON-RPC 2.0 envelope" do
      response = JsonRpc.success_response(42, %{"tools" => []})

      assert response == %{
               "jsonrpc" => "2.0",
               "id" => 42,
               "result" => %{"tools" => []}
             }
    end
  end

  describe "error_response/3" do
    test "builds parse_error response with code -32700" do
      response = JsonRpc.error_response(:parse_error, 1, %{detail: "bad json"})

      assert response["jsonrpc"] == "2.0"
      assert response["id"] == 1
      assert response["error"]["code"] == -32700
      assert response["error"]["message"] == "Parse error"
      assert response["error"]["data"] == %{detail: "bad json"}
    end

    test "builds method_not_found response with code -32601" do
      response = JsonRpc.error_response(:method_not_found, 2, %{})
      assert response["error"]["code"] == -32601
    end

    test "builds invalid_params response with code -32602" do
      response = JsonRpc.error_response(:invalid_params, 3, %{})
      assert response["error"]["code"] == -32602
    end

    test "builds invalid_request response with code -32600" do
      response = JsonRpc.error_response(:invalid_request, 4, %{})
      assert response["error"]["code"] == -32600
    end

    test "builds internal_error response with code -32603" do
      response = JsonRpc.error_response(:internal_error, 5, %{})
      assert response["error"]["code"] == -32603
    end
  end

  describe "validate_mcp_request/2" do
    test "returns :ok for a valid JSON-RPC request" do
      request = %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "tools/list"
      }

      assert :ok = JsonRpc.validate_mcp_request("JSONRPCMessage", request)
    end

    test "returns error for invalid request" do
      assert {:error, _reason} = JsonRpc.validate_mcp_request("JSONRPCMessage", %{"bad" => true})
    end
  end
end
