defmodule Wymcp.Transport.Stream do
  @moduledoc """
  Opens and manages SSE streams on a Plug connection.

  Wraps `Plug.Conn.send_chunked/2` with SSE content-type headers and
  provides helpers to push JSON-RPC messages formatted as SSE events.

  ## Keepalive

  SSE connections over proxies and load balancers are dropped if idle.
  Call `push_keepalive/1` periodically (e.g. every 15 seconds) to send
  an SSE comment that maintains the connection without triggering
  client-side event handlers. The caller is responsible for scheduling
  keepalive messages (e.g. via `Process.send_after`).
  """

  import Plug.Conn
  alias Wymcp.Transport.SSE

  def open(conn) do
    conn
    |> put_resp_content_type("text/event-stream")
    |> put_resp_header("cache-control", "no-cache")
    |> send_chunked(200)
  end

  def push(conn, message, event_id \\ nil) do
    chunk(conn, SSE.encode(message, event_id))
  end

  def push_empty(conn, event_id) do
    chunk(conn, SSE.encode_empty(event_id))
  end

  def push_keepalive(conn) do
    chunk(conn, ":keepalive\n\n")
  end
end
