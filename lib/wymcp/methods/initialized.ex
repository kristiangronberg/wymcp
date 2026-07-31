defmodule Wymcp.Methods.Initialized do
  @moduledoc false

  require Logger

  import Wymcp.Response
  alias Wymcp.{JsonRpc, Session}

  def run(conn) do
    session_pid = conn.assigns[:wymcp_session_pid]
    Session.mark_ready(session_pid)
    invoke_server_init(conn, session_pid)
  end

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

        telemetry_metadata = %{
          server: server,
          session_id: state.session_id,
          request_id: conn.body_params["id"]
        }

        case safe_init(server, state.client_info, assigns, telemetry_metadata) do
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
              JsonRpc.error_response(:internal_error, request["id"], %{
                reason: reason_to_string(reason)
              })

            send_json(conn, response)
        end
    end
  end

  # Consumer code runs inside the notifications/initialized request. A raise,
  # exit, or throw here — Session.register_tool/2's reserved-name or
  # malformed-schema ArgumentError, a GenServer.call timeout in the
  # callback's own code, or any other bug — must not escape the pipeline:
  # nothing above rescues, so the client would get an envelope-less 500 and
  # the already-marked-ready session would live on until the idle timeout.
  # Converting to {:error, reason} routes it into the graceful branch below
  # (log, terminate, internal_error). Same shape as
  # Wymcp.Methods.ToolsCall's rescue around a tool's run/2.
  defp safe_init(server, client_info, assigns, telemetry_metadata) do
    case server.init(client_info, assigns) do
      {:error, reason} = rejection ->
        Wymcp.Telemetry.emit(
          :server,
          :reject,
          %{},
          Map.put(telemetry_metadata, :reason, reason)
        )

        rejection

      other ->
        other
    end
  rescue
    exception ->
      Wymcp.Telemetry.emit(
        :server,
        :error,
        %{},
        Map.merge(telemetry_metadata, %{
          exception: inspect(exception.__struct__),
          error: Exception.message(exception)
        })
      )

      Logger.error("Server.init/2 raised: #{Exception.message(exception)}",
        crash_reason: {exception, __STACKTRACE__}
      )

      {:error, "#{inspect(exception.__struct__)}: #{Exception.message(exception)}"}
  catch
    kind, value ->
      Wymcp.Telemetry.emit(
        :server,
        :error,
        %{},
        Map.merge(telemetry_metadata, %{
          exception: Atom.to_string(kind),
          error: inspect(value)
        })
      )

      Logger.error("Server.init/2 #{kind}: #{inspect(value)}",
        crash_reason: {value, __STACKTRACE__}
      )

      {:error, "#{kind}: #{inspect(value)}"}
  end

  # Server.init/2's rejection reason is term() by contract; only binaries
  # and atoms have a String.Chars head, so anything else goes through
  # inspect instead of raising Protocol.UndefinedError out of the pipeline.
  defp reason_to_string(reason) when is_binary(reason), do: reason
  defp reason_to_string(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp reason_to_string(reason), do: inspect(reason)
end
