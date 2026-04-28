defmodule Wymcp.Methods.ToolsList do
  @moduledoc false

  import Wymcp.Response
  alias Wymcp.{JsonRpc, ProtocolVersion, Session}

  @spec run(Plug.Conn.t(), [module()]) :: Plug.Conn.t()
  def run(%Plug.Conn{} = conn, compile_tools) do
    request = conn.body_params
    tools = resolve_tools(conn, compile_tools)
    version = Session.negotiated_version(conn)

    tool_definitions =
      tools
      |> Enum.map(& &1.definition())
      |> Enum.map(&ProtocolVersion.strip_tool_definition(&1, version))

    result =
      %{tools: tool_definitions}
      |> maybe_add_warning(conn)

    response = JsonRpc.success_response(request["id"], result)
    send_json(conn, response)
  end

  @spec maybe_add_warning(map(), Plug.Conn.t()) :: map()
  defp maybe_add_warning(result, conn) do
    case conn.assigns[:wymcp_session_warning] do
      nil -> result
      warning -> put_in(result, [:_meta], %{warnings: [warning]})
    end
  end

  @spec resolve_tools(Plug.Conn.t(), [module()]) :: [module()]
  defp resolve_tools(conn, compile_tools) do
    case conn.assigns[:wymcp_session_pid] do
      nil -> compile_tools
      pid -> Session.get_tools(pid)
    end
  end
end
