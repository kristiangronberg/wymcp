defmodule Wymcp.Methods.LoggingSetLevelTest do
  use ExUnit.Case, async: true

  @moduledoc """
  Tests for the logging/setLevel method handler.

  logging/setLevel allows the client to configure the minimum log level
  for the session. The server stores the level and only sends
  notifications/message at or above that severity. The response is an
  empty JSON-RPC success result.

  Invalid log levels produce a JSON-RPC invalid_params error.
  """

  import Plug.Test
  import Plug.Conn

  alias Wymcp.{Methods.LoggingSetLevel, Session}

  defp build_conn(level) do
    body = %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => "logging/setLevel",
      "params" => %{"level" => level}
    }

    {:ok, pid, session_id} =
      Session.start_session(%{
        client_capabilities: %{},
        client_info: %{"name" => "test", "version" => "1.0"},
        protocol_version: "2025-11-25",
        tools: [],
        auth: nil
      })

    Session.mark_ready(pid)

    conn(:post, "/")
    |> put_req_header("content-type", "application/json")
    |> Map.put(:body_params, body)
    |> assign(:wymcp_session_pid, pid)
    |> assign(:wymcp_session_id, session_id)
  end

  test "sets log level on the session and returns empty result" do
    conn = build_conn("warning")
    result = LoggingSetLevel.run(conn)
    body = JSON.decode!(result.resp_body)

    assert body["result"] == %{}

    pid = conn.assigns[:wymcp_session_pid]
    state = Session.get_state(pid)
    assert state.log_level == "warning"
  end

  test "returns invalid_params for unknown level" do
    conn = build_conn("verbose")
    result = LoggingSetLevel.run(conn)
    body = JSON.decode!(result.resp_body)

    assert body["error"]["code"] == -32602
  end

  test "accepts all valid syslog levels" do
    for level <- ~w(debug info notice warning error critical alert emergency) do
      conn = build_conn(level)
      result = LoggingSetLevel.run(conn)
      body = JSON.decode!(result.resp_body)
      assert body["result"] == %{}, "Failed for level: #{level}"
    end
  end
end
