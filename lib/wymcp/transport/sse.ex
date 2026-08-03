defmodule Wymcp.Transport.SSE do
  @moduledoc """
  Pure SSE event framing.

  Formats pre-encoded JSON-RPC payloads as Server-Sent Events per the MCP
  Streamable HTTP transport specification. No process state, no side
  effects — just string formatting. JSON encoding happens at the push
  entries (`Wymcp.Session.push/3`, `Wymcp.Session.await_client_response/4`)
  in the pusher's own process; by the time a payload reaches this module it
  is a JSON binary, which cannot contain a raw newline (`JSON` escapes
  control characters) — so the SSE `data:` line cannot be broken by
  content, by construction rather than by an unenforced precondition.

  ## SSE Format

  Each event has an optional ID (for resumability) and a data field
  containing a JSON-RPC message:

      id: <event-id>
      data: <json>

  Events are separated by a blank line (`\\n\\n`).
  """

  def frame(json, nil) when is_binary(json) do
    "data: #{json}\n\n"
  end

  def frame(json, event_id) when is_binary(json) do
    "id: #{event_id}\ndata: #{json}\n\n"
  end

  def frame_empty(event_id) do
    "id: #{event_id}\ndata: \n\n"
  end
end
