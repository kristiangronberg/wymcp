defmodule Wymcp.Plugs.OriginCheck do
  @moduledoc false

  import Plug.Conn
  import Wymcp.Response

  @behaviour Plug

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(%Plug.Conn{} = conn, opts) do
    wymcp_opts = conn.assigns[:wymcp] || []
    dialect = Keyword.get(opts, :error_dialect, :json_rpc)

    case Keyword.get(wymcp_opts, :origin) do
      nil -> conn
      [] -> conn
      allowlist when is_list(allowlist) -> check_origin(conn, allowlist, dialect)
    end
  end

  defp check_origin(conn, allowlist, dialect) do
    case get_req_header(conn, "origin") do
      [] ->
        conn

      [origin] ->
        if origin in allowlist do
          conn
        else
          reject(conn, 403, "Origin not allowed: #{origin}", dialect)
        end

      [_, _ | _] ->
        reject(
          conn,
          400,
          "Duplicated Origin header. Send exactly one Origin header.",
          dialect
        )
    end
  end

  # The rejection id is always nil here: this is the first wire check, so on
  # POST it runs before parse_body and on GET/DELETE no body is parsed at all.
  # Origin's duplicate arm stays in this plug rather than moving to
  # Wymcp.Plugs.SingletonHeaders — the wire-check invariant puts the origin
  # check first, so nothing has validated Origin by the time it is read.
  # Unlike that plug's rows, this arm is reached only when an :origin
  # allowlist is configured; call/2 returns early otherwise, so a duplicated
  # Origin passes unexamined in the default configuration.
  defp reject(conn, status, message, dialect) do
    send_error(conn, status, nil, message, dialect)
  end
end
