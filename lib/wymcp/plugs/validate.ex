defmodule Wymcp.Plugs.Validate do
  @moduledoc false

  import Wymcp.Response
  import Plug.Conn
  alias Wymcp.JsonRpc

  @behaviour Plug

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(%Plug.Conn{} = conn, _opts) do
    if conn.assigns[:wymcp_message_type] == :response do
      conn
    else
      validate_request(conn)
    end
  end

  @spec validate_request(Plug.Conn.t()) :: Plug.Conn.t()
  defp validate_request(conn) do
    request = conn.body_params

    case JsonRpc.validate_mcp_request("JSONRPCMessage", request) do
      :ok ->
        conn

      {:error, reason} ->
        request_id = request["id"]
        data = %{original_request: request, error: reason}
        response = JsonRpc.error_response(:invalid_request, request_id, data)

        conn
        |> put_status(400)
        |> send_json(response)
    end
  end
end
