defmodule Wymcp.Methods.Unknown do
  @moduledoc false

  import Wymcp.Response
  alias Wymcp.JsonRpc

  @spec run(Plug.Conn.t()) :: Plug.Conn.t()
  def run(%Plug.Conn{} = conn) do
    request = conn.body_params
    data = %{original_request: request}
    response = JsonRpc.error_response(:method_not_found, request["id"], data)
    send_json(conn, response)
  end
end
