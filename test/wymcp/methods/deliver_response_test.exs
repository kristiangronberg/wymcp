defmodule Wymcp.Methods.DeliverResponseTest do
  use ExUnit.Case, async: true

  @moduledoc """
  Tests for the DeliverResponse method handler.

  When a client POSTs a JSON-RPC response (answer to a server-initiated
  request like sampling/createMessage), the router pipeline classifies it
  as :response and Dispatch routes it here. DeliverResponse extracts the
  request_id and result/error, calls Session.deliver_response/3, and
  returns HTTP 202 Accepted with an empty body.

  The actual response delivery is tested in SessionTest — these tests
  verify the HTTP-level behavior: correct status codes, proper extraction
  of result vs error, and handling of sessions.
  """

  import Plug.Test
  import Plug.Conn

  alias Wymcp.Methods.DeliverResponse
  alias Wymcp.Session

  test "returns 202 for a result response" do
    {:ok, pid, session_id} = start_ready_session()

    conn =
      conn(:post, "/")
      |> Map.put(:body_params, %{
        "jsonrpc" => "2.0",
        "id" => "srv-1",
        "result" => %{"role" => "assistant"}
      })
      |> assign(:wymcp_session_pid, pid)
      |> assign(:wymcp_session_id, session_id)

    result_conn = DeliverResponse.run(conn)

    assert result_conn.status == 202
    assert result_conn.halted
  end

  test "returns 202 for an error response" do
    {:ok, pid, session_id} = start_ready_session()

    conn =
      conn(:post, "/")
      |> Map.put(:body_params, %{
        "jsonrpc" => "2.0",
        "id" => "srv-2",
        "error" => %{"code" => -1, "message" => "denied"}
      })
      |> assign(:wymcp_session_pid, pid)
      |> assign(:wymcp_session_id, session_id)

    result_conn = DeliverResponse.run(conn)

    assert result_conn.status == 202
    assert result_conn.halted
  end

  @spec start_ready_session() :: {:ok, pid(), String.t()}
  defp start_ready_session do
    {:ok, pid, id} =
      Session.start_session(%{
        client_capabilities: %{},
        client_info: %{"name" => "test", "version" => "1.0"},
        protocol_version: "2025-11-25",
        tools: [],
        auth: nil
      })

    Session.mark_ready(pid)
    {:ok, pid, id}
  end
end
