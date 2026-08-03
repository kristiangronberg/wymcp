defmodule Wymcp.Transport.SSETest do
  use ExUnit.Case, async: true

  alias Wymcp.Transport.SSE

  describe "frame/2" do
    test "frames pre-encoded JSON as an SSE event with ID" do
      json = JSON.encode!(%{"jsonrpc" => "2.0", "id" => 1, "result" => %{}})
      assert SSE.frame(json, "evt-1") == "id: evt-1\ndata: #{json}\n\n"
    end

    test "frames without ID when nil" do
      json = JSON.encode!(%{"jsonrpc" => "2.0", "method" => "notifications/progress"})
      assert SSE.frame(json, nil) == "data: #{json}\n\n"
    end
  end

  describe "frame_empty/1" do
    test "frames an empty priming event with ID" do
      assert SSE.frame_empty("stream-1") == "id: stream-1\ndata: \n\n"
    end
  end
end
