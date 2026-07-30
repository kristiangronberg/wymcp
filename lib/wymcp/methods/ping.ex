defmodule Wymcp.Methods.Ping do
  @moduledoc false

  import Wymcp.Response
  alias Wymcp.JsonRpc

  def run(conn) do
    request = conn.body_params
    response = JsonRpc.success_response(request["id"], %{})
    send_json(conn, response)
  end
end
