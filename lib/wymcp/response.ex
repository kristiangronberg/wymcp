defmodule Wymcp.Response do
  @moduledoc """
  Sends JSON-RPC responses over the Plug connection.

  This is the lowest-level output module in the pipeline. Every MCP response —
  whether a successful tool result, a JSON-RPC error, or an auth rejection —
  flows through `send_json/2`. It preserves any previously-set HTTP status code
  and halts the connection after sending.

  Renamed from Vancouver's `Method` module for clarity: this module's only job
  is sending the HTTP response, it has nothing to do with JSON-RPC methods.
  """

  import Plug.Conn

  @spec send_json(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def send_json(%Plug.Conn{} = conn, %{} = response) do
    body = JSON.encode!(response)
    status = conn.status || 200

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, body)
    |> halt()
  end
end
