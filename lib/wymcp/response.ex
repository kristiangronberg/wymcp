defmodule Wymcp.Response do
  @moduledoc """
  Sends wire responses over the Plug connection — the lowest-level output
  module in the pipeline.

  One sender per structured error dialect (`docs/glossary.md`, *error
  dialect*): `send_json/2` sends a JSON-RPC envelope as-is — every
  JSON-RPC-enveloped POST answer flows through it, and it preserves any
  previously-set HTTP status. `send_plain_error/3` sends the plain-JSON
  dialect's flat `%{error: message}` object — the rejection body of the
  GET/DELETE routes and of the wire checks running on them. Both halt the
  connection after sending.

  Two POST answers carry no envelope and so use neither sender: the bare
  `202` acknowledging a client-delivered JSON-RPC response
  (`Wymcp.Methods.DeliverResponse`) and the bare `404` answering an
  unrecognized session on a message with no id to answer — a JSON-RPC
  response or a notification (`Wymcp.Plugs.Session`). JSON-RPC forbids
  replying to either with an envelope, so there is nothing to send.

  Renamed from Vancouver's `Method` module for clarity: this module's only job
  is sending the HTTP response, it has nothing to do with JSON-RPC methods.
  """

  import Plug.Conn

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
end
