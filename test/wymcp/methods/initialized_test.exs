defmodule Wymcp.Methods.InitializedTest do
  use ExUnit.Case, async: true

  @moduledoc """
  Tests for the notifications/initialized handler.

  Per MCP spec, notifications/initialized is a client-to-server notification
  sent after the client has processed the initialize response. The server
  acknowledges with an empty response. This is a fire-and-forget message —
  no request id is required.
  """

  import Plug.Test

  test "returns empty response for initialized notification" do
    conn =
      conn(:post, "/")
      |> Map.put(:body_params, %{
        "jsonrpc" => "2.0",
        "method" => "notifications/initialized"
      })

    result = Wymcp.Methods.Initialized.run(conn)
    body = JSON.decode!(result.resp_body)

    assert body == %{}
  end
end
