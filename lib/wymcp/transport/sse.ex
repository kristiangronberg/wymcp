defmodule Wymcp.Transport.SSE do
  @moduledoc """
  Pure SSE event encoding.

  Formats JSON-RPC messages as Server-Sent Events per the MCP Streamable
  HTTP transport specification. No process state, no side effects — just
  string formatting.

  ## SSE Format

  Each event has an optional ID (for resumability) and a data field
  containing a JSON-RPC message:

      id: <event-id>
      data: <json>

  Messages must not contain embedded newlines. Events are separated by
  a blank line (`\\n\\n`).

  ## Related Modules

  See: `Wymcp.Transport.Stream`

  ## Tests

  See: `Wymcp.Transport.SSETest`
  """

  @spec encode(map(), String.t() | nil) :: String.t()
  def encode(message, nil) do
    "data: #{JSON.encode!(message)}\n\n"
  end

  def encode(message, event_id) do
    "id: #{event_id}\ndata: #{JSON.encode!(message)}\n\n"
  end

  @spec encode_empty(String.t()) :: String.t()
  def encode_empty(event_id) do
    "id: #{event_id}\ndata: \n\n"
  end
end
