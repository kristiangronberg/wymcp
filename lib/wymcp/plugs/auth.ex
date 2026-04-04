defmodule Wymcp.Plugs.Auth do
  @moduledoc """
  Authentication plug for MCP requests.

  Reads the auth module from router opts (`conn.assigns[:wymcp][:auth]`) and
  calls its `c:Wymcp.Auth.authenticate/1` callback. When no auth module is
  configured, defaults to `Wymcp.Auth.Noop` (pass-through).

  On authentication failure, returns HTTP 401 with a `WWW-Authenticate: Bearer`
  header as required by the MCP 2025-11-25 specification. The response body is
  a JSON-RPC error with code -32600 (Invalid Request). If the auth module
  raises, the exception is caught and logged — the client still receives a
  401 rather than a 500.

  ## Related Modules

  See: `Wymcp.Auth`, `Wymcp.Auth.Noop`
  """

  require Logger

  import Wymcp.Response
  import Plug.Conn
  alias Wymcp.JsonRpc

  @behaviour Plug

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(%Plug.Conn{} = conn, _opts) do
    auth_module = get_in(conn.assigns, [:wymcp, :auth]) || Wymcp.Auth.Noop
    do_authenticate(conn, auth_module)
  end

  @spec do_authenticate(Plug.Conn.t(), module()) :: Plug.Conn.t()
  defp do_authenticate(conn, auth_module) do
    case auth_module.authenticate(conn) do
      {:ok, conn} ->
        conn

      {:error, message} ->
        request_id = conn.body_params["id"]
        data = %{error: message}
        response = JsonRpc.error_response(:invalid_request, request_id, data)

        conn
        |> put_resp_header("www-authenticate", "Bearer")
        |> put_status(401)
        |> send_json(response)
    end
  rescue
    e ->
      Logger.error("Auth module #{inspect(auth_module)} raised: #{Exception.message(e)}")
      send_unauthorized(conn)
  end

  @spec send_unauthorized(Plug.Conn.t()) :: Plug.Conn.t()
  defp send_unauthorized(conn) do
    request_id = conn.body_params["id"]
    data = %{error: "Authentication error"}
    response = JsonRpc.error_response(:invalid_request, request_id, data)

    conn
    |> put_resp_header("www-authenticate", "Bearer")
    |> put_status(401)
    |> send_json(response)
  end
end
