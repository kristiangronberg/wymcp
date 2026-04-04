defmodule Wymcp.Methods.LoggingSetLevel do
  @moduledoc false

  import Wymcp.Response
  alias Wymcp.{JsonRpc, Session}

  @spec run(Plug.Conn.t()) :: Plug.Conn.t()
  def run(%Plug.Conn{} = conn) do
    request = conn.body_params
    params = request["params"] || %{}
    level = params["level"]
    session_pid = conn.assigns[:wymcp_session_pid]

    case Session.set_log_level(session_pid, level) do
      :ok ->
        send_json(conn, JsonRpc.success_response(request["id"], %{}))

      {:error, :invalid_level} ->
        send_json(
          conn,
          JsonRpc.error_response(:invalid_params, request["id"], %{
            reason: "Invalid log level: #{inspect(level)}"
          })
        )
    end
  end
end
