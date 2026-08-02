defmodule Wymcp.Plugs.Auth do
  @moduledoc """
  Authentication plug for MCP requests.

  Reads the auth module from router opts (`conn.assigns[:wymcp][:auth]`)
  and calls its `c:Wymcp.Auth.authenticate/1` callback. When no auth
  module is configured, defaults to `Wymcp.Auth.Noop` (pass-through).

  On authentication failure, returns HTTP 401 with a `WWW-Authenticate`
  challenge as required by the MCP 2025-11-25 specification. By default the
  challenge is bare `Bearer`; consumers may append RFC 6750 auth-params (an
  RFC 9728 `resource_metadata` pointer, a `scope` hint) via the router's
  `:www_authenticate` option — see `Wymcp.Router`. If rendering the configured
  params raises (e.g. a misconfigured MFA), the challenge degrades to bare
  `Bearer` for that request and the error is logged naming the option — the
  401 contract survives misconfiguration. The response body follows the
  route's error dialect (the `:error_dialect` init option): a JSON-RPC error
  with code -32600 (Invalid Request) on the default `:json_rpc` dialect — the
  POST pipeline — or the plain-JSON `%{error: message}` object under
  `:plain_json`, which the router's GET/DELETE wire-check call sites pass.

  ## Observability

  The plug emits two telemetry events (see `Wymcp.Telemetry`) alongside
  the wire response:

  * `[:wymcp, :auth, :reject]` — the auth module returned `{:error,
    reason}`. Metadata includes `auth_module`, `reason`, `request_id`,
    and `method`.
  * `[:wymcp, :auth, :error]` — the auth module raised. Metadata
    includes `auth_module`, `exception`, `error`, `request_id`, and
    `method`.

  Both events carry `http_method` — the conn's HTTP verb (`"POST"`,
  `"GET"`, `"DELETE"`). `request_id` and `method` come from the parsed
  request body, so both are `nil` off POST. Both branches also emit a
  structured `Logger` line with the same metadata so operators without a
  telemetry handler still get attribution.
  """

  require Logger

  import Wymcp.Response
  import Plug.Conn
  alias Wymcp.JsonRpc

  @behaviour Plug

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(%Plug.Conn{} = conn, opts) do
    auth_module = get_in(conn.assigns, [:wymcp, :auth]) || Wymcp.Auth.Noop
    dialect = Keyword.get(opts, :error_dialect, :json_rpc)
    do_authenticate(conn, auth_module, dialect)
  end

  defp do_authenticate(conn, auth_module, dialect) do
    case auth_module.authenticate(conn) do
      {:ok, conn} ->
        conn

      {:error, message} ->
        log_and_emit_reject(conn, auth_module, message)
        send_unauthorized(conn, message, dialect)
    end
  rescue
    e ->
      log_and_emit_error(conn, auth_module, e, __STACKTRACE__)
      send_unauthorized(conn, "Authentication error", dialect)
  end

  defp log_and_emit_reject(conn, auth_module, reason) do
    request_id = request_field(conn, "id")
    method = request_field(conn, "method")

    Wymcp.Telemetry.emit(:auth, :reject, %{}, %{
      auth_module: auth_module,
      reason: reason,
      request_id: request_id,
      method: method,
      http_method: conn.method
    })

    Logger.warning("MCP auth rejected: #{reason}",
      auth_module: inspect(auth_module),
      reason: reason,
      request_id: request_id,
      method: method,
      http_method: conn.method
    )

    :ok
  end

  defp log_and_emit_error(conn, auth_module, exception, stacktrace) do
    request_id = request_field(conn, "id")
    method = request_field(conn, "method")
    exception_class = inspect(exception.__struct__)

    Wymcp.Telemetry.emit(:auth, :error, %{}, %{
      auth_module: auth_module,
      exception: exception_class,
      error: Exception.message(exception),
      request_id: request_id,
      method: method,
      http_method: conn.method
    })

    Logger.error("MCP auth raised: #{Exception.message(exception)}",
      auth_module: inspect(auth_module),
      exception: exception_class,
      request_id: request_id,
      method: method,
      http_method: conn.method,
      crash_reason: {exception, stacktrace}
    )

    :ok
  end

  defp send_unauthorized(conn, reason, dialect) do
    conn
    |> put_resp_header("www-authenticate", www_authenticate_value(conn))
    |> send_rejection(reason, dialect)
  end

  defp send_rejection(conn, reason, :json_rpc) do
    request_id = request_field(conn, "id")
    response = JsonRpc.error_response(:invalid_request, request_id, %{error: reason})

    conn
    |> put_status(401)
    |> send_json(response)
  end

  defp send_rejection(conn, reason, :plain_json), do: send_plain_error(conn, 401, reason)

  # Bare `Bearer` unless the consumer configured auth-params via the router's
  # :www_authenticate option (see Wymcp.Router). MFA values are resolved per
  # request because consumers may only know them at runtime (Phoenix forward
  # options are evaluated at compile time).
  #
  # Rendering is total: send_unauthorized/3 is called from inside
  # do_authenticate/3's rescue, so a raising entry (a typo'd MFA past the
  # shape-only init validation, or an MFA returning a non-binary) would
  # otherwise escape as a 500 on every unauthenticated request — and the first
  # raise would emit [:wymcp, :auth, :error], misattributing the crash to the
  # auth module. On rescue the WHOLE header degrades to bare "Bearer" (never a
  # partial param list — a scope hint without the resource_metadata pointer is
  # a misleading half-challenge), with an error log naming the real owner.
  defp www_authenticate_value(conn) do
    case get_in(conn.assigns, [:wymcp, :www_authenticate]) || [] do
      [] -> "Bearer"
      params -> "Bearer " <> Enum.map_join(params, ", ", &auth_param/1)
    end
  rescue
    e ->
      Logger.error(
        "MCP :www_authenticate option failed to render; sending bare Bearer challenge: " <>
          Exception.message(e),
        www_authenticate: inspect(get_in(conn.assigns, [:wymcp, :www_authenticate])),
        crash_reason: {e, __STACKTRACE__}
      )

      "Bearer"
  end

  defp auth_param({key, {m, f, a}}), do: auth_param({key, apply(m, f, a)})

  defp auth_param({key, value}) when is_binary(value) do
    escaped =
      value
      |> String.replace("\\", "\\\\")
      |> String.replace("\"", "\\\"")

    ~s(#{key}="#{escaped}")
  end

  defp request_field(%Plug.Conn{body_params: params}, key), do: Map.get(params, key)
end
