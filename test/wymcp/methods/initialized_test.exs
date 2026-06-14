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
  import Plug.Conn

  alias Wymcp.Methods.Initialized
  alias Wymcp.Session

  test "returns empty response for initialized notification" do
    {:ok, pid, _session_id} =
      Session.start_session(%{
        client_capabilities: %{},
        client_info: %{"name" => "test", "version" => "1.0"},
        protocol_version: "2025-11-25",
        tools: [],
        auth: nil
      })

    conn =
      conn(:post, "/")
      |> Map.put(:body_params, %{
        "jsonrpc" => "2.0",
        "method" => "notifications/initialized"
      })
      |> assign(:wymcp_session_pid, pid)

    result = Initialized.run(conn)
    body = JSON.decode!(result.resp_body)

    assert body == %{}
  end
end
