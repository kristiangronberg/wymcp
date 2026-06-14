defmodule Wymcp.Plugs.Dispatch do
  @moduledoc false

  alias Wymcp.Methods

  @behaviour Plug

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(%Plug.Conn{} = conn, _opts) do
    if conn.assigns[:wymcp_message_type] == :response do
      Methods.DeliverResponse.run(conn)
    else
      dispatch_request(conn)
    end
  end

  @spec dispatch_request(Plug.Conn.t()) :: Plug.Conn.t()
  defp dispatch_request(conn) do
    case conn.body_params["method"] do
      "initialize" -> Methods.Initialize.run(conn)
      "notifications/initialized" -> Methods.Initialized.run(conn)
      "ping" -> Methods.Ping.run(conn)
      "tools/list" -> Methods.ToolsList.run(conn, tools(conn))
      "tools/call" -> Methods.ToolsCall.run(conn, tools(conn))
      "logging/setLevel" -> Methods.LoggingSetLevel.run(conn)
      "notifications/cancelled" -> Methods.Cancelled.run(conn)
      _ -> Methods.Unknown.run(conn)
    end
  end

  @spec tools(Plug.Conn.t()) :: [module()]
  defp tools(conn), do: conn.assigns[:wymcp][:tools] || []
end
