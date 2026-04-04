defmodule Wymcp.Plugs.OriginCheck do
  @moduledoc false

  import Plug.Conn
  import Wymcp.Response
  alias Wymcp.JsonRpc

  @behaviour Plug

  @impl Plug
  @spec init(keyword()) :: keyword()
  def init(opts), do: opts

  @impl Plug
  @spec call(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
  def call(%Plug.Conn{} = conn, _opts) do
    wymcp_opts = conn.assigns[:wymcp] || []

    case Keyword.get(wymcp_opts, :origin) do
      nil -> conn
      [] -> conn
      allowlist when is_list(allowlist) -> check_origin(conn, allowlist)
    end
  end

  @spec check_origin(Plug.Conn.t(), [String.t()]) :: Plug.Conn.t()
  defp check_origin(conn, allowlist) do
    case get_req_header(conn, "origin") do
      [] ->
        conn

      [origin] ->
        if origin in allowlist do
          conn
        else
          reject_origin(conn, origin)
        end
    end
  end

  @spec reject_origin(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  defp reject_origin(conn, origin) do
    data = %{error: "Origin not allowed: #{origin}"}
    response = JsonRpc.error_response(:invalid_request, nil, data)

    conn
    |> put_status(403)
    |> send_json(response)
  end
end
