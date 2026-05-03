defmodule Wymcp.Plugs.Auth do
  @moduledoc """
  Authentication plug for MCP requests.

  Reads the auth module from router opts (`conn.assigns[:wymcp][:auth]`)
  and calls its `c:Wymcp.Auth.authenticate/1` callback. When no auth
  module is configured, defaults to `Wymcp.Auth.Noop` (pass-through).

  On authentication failure, returns HTTP 401 with a
  `WWW-Authenticate: Bearer` header as required by the MCP 2025-11-25
  specification. The response body is a JSON-RPC error with code
  -32600 (Invalid Request).

  ## Observability

  The plug emits two telemetry events alongside the wire response:

  * `[:wymcp, :auth, :reject]` — the auth module returned `{:error,
    reason}`. Metadata includes `auth_module`, `reason`, `request_id`,
    and `method`.
  * `[:wymcp, :auth, :error]` — the auth module raised. Metadata
    includes `auth_module`, `exception`, `error`, `request_id`, and
    `method`.

  Both branches also emit a structured `Logger` line with the same
  metadata so operators without a telemetry handler still get
  attribution.

  ## Related Modules

  See: `Wymcp.Auth`, `Wymcp.Auth.Noop`, `Wymcp.Telemetry`
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
        log_and_emit_reject(conn, auth_module, message)
        send_unauthorized(conn, message)
    end
  rescue
    e ->
      log_and_emit_error(conn, auth_module, e, __STACKTRACE__)
      send_unauthorized(conn, "Authentication error")
  end

  @spec log_and_emit_reject(Plug.Conn.t(), module(), String.t()) :: :ok
  defp log_and_emit_reject(conn, auth_module, reason) do
    request_id = request_field(conn, "id")
    method = request_field(conn, "method")

    Wymcp.Telemetry.emit(:auth, :reject, %{}, %{
      auth_module: auth_module,
      reason: reason,
      request_id: request_id,
      method: method
    })

    Logger.warning("MCP auth rejected: #{reason}",
      auth_module: inspect(auth_module),
      reason: reason,
      request_id: request_id,
      method: method
    )

    :ok
  end

  @spec log_and_emit_error(Plug.Conn.t(), module(), Exception.t(), Exception.stacktrace()) ::
          :ok
  defp log_and_emit_error(conn, auth_module, exception, stacktrace) do
    request_id = request_field(conn, "id")
    method = request_field(conn, "method")
    exception_class = inspect(exception.__struct__)

    Wymcp.Telemetry.emit(:auth, :error, %{}, %{
      auth_module: auth_module,
      exception: exception_class,
      error: Exception.message(exception),
      request_id: request_id,
      method: method
    })

    Logger.error("MCP auth raised: #{Exception.message(exception)}",
      auth_module: inspect(auth_module),
      exception: exception_class,
      request_id: request_id,
      method: method,
      crash_reason: {exception, stacktrace}
    )

    :ok
  end

  @spec send_unauthorized(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  defp send_unauthorized(conn, reason) do
    request_id = request_field(conn, "id")
    data = %{error: reason}
    response = JsonRpc.error_response(:invalid_request, request_id, data)

    conn
    |> put_resp_header("www-authenticate", "Bearer")
    |> put_status(401)
    |> send_json(response)
  end

  @spec request_field(Plug.Conn.t(), String.t()) :: term() | nil
  defp request_field(%Plug.Conn{body_params: params}, key), do: Map.get(params, key)
end
