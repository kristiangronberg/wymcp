defmodule Wymcp.Methods.ToolsList do
  @moduledoc false

  import Wymcp.Response
  alias Wymcp.{JsonRpc, ProtocolVersion, Session}

  @spec run(Plug.Conn.t(), [module()]) :: Plug.Conn.t()
  def run(%Plug.Conn{} = conn, _compile_tools) do
    request = conn.body_params
    tools = Session.get_tools(conn.assigns[:wymcp_session_pid])
    version = Session.negotiated_version(conn)

    tool_definitions =
      tools
      |> Enum.map(& &1.definition())
      |> Enum.map(&ProtocolVersion.strip_tool_definition(&1, version))

    response = JsonRpc.success_response(request["id"], %{tools: tool_definitions})
    send_json(conn, response)
  end
end
