defmodule Wymcp.Plugs.OriginCheck do
  @moduledoc false

  import Plug.Conn
  import Wymcp.Response
  alias Wymcp.JsonRpc

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
          send_rejection(conn, 403, "Origin not allowed: #{origin}", dialect)
        end

      [_, _ | _] ->
        send_rejection(
          conn,
          400,
          "Duplicated Origin header. Send exactly one Origin header.",
          dialect
        )
    end
  end

  # The JSON-RPC dialect's id is always nil here: on POST this plug runs
  # before parse_body, and on GET/DELETE no body is parsed at all.
  defp send_rejection(conn, status, message, :json_rpc) do
    response = JsonRpc.error_response(:invalid_request, nil, %{error: message})

    conn
    |> put_status(status)
    |> send_json(response)
  end

  defp send_rejection(conn, status, message, :plain_json) do
    send_plain_error(conn, status, message)
  end
end
