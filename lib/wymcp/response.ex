defmodule Wymcp.Response do
  @moduledoc """
  Sends wire responses over the Plug connection — the lowest-level output
  module in the pipeline.

  Two primitives, one per structured error dialect (`docs/glossary.md`,
  *error dialect*): `send_json/2` sends a JSON-RPC envelope as-is — every
  JSON-RPC-enveloped POST answer flows through it, and it preserves any
  previously-set HTTP status — and `send_plain_error/3` sends the plain-JSON
  dialect's flat `%{error: message}` object, the rejection body of the
  GET/DELETE routes. Both halt the connection after sending.

  Above them sits `send_error/5`, the shared rejection sender: it takes the
  dialect as a parameter and assembles the `-32600` envelope or the flat
  object accordingly. That is what lets the three wire checks
  (`Wymcp.Plugs.OriginCheck`, `Wymcp.Plugs.Auth`,
  `Wymcp.Plugs.SingletonHeaders`), each of which runs on both POST and the
  GET/DELETE routes, state a status and a message once rather than carry a
  private dialect switch. `rejection_id/1` holds the rule for what id such
  an envelope echoes — applied by the singleton-header check and by
  `Wymcp.Plugs.Session`'s missing-header and lifecycle 400s. Two sites
  deliberately pass the raw body id instead and are documented at their call
  sites: `Wymcp.Plugs.Auth`'s 401 and `Wymcp.Plugs.Session`'s
  `protocol_version_mismatch/1`.

  Three rejections stay assembled at their call sites, each carrying a
  different *meaning* rather than merely a different shape — absorbing them
  would need both an error-type and a raw data-map parameter, leaving the
  sender with no opinion at all:

    * `Wymcp.Plugs.Session`'s `session_terminated/2` — error type
      `:session_not_found` and **no** `data` map, matching the TypeScript
      SDK byte-for-byte.
    * `Wymcp.Plugs.Validate` — echoes `:original_request` alongside the error.
    * `Wymcp.Plugs.Pipeline`'s body-parse rescue — error type `:parse_error`,
      data key `:reason`.

  Two POST answers carry no envelope and so use no sender: the bare `202`
  acknowledging a client-delivered JSON-RPC response
  (`Wymcp.Methods.DeliverResponse`) and the bare `404` answering an
  unrecognized session on a message with no id to answer — a JSON-RPC
  response or a notification (`Wymcp.Plugs.Session`). JSON-RPC forbids
  replying to either with an envelope, so there is nothing to send.

  Renamed from Vancouver's `Method` module for clarity: this module's only job
  is sending the HTTP response, it has nothing to do with JSON-RPC methods.
  """

  import Plug.Conn

  alias Wymcp.JsonRpc

  def send_json(%Plug.Conn{} = conn, %{} = response) do
    body = JSON.encode!(response)
    status = conn.status || 200

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, body)
    |> halt()
  end

  @doc """
  Sends a plain-JSON dialect error — the flat `%{error: message}` object the
  GET/DELETE routes and their wire checks answer with — and halts.

  The given `status` is sent as-is; a previously-set `conn.status` is not
  consulted (unlike `send_json/2`, which preserves it).
  """
  def send_plain_error(%Plug.Conn{} = conn, status, message) when is_integer(status) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, JSON.encode!(%{error: message}))
    |> halt()
  end

  @doc """
  Sends a rejection in the given error dialect and halts — the shared sender
  behind the wire checks' rejections and `Wymcp.Plugs.Session`'s 400s.

  Taking the dialect as a parameter is what lets a plug that runs on both
  POST and the GET/DELETE routes state its status and message once, instead
  of carrying a private two-clause dialect switch. `request_id` is used by
  the `:json_rpc` dialect only — the plain-JSON dialect's flat object carries
  no id — so callers with nothing to echo pass `nil`.

  `message` is guarded no more tightly than `send_plain_error/3` guards its
  own: a consumer's `c:Wymcp.Auth.authenticate/1` may reject with an atom
  reason (`{:error, :invalid_token}`), which both dialects render as the
  string `"invalid_token"`. An `is_binary/1` guard here would turn that
  supported answer into a 500.
  """
  def send_error(conn, status, request_id, message, dialect \\ :json_rpc)

  def send_error(%Plug.Conn{} = conn, status, request_id, message, :json_rpc)
      when is_integer(status) do
    response = JsonRpc.error_response(:invalid_request, request_id, %{error: message})

    conn
    |> put_status(status)
    |> send_json(response)
  end

  def send_error(%Plug.Conn{} = conn, status, _request_id, message, :plain_json)
      when is_integer(status) do
    send_plain_error(conn, status, message)
  end

  @doc """
  The id a rejection envelope echoes: the request body's `id`, except on a
  JSON-RPC *response* message, where it is `nil`.

  A response message's `id` was minted by the **server** for a request of its
  own (a sampling or elicitation call). Echoing it inside an error envelope
  offers a strict client a second, conflicting answer to that outstanding
  request — which is the same reason `Wymcp.Plugs.Session` answers a
  response message's 404 with an empty body. A notification has no `id` by
  construction, so the one rule covers every message kind without
  enumerating them.

  `Map.get/3` rather than `conn.body_params["id"]`: on the routes that parse
  no body, `body_params` is a `Plug.Conn.Unfetched` struct whose `Access`
  callbacks raise.
  """
  def rejection_id(%Plug.Conn{} = conn) do
    case conn.assigns[:wymcp_message_type] do
      :response -> nil
      _request_notification_or_unclassified -> Map.get(conn.body_params, "id")
    end
  end
end
