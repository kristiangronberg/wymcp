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

  # The rejection id is always nil on this path and needs no thought at the
  # call sites: Wymcp.Response.rejection_id/1 derives it. This is the first
  # wire check — pipeline plug 1, ahead of both parse_body and
  # Wymcp.Plugs.Classify — so on POST the message-type assign is still unset
  # and the rule's catch-all answers nil even when the body does carry an id.
  # On GET/DELETE no body is parsed at all. The nil here is therefore
  # structural, not a judgement about the message kind.
  #
  # Origin's duplicate arm stays in this plug rather than moving to
  # Wymcp.Plugs.SingletonHeaders — the wire-check invariant puts the origin
  # check first, so nothing has validated Origin by the time it is read. Unlike
  # that plug's rows, this arm is reached only when an :origin allowlist is
  # configured; call/2 returns early otherwise, so a duplicated Origin passes
  # unexamined in the default configuration.
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
end
