defmodule Wymcp.Transport.SSETest do
  use ExUnit.Case, async: true

  @moduledoc """
  Tests for SSE event encoding.

  The MCP Streamable HTTP transport uses Server-Sent Events to stream
  JSON-RPC messages from server to client. Each event has an optional
  ID (for resumability) and a data field containing a JSON-RPC message.

  The SSE format is: `id: <id>\\ndata: <json>\\n\\n`
  Messages MUST NOT contain embedded newlines.
  """

  alias Wymcp.Transport.SSE

  describe "encode/2" do
    test "encodes a JSON-RPC message as an SSE event with ID" do
      message = %{"jsonrpc" => "2.0", "id" => 1, "result" => %{}}
      event = SSE.encode(message, "evt-1")

      assert event == "id: evt-1\ndata: #{JSON.encode!(message)}\n\n"
    end

    test "encodes without ID when nil" do
      message = %{"jsonrpc" => "2.0", "method" => "notifications/progress"}
      event = SSE.encode(message, nil)

      assert event == "data: #{JSON.encode!(message)}\n\n"
    end
  end

  describe "encode_empty/1" do
    test "encodes an empty priming event with ID" do
      event = SSE.encode_empty("stream-1")
      assert event == "id: stream-1\ndata: \n\n"
    end
  end
end
