defmodule Wymcp.Plugs.SingletonHeaders do
  @moduledoc """
  Enforces the cardinality of the singleton request headers wymcp owns — the
  third wire check (`docs/glossary.md`, *wire check*), run after the origin
  check and the auth check.

  For what a *singleton header* is, and the reject/degrade policy vocabulary
  below, see `docs/glossary.md`. This check applies one policy per header:

  | Header | Policy | A duplicate |
  |---|---|---|
  | `Mcp-Session-Id` | reject | HTTP 400 + JSON-RPC -32600, naming the header |
  | `MCP-Protocol-Version` | reject | HTTP 400 + JSON-RPC -32600, naming the header |
  | `Last-Event-ID` | degrade | passes; the outcome is assigned as `:duplicated` |

  Failing closed rather than picking a value is the point: a repeated header
  is the signature of a broken proxy, and quietly choosing one of its values
  would mask that. The reject policy therefore reads cardinality and nothing
  else — it never looks at the values. Two identical `Mcp-Session-Id` values
  are a 400, and so are two `MCP-Protocol-Version` values of which one
  matches the version negotiated at `initialize`: this check runs before any
  session pid resolves, so it has no negotiated version to compare against,
  and comparing values is `Wymcp.Plugs.Session`'s job further down the chain.

  Two singleton headers are not here. `Origin` stays with
  `Wymcp.Plugs.OriginCheck`, which the wire-check invariant puts **first** —
  nothing has validated that header when it runs, so it carries its own
  duplicate arm and its own copy of the message. Note that arm is reached
  only when an `:origin` allowlist is configured: with none, the origin
  check returns immediately and a duplicated `Origin` is not rejected at
  all. `Origin` is therefore the one singleton header whose cardinality is
  unenforced in the default configuration — acceptable because nothing
  downstream reads it, and with no allowlist there is no rebinding
  protection to weaken. `Authorization` is the
  consumer's `Wymcp.Auth` implementation's to read, and it runs before this
  check for the same ordering reason; see that module's example, which reads
  the header three ways.

  ### What the reject policy buys downstream

  For a reject-class header, halting *is* the normalization. Every path that
  reaches a downstream `Plug.Conn.get_req_header/2` either was halted here or
  carried at most one value to begin with, so `[]` or `[value]` is a fact
  about the conn rather than a convention — which is why no read in
  `Wymcp.Plugs.Session`, `Wymcp.Router`, or `Wymcp.Session` carries a
  duplicate arm: each faces a two-way present/absent decision on cardinality.
  A header's *value* is a separate concern, so a read that also compares the
  value keeps a clause for it — `Wymcp.Plugs.Session`'s
  `enforce_protocol_version_header/2` still checks the single value against
  the negotiated version, and so has three clauses, not two.

  There is deliberately **no assign** mirroring that guarantee. An assign is
  *absent* when this plug did not run, and absent reads as "header missing" —
  a silent wrong answer (a 400 on a request that carried the header). A
  two-clause `get_req_header/2` read facing a bypassed check crashes instead.
  For a guarantee this load-bearing, loud beats silent, and
  `Wymcp.WireCheckInvariantTest` is the mechanism that catches a route wired
  without the check.

  ### What the degrade policy assigns

  `Last-Event-ID` does not halt, so a duplicate really can still travel. Its
  outcome is therefore the one that must be carried: it is assigned under
  `:wymcp_last_event_id` as `{:ok, value} | :missing | :duplicated`, and
  `Wymcp.Transport.Stream` discards the resumption point on `:duplicated`
  with the warning `List.first/1` used to swallow.

  ### One table, both insertion points

  The table is applied in full at both places the check is wired — inside
  `Wymcp.Plugs.Pipeline` on POST (after `Wymcp.Plugs.Auth`, so body parsing
  and `Wymcp.Plugs.Classify` have already run and a rejection can carry the
  body id and the message kind) and inside `Wymcp.Router`'s
  `with_wire_checks/2` on GET and DELETE. A singleton header is a singleton
  on every route; a per-route table would be a second thing to keep true.
  The accepted cost: `Last-Event-ID` is read only by the GET stream, so its
  assigned outcome is present and unread on POST and DELETE. That costs
  nothing on the wire — degrade never rejects.

  Rejections speak the route's error dialect via the `:error_dialect` init
  option (`:json_rpc` by default, `:plain_json` on GET/DELETE) and echo the
  id `Wymcp.Response.rejection_id/1` gives.
  """

  import Plug.Conn

  alias Wymcp.Response

  @behaviour Plug

  # {wire name, display name, policy}. The order is wire-visible: a request
  # duplicating two reject-class headers is answered for the first matching
  # row. singleton_headers_test.exs pins it.
  @singleton_headers [
    {"mcp-session-id", "Mcp-Session-Id", :reject},
    {"mcp-protocol-version", "MCP-Protocol-Version", :reject},
    {"last-event-id", "Last-Event-ID", {:degrade, :wymcp_last_event_id}}
  ]

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(%Plug.Conn{} = conn, opts) do
    dialect = Keyword.get(opts, :error_dialect, :json_rpc)

    Enum.reduce_while(@singleton_headers, conn, &apply_policy(&1, &2, dialect))
  end

  defp apply_policy({wire_name, display_name, :reject}, conn, dialect) do
    case get_req_header(conn, wire_name) do
      [_, _ | _] -> {:halt, reject(conn, display_name, dialect)}
      _at_most_one -> {:cont, conn}
    end
  end

  defp apply_policy({wire_name, _display_name, {:degrade, assign_key}}, conn, _dialect) do
    {:cont, assign(conn, assign_key, outcome(get_req_header(conn, wire_name)))}
  end

  defp outcome([]), do: :missing
  defp outcome([value]), do: {:ok, value}
  defp outcome([_, _ | _]), do: :duplicated

  defp reject(conn, display_name, dialect) do
    message = "Duplicated #{display_name} header. Send exactly one #{display_name} header."

    Response.send_error(conn, 400, Response.rejection_id(conn), message, dialect)
  end
end
