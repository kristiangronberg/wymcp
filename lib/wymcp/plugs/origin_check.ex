defmodule Wymcp.Plugs.OriginCheck do
  @moduledoc false

  import Plug.Conn
  import Wymcp.Response
  alias Wymcp.JsonRpc

  @behaviour Plug

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(%Plug.Conn{} = conn, _opts) do
    wymcp_opts = conn.assigns[:wymcp] || []

    case Keyword.get(wymcp_opts, :origin) do
      nil -> conn
      [] -> conn
      allowlist when is_list(allowlist) -> check_origin(conn, allowlist)
    end
  end

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

      [_, _ | _] ->
        duplicated_origin(conn)
    end
  end

  defp reject_origin(conn, origin) do
    data = %{error: "Origin not allowed: #{origin}"}
    response = JsonRpc.error_response(:invalid_request, nil, data)

    conn
    |> put_status(403)
    |> send_json(response)
  end

  # Runs before parse_body in the pipeline, so no request id is available —
  # same as reject_origin/2.
  defp duplicated_origin(conn) do
    data = %{error: "Duplicated Origin header. Send exactly one Origin header."}
    response = JsonRpc.error_response(:invalid_request, nil, data)

    conn
    |> put_status(400)
    |> send_json(response)
  end
end
