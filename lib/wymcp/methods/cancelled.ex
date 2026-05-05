defmodule Wymcp.Methods.Cancelled do
  @moduledoc false

  require Logger

  import Wymcp.Response
  alias Wymcp.Session

  @spec run(Plug.Conn.t()) :: Plug.Conn.t()
  def run(conn) do
    params = conn.body_params["params"] || %{}
    request_id = params["requestId"]
    reason = params["reason"] || "cancelled"
    session_pid = conn.assigns[:wymcp_session_pid]

    if request_id do
      Session.complete_request(session_pid, request_id)
      Logger.info("Request #{request_id} cancelled: #{reason}")
    end

    send_json(conn, %{})
  end
end
