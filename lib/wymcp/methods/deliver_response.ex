defmodule Wymcp.Methods.DeliverResponse do
  @moduledoc false

  import Plug.Conn
  alias Wymcp.Session

  @spec run(Plug.Conn.t()) :: Plug.Conn.t()
  def run(conn) do
    body = conn.body_params
    request_id = body["id"]
    session_pid = conn.assigns[:wymcp_session_pid]

    result_or_error =
      cond do
        Map.has_key?(body, "result") -> {:ok, body["result"]}
        Map.has_key?(body, "error") -> {:error, body["error"]}
      end

    Session.deliver_response(session_pid, request_id, result_or_error)

    conn
    |> send_resp(202, "")
    |> halt()
  end
end
