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

  Above them sits `send_rejection/4`, the shared rejection sender: it takes the
  dialect as a parameter and assembles the `-32600` envelope or the flat object
  accordingly. That is what lets the three wire checks
  (`Wymcp.Plugs.OriginCheck`, `Wymcp.Plugs.Auth`,
  `Wymcp.Plugs.SingletonHeaders`), each of which runs on both POST and the
  GET/DELETE routes, state a status and a message once rather than carry a
  private dialect switch. `rejection_id/1` holds the rule for what id such an
  envelope echoes, and the sender applies it — no call site passes an id, so
  none can choose otherwise.

  Two places answer `nil` structurally rather than by consulting the rule, and
  both do so because no message kind is known to them yet:
  `Wymcp.Plugs.Pipeline`'s body-parse rescue (no body parsed) and
  `Wymcp.Plugs.OriginCheck` on POST, which is pipeline plug 1 and therefore
  runs ahead of `Wymcp.Plugs.Classify` — so its 403 carries a null id even for
  a well-formed request that does have one on the wire.

  Three rejections stay assembled at their call sites, each carrying a
  different *meaning* rather than merely a different shape — absorbing them
  would need both an error-type and a raw data-map parameter, leaving the
  sender with no opinion at all. Two of the three read `rejection_id/1`
  themselves, so bypassing the sender is not bypassing the rule:

    * `Wymcp.Plugs.Session`'s `session_terminated/2` — error type
      `:session_not_found` and **no** `data` map, matching the TypeScript SDK
      byte-for-byte; it branches on the rule rather than passing it a value,
      sending an envelope exactly when the rule yields an id.
    * `Wymcp.Plugs.Validate` — echoes `:original_request` alongside the error.
    * `Wymcp.Plugs.Pipeline`'s body-parse rescue — error type `:parse_error`,
      data key `:reason`. The one site that hardcodes `nil`: it runs when no
      body parsed, so there is nothing to read a rule from.

  Two POST answers carry no envelope and so use no sender: the bare `202`
  acknowledging a client-delivered JSON-RPC response
  (`Wymcp.Methods.DeliverResponse`) and the bare `404` answering an
  unrecognized session on a message the rejection-id rule gives no id for
  (`Wymcp.Plugs.Session`). What JSON-RPC forbids is an **id-bearing** reply to
  a response message — that is a second answer to a request still outstanding.
  An id-less error body is not a reply to anything, and the MCP spec names it
  explicitly: on input the server cannot accept, the body *"MAY comprise a
  JSON-RPC error response that has no `id`"*. So the 400s legitimately carry a
  null-id envelope; the 404 stays empty for a different reason — a client
  receiving it must start a new session, so the status is the whole signal and
  a diagnostic string would name no next action.

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
  Sends a rejection (`docs/glossary.md`, *rejection*) in the given error
  dialect and halts — the shared sender behind the wire checks' rejections and
  `Wymcp.Plugs.Session`'s 400s.

  Taking the dialect as a parameter is what lets a plug that runs on both POST
  and the GET/DELETE routes state its status and message once, instead of
  carrying a private two-clause dialect switch.

  The envelope's id is not a parameter: it comes from `rejection_id/1`, so no
  call site can pass one and none can choose otherwise. That is why the
  function is named for the rejection rather than for the error —
  `Wymcp.JsonRpc.error_response/3` remains the general builder for errors that
  are not rejections. The derivation sits in the `:json_rpc` clause alone: the
  plain-JSON dialect's flat object carries no id field at all, so computing one
  on that path would feed a value nothing reads.

  `message` is guarded no more tightly than `send_plain_error/3` guards its
  own: a consumer's `c:Wymcp.Auth.authenticate/1` may reject with an atom
  reason (`{:error, :invalid_token}`), which both dialects render as the string
  `"invalid_token"`. An `is_binary/1` guard here would turn that supported
  answer into a 500.
  """
  def send_rejection(conn, status, message, dialect \\ :json_rpc)

  def send_rejection(%Plug.Conn{} = conn, status, message, :json_rpc)
      when is_integer(status) do
    response = JsonRpc.error_response(:invalid_request, rejection_id(conn), %{error: message})

    conn
    |> put_status(status)
    |> send_json(response)
  end

  def send_rejection(%Plug.Conn{} = conn, status, message, :plain_json)
      when is_integer(status) do
    send_plain_error(conn, status, message)
  end

  @doc """
  The id a rejection envelope echoes: the body's `id` on a JSON-RPC
  **request**, and `nil` on every other message kind.

  An id on a non-request message was minted by the **server** for a request of
  its own — a sampling or elicitation call. Echoing it inside an error envelope
  offers a strict client a second, conflicting answer to a request the client
  is still waiting on.

  The rule is stated positively rather than as "except on a response message"
  because `Wymcp.Plugs.Classify` tags `:response` only when an `id` sits beside
  a `result` or an `error`. A truncated client answer tags `:unknown`, and
  those are precisely the bodies where a request and a response cannot be told
  apart — so they must not keep their id either. Classify's `:request` test is
  looser than schema validity, so a *recognisable* malformed request keeps its
  id and stays correlatable.

  `Map.get/3` rather than `conn.body_params["id"]`: on the routes that parse no
  body, `body_params` is a `Plug.Conn.Unfetched` struct whose `Access`
  callbacks raise.
  """
  def rejection_id(%Plug.Conn{} = conn) do
    case conn.assigns[:wymcp_message_type] do
      :request -> Map.get(conn.body_params, "id")
      _every_other_message_kind -> nil
    end
  end
end
