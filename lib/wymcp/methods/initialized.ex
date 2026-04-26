defmodule Wymcp.Methods.Initialized do
  @moduledoc false

  require Logger

  import Wymcp.Response
  alias Wymcp.{JsonRpc, Session}

  @spec run(Plug.Conn.t()) :: Plug.Conn.t()
  def run(conn) do
    session_pid = conn.assigns[:wymcp_session_pid]

    if session_pid do
      Session.mark_ready(session_pid)
      invoke_server_init(conn, session_pid)
    else
      send_json(conn, %{})
    end
  end

  @spec invoke_server_init(Plug.Conn.t(), pid()) :: Plug.Conn.t()
  defp invoke_server_init(conn, session_pid) do
    state = Session.get_state(session_pid)

    case state.server do
      nil ->
        send_json(conn, %{})

      server ->
        # Pre-seed session_pid into assigns so the callback can call
        # Session.register_tool/2 directly — follows the Phoenix pattern
        # where socket.assigns carries process references.
        assigns = Map.put(state.assigns, :session_pid, session_pid)

        case server.init(state.client_info, assigns) do
          {:ok, assigns} when is_map(assigns) ->
            Session.put_assigns(session_pid, assigns)
            send_json(conn, %{})

          {:error, reason} ->
            Logger.warning(
              "Server.init/2 rejected session #{state.session_id}: #{inspect(reason)}"
            )

            _ = Session.terminate_session(state.session_id)

            request = conn.body_params

            response =
              JsonRpc.error_response(:internal_error, request["id"], %{reason: to_string(reason)})

            send_json(conn, response)
        end
    end
  end
end
