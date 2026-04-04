defmodule Wymcp.Plugs.Classify do
  @moduledoc false

  import Plug.Conn

  @behaviour Plug

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  @spec call(Plug.Conn.t(), term()) :: Plug.Conn.t()
  def call(%Plug.Conn{} = conn, _opts) do
    assign(conn, :wymcp_message_type, classify(conn.body_params))
  end

  @spec classify(map()) :: :request | :notification | :response | :unknown
  defp classify(%{"method" => method, "id" => _id}) when is_binary(method), do: :request
  defp classify(%{"method" => method}) when is_binary(method), do: :notification
  defp classify(%{"id" => _id, "result" => _result}), do: :response
  defp classify(%{"id" => _id, "error" => _error}), do: :response
  defp classify(_), do: :unknown
end
