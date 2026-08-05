defmodule Wymcp.Plugs.Session do
  @moduledoc """
  Resolves the MCP session for an incoming request and enforces the
  spec-mandated lifecycle.

  Three outcomes per request:

    * **Session header present and registered** — assigns
      `:wymcp_session_pid` and `:wymcp_session_id`, calls `Session.touch/1`,
      and validates the `MCP-Protocol-Version` header (see
      `Wymcp.ProtocolVersion`) against the version pinned at `initialize`
      time — on response messages as well as requests. Downstream methods
      read tools from the session pid, not from compile-time options.

    * **Session header missing on a non-exempt method** — rejects
      with HTTP 400 + JSON-RPC -32600 (`invalid_request`). Per the
      MCP 2025-11-25 spec: "Servers that require a session ID SHOULD
      respond to requests without an `MCP-Session-Id` header with
      HTTP 400 Bad Request."

    * **Session header present but not registered** — rejects with
      HTTP 404. Per the MCP 2025-11-25 spec, Streamable HTTP / Session
      Management clauses 3 and 4: a server MAY terminate a session at
      any time and MUST then respond to requests carrying that ID
      with 404; the client MUST issue a fresh `InitializeRequest`. A
      server-restart-wiped in-memory registry is an instance of
      clause 3 — the spec does not distinguish "I never saw this ID"
      from "I terminated this ID".

  Header *cardinality* is not this plug's job: `Wymcp.Plugs.SingletonHeaders`
  runs upstream and rejects a duplicated `Mcp-Session-Id` or
  `MCP-Protocol-Version` before the request reaches here. That is why no read
  below carries a duplicate arm — on every path that gets here, the header
  carried at most one value. A header's *value* is still this plug's
  business, so `enforce_protocol_version_header/2` keeps a third clause for
  the value that is present but wrong. A read that crashes with
  `CaseClauseError` therefore means a route was wired without the check, not
  that a client sent something exotic.

  The missing-header and lifecycle 400s below carry the id
  `Wymcp.Response.rejection_id/1` gives: the body's, except on a response
  message, where it is `nil` — the same reasoning that makes the
  response-message 404 an empty body. `protocol_version_mismatch/1` is the
  one exception: it still echoes the raw body id even on a response message,
  a known gap left outside this change's scope and flagged at its call site.

  ### Flow

  ```mermaid
  flowchart TD
      A[Incoming POST] --> B{Mcp-Session-Id<br/>required?}
      B -->|"no — initialize / ping"| Pass([pass through<br/>to next plug])
      B -->|yes| C{Header present?}
      C -->|no| R400([HTTP 400<br/>JSON-RPC -32600<br/>invalid_request])
      C -->|yes| D{Session.lookup}
      D -->|"{:ok, pid}"| E[assign pid<br/>+ touch<br/>+ check version<br/>+ lifecycle gate] --> Pass
      D -->|":not_found"| F{Message kind?}
      F -->|"request<br/>(has id)"| R404Body([HTTP 404<br/>JSON-RPC -32001<br/>'Session terminated'<br/>no data field])
      F -->|notification or<br/>response message| R404Empty([HTTP 404<br/>empty body])
  ```

  ### Exemptions

    * `initialize` and `ping` skip session lookup entirely
      (`@session_exempt_methods`).
    * `tools/list`, `tools/call`, `notifications/initialized`, and the
      two exempt methods above also skip the lifecycle gate
      (`@lifecycle_exempt_methods`) — they are allowed to run while a
      session is still in `:initializing`. This is necessary because
      clients (notably `mcp-remote`) send `tools/list` and
      `tools/call` concurrently with `notifications/initialized`.

  ### Wire shape for session-not-found

  The 404 body branches on JSON-RPC message kind, since JSON-RPC 2.0
  forbids responding to notifications and to responses:

    * **Request** (`id` present, `wymcp_message_type` not `:response`)
      — body is `{"jsonrpc":"2.0","id":<request-id>,"error":{"code":
      -32001,"message":"Session terminated"}}`, matching the
      TypeScript SDK exactly: see
      `modelcontextprotocol/typescript-sdk`,
      `packages/server/src/server/streamableHttp.ts`, where the SDK
      throws `new McpError(-32001, "Session terminated")` with no
      `data` field. Matching that wire shape exactly maximises the
      chance compliant clients (which MUST re-initialise on this
      response) recognise it.

    * **Notification** (no `id`) — HTTP 404 with empty body. JSON-RPC
      2.0 forbids responding to notifications, so we do not emit an
      envelope. The 404 status alone carries the spec-required
      signal.

    * **Response message** (`wymcp_message_type == :response`) — HTTP
      404 with empty body. A JSON-RPC response carries an `id` of a
      server-initiated request the server already sent; replying to
      it with a JSON-RPC error would itself be a protocol violation.
  """

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
            session_terminated(conn, session_id)
        end

      [] ->
        missing_session_header(conn)
    end
  end

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
            session_terminated(conn, session_id)
        end

      [] ->
        missing_session_header(conn)
    end
  end

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

  defp missing_session_header(conn) do
    send_error(
      conn,
      400,
      rejection_id(conn),
      "Missing Mcp-Session-Id header. Initialize first."
    )
  end

  defp session_terminated(conn, session_id) do
    request_id = conn.body_params["id"]
    method = conn.body_params["method"]

    Wymcp.Telemetry.emit(:session, :not_found, %{}, %{
      session_id: session_id,
      request_id: request_id,
      method: method
    })

    require Logger

    Logger.info(
      "Session terminated (id: #{session_id}). Returning 404 to prompt client re-initialise."
    )

    if conn.assigns[:wymcp_message_type] == :response or is_nil(request_id) do
      conn
      |> send_resp(404, "")
      |> halt()
    else
      response = JsonRpc.error_response(:session_not_found, request_id)

      conn
      |> put_status(404)
      |> send_json(response)
    end
  end

  defp session_not_ready(conn) do
    send_error(
      conn,
      400,
      rejection_id(conn),
      "Session not yet initialized. Send notifications/initialized first."
    )
  end

  defp check_protocol_version(conn, pid) do
    expected = Session.protocol_version(pid)

    if Wymcp.ProtocolVersion.supports_protocol_version_header?(expected) do
      enforce_protocol_version_header(conn, expected)
    else
      conn
    end
  end

  defp enforce_protocol_version_header(conn, expected) do
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

  # The id stays the raw body id rather than rejection_id/1: this branch IS
  # reachable on the :response path, and narrowing it there would be a fifth
  # wire change, outside this topic's four. Filed thought, not an oversight —
  # see the topic's plan.md, Assumptions.
  defp protocol_version_mismatch(conn) do
    send_error(
      conn,
      400,
      conn.body_params["id"],
      "Incorrect MCP-Protocol-Version header. Expected the version negotiated during initialize."
    )
  end
end
