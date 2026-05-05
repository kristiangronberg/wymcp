defmodule Wymcp.Methods.CancelledTest do
  use ExUnit.Case, async: true

  @moduledoc """
  Tests for the Wymcp.Methods.Cancelled handler.

  Cancelled handles `notifications/cancelled` — a client notification that
  a previously-issued request should be abandoned. The handler calls
  `Session.complete_request/2` to clean up the pending request tracker.
  It always returns an empty JSON response (notifications don't expect a
  meaningful reply).

  `notifications/cancelled` is not session-exempt, so `Plugs.Session`
  ensures the session pid is always assigned by the time this handler
  runs.
  """

  import Plug.Test
  import Plug.Conn

  alias Wymcp.Methods.Cancelled
  alias Wymcp.Session

  defp start_session do
    {:ok, pid, session_id} =
      Session.start_session(%{
        client_capabilities: %{},
        client_info: %{"name" => "test", "version" => "1.0"},
        protocol_version: "2025-11-25",
        tools: [],
        auth: nil
      })

    Session.mark_ready(pid)
    {pid, session_id}
  end

  defp build_conn(params, session_pid) do
    body = %{
      "jsonrpc" => "2.0",
      "method" => "notifications/cancelled",
      "params" => params
    }

    conn(:post, "/")
    |> Map.put(:body_params, body)
    |> assign(:wymcp_session_pid, session_pid)
  end

  test "returns empty JSON response" do
    {pid, _id} = start_session()
    conn = build_conn(%{"requestId" => 1, "reason" => "user abort"}, pid)
    result = Cancelled.run(conn)
    body = JSON.decode!(result.resp_body)

    assert body == %{}
  end

  test "halts the connection" do
    {pid, _id} = start_session()
    conn = build_conn(%{"requestId" => 1}, pid)
    result = Cancelled.run(conn)

    assert result.halted
  end

  test "completes the pending request in the session" do
    {pid, _id} = start_session()

    # Track a request so we can verify it gets completed
    Session.track_request(pid, 42, "tools/call")
    state_before = Session.get_state(pid)
    assert Map.has_key?(state_before.pending_requests, 42)

    conn = build_conn(%{"requestId" => 42, "reason" => "timeout"}, pid)
    Cancelled.run(conn)

    state_after = Session.get_state(pid)
    refute Map.has_key?(state_after.pending_requests, 42)
  end

  test "handles missing params gracefully" do
    body = %{
      "jsonrpc" => "2.0",
      "method" => "notifications/cancelled"
    }

    conn = conn(:post, "/") |> Map.put(:body_params, body)
    result = Cancelled.run(conn)
    body = JSON.decode!(result.resp_body)

    assert body == %{}
  end

  test "handles missing requestId without crashing" do
    {pid, _id} = start_session()
    conn = build_conn(%{"reason" => "no request id"}, pid)
    result = Cancelled.run(conn)
    body = JSON.decode!(result.resp_body)

    assert body == %{}
  end

  test "uses default reason when not provided" do
    {pid, _id} = start_session()
    Session.track_request(pid, 99, "tools/call")

    conn = build_conn(%{"requestId" => 99}, pid)

    # Should not crash — defaults to "cancelled"
    result = Cancelled.run(conn)
    body = JSON.decode!(result.resp_body)

    assert body == %{}

    # Request should still be completed
    state = Session.get_state(pid)
    refute Map.has_key?(state.pending_requests, 99)
  end
end
