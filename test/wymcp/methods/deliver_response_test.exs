defmodule Wymcp.Methods.DeliverResponseTest do
  use ExUnit.Case, async: true

  import Plug.Test
  import Plug.Conn

  alias Wymcp.Methods.DeliverResponse
  alias Wymcp.Session
  alias Wymcp.Testing

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

  defp start_ready_session do
    {:ok, pid, id} = Session.start_session(Testing.build_session_opts())

    Session.mark_ready(pid)
    {:ok, pid, id}
  end
end
