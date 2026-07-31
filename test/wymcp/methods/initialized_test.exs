defmodule Wymcp.Methods.InitializedTest do
  use ExUnit.Case, async: true

  import Plug.Test
  import Plug.Conn

  alias Wymcp.Methods.Initialized
  alias Wymcp.Session
  alias Wymcp.Testing

  test "returns empty response for initialized notification" do
    {:ok, pid, _session_id} = Session.start_session(Testing.build_session_opts())

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
