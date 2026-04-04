defmodule Wymcp.Plugs.Session do
  @moduledoc false

  import Plug.Conn
  import Wymcp.Response
  alias Wymcp.{JsonRpc, Session}

  @behaviour Plug

  # Methods exempt from session lookup entirely (no session needed)
  @session_exempt_methods ["initialize", "ping"]

  # Methods exempt from the lifecycle gate (allowed during :initializing).
  # tools/list and tools/call are exempt because clients (via mcp-remote)
  # send them concurrently with notifications/initialized — the session
  # may not be :ready yet when they arrive.
  @lifecycle_exempt_methods [
    "initialize",
    "notifications/initialized",
    "ping",
    "tools/list",
    "tools/call"
  ]

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(%Plug.Conn{} = conn, _opts) do
    case conn.assigns[:wymcp_message_type] do
      :response ->
        resolve_session_for_response(conn)

      _request_or_notification ->
        method = conn.body_params["method"]

        if method in @session_exempt_methods do
          conn
        else
          resolve_session(conn)
        end
    end
  end

  @spec resolve_session_for_response(Plug.Conn.t()) :: Plug.Conn.t()
  defp resolve_session_for_response(conn) do
    case get_req_header(conn, "mcp-session-id") do
      [session_id] ->
        case Session.lookup(session_id) do
          {:ok, pid} ->
            Session.touch(pid)

            conn
            |> assign(:wymcp_session_pid, pid)
            |> assign(:wymcp_session_id, session_id)
            |> check_protocol_version(pid)

          {:error, :not_found} ->
            session_fallthrough(conn)
        end

      [] ->
        missing_session_header(conn)
    end
  end

  @spec resolve_session(Plug.Conn.t()) :: Plug.Conn.t()
  defp resolve_session(conn) do
    method = conn.body_params["method"]

    case get_req_header(conn, "mcp-session-id") do
      [session_id] ->
        case Session.lookup(session_id) do
          {:ok, pid} ->
            Session.touch(pid)

            conn
            |> assign(:wymcp_session_pid, pid)
            |> assign(:wymcp_session_id, session_id)
            |> check_protocol_version(pid)
            |> check_lifecycle_gate(pid, method)

          {:error, :not_found} ->
            session_fallthrough(conn)
        end

      [] ->
        missing_session_header(conn)
    end
  end

  @spec check_lifecycle_gate(Plug.Conn.t(), pid(), String.t()) :: Plug.Conn.t()
  defp check_lifecycle_gate(%Plug.Conn{halted: true} = conn, _pid, _method), do: conn

  defp check_lifecycle_gate(conn, _pid, method) when method in @lifecycle_exempt_methods do
    conn
  end

  defp check_lifecycle_gate(conn, pid, _method) do
    if Session.ready?(pid) do
      conn
    else
      session_not_ready(conn)
    end
  end

  @spec missing_session_header(Plug.Conn.t()) :: Plug.Conn.t()
  defp missing_session_header(conn) do
    request_id = conn.body_params["id"]
    data = %{error: "Missing Mcp-Session-Id header. Initialize first."}
    response = JsonRpc.error_response(:invalid_request, request_id, data)

    conn
    |> put_status(400)
    |> send_json(response)
  end

  @spec session_fallthrough(Plug.Conn.t()) :: Plug.Conn.t()
  defp session_fallthrough(conn) do
    session_id = List.first(get_req_header(conn, "mcp-session-id"))

    require Logger

    Logger.warning("Session not found or expired (id: #{session_id}). Operating sessionless.")

    assign(
      conn,
      :wymcp_session_warning,
      "Session not found or expired. Per-session state has been reset."
    )
  end

  @spec session_not_ready(Plug.Conn.t()) :: Plug.Conn.t()
  defp session_not_ready(conn) do
    request_id = conn.body_params["id"]
    data = %{error: "Session not yet initialized. Send notifications/initialized first."}
    response = JsonRpc.error_response(:invalid_request, request_id, data)

    conn
    |> put_status(400)
    |> send_json(response)
  end

  @spec check_protocol_version(Plug.Conn.t(), pid()) :: Plug.Conn.t()
  defp check_protocol_version(conn, pid) do
    expected = Session.protocol_version(pid)

    case get_req_header(conn, "mcp-protocol-version") do
      [^expected] ->
        conn

      [] ->
        # Header absent — allow through. Major clients (Claude Desktop)
        # don't send MCP-Protocol-Version yet.
        conn

      [_wrong] ->
        protocol_version_mismatch(conn)
    end
  end

  @spec protocol_version_mismatch(Plug.Conn.t()) :: Plug.Conn.t()
  defp protocol_version_mismatch(conn) do
    request_id = conn.body_params["id"]

    data = %{
      error:
        "Incorrect MCP-Protocol-Version header. Expected the version negotiated during initialize."
    }

    response = JsonRpc.error_response(:invalid_request, request_id, data)

    conn
    |> put_status(400)
    |> send_json(response)
  end
end
