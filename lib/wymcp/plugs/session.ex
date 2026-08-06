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

  Every rejection below carries the id `Wymcp.Response.rejection_id/1` gives:
  the body's on a request, `nil` on every other message kind. That holds for
  the three 400s, which route through `Wymcp.Response.send_rejection/4`, and
  for the 404, which assembles its own envelope but branches on the same rule
  — see "Wire shape for session-not-found" below. There are no exceptions.

  ### Flow

  ```mermaid
  flowchart TD
      A[Incoming POST] --> B{Mcp-Session-Id<br/>required?}
      B -->|"no — initialize / ping"| Pass([pass through<br/>to next plug])
      B -->|yes| C{Header present?}
      C -->|no| R400Missing([HTTP 400<br/>JSON-RPC -32600<br/>missing header])
      C -->|yes| D{Session.lookup}
      D -->|":not_found"| F{rejection_id?}
      F -->|"an id<br/>(a request)"| R404Body([HTTP 404<br/>JSON-RPC -32001<br/>'Session terminated'<br/>no data field])
      F -->|"nil<br/>(every other kind)"| R404Empty([HTTP 404<br/>empty body])
      D -->|"{:ok, pid}"| E[assign pid<br/>+ touch] --> G{Version header<br/>matches?}
      G -->|"no"| R400Version([HTTP 400<br/>JSON-RPC -32600<br/>version mismatch])
      G -->|"yes, absent,<br/>or not enforced"| K{Response<br/>message?}
      K -->|"yes"| Pass
      K -->|"no — every<br/>other kind"| H{Lifecycle gate}
      H -->|"exempt method<br/>or session ready"| Pass
      H -->|"otherwise"| R400Lifecycle([HTTP 400<br/>JSON-RPC -32600<br/>session not ready])
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
    * A **response message** skips the lifecycle gate entirely, whatever its
      method: `call/2` routes it to `resolve_session_for_response/1`, which
      checks the protocol version and stops. Unlike the two lists above this is
      not a method exemption — `session_not_ready/1` is simply unreachable on
      that path.

  ### Wire shape for session-not-found

  The 404 body branches on the rejection-id rule
  (`Wymcp.Response.rejection_id/1`): it carries an envelope exactly when the
  rule yields an id, which is exactly when the inbound message is a request.

    * **Request** — body is `{"jsonrpc":"2.0","id":<request-id>,"error":
      {"code":-32001,"message":"Session terminated"}}`, matching the
      TypeScript SDK exactly: see `modelcontextprotocol/typescript-sdk`,
      `packages/server/src/server/streamableHttp.ts`, where the SDK throws
      `new McpError(-32001, "Session terminated")` with no `data` field.
      Matching that wire shape exactly maximises the chance compliant clients
      (which MUST re-initialise on this response) recognise it.

    * **Every other message kind** — a notification, a response message, or a
      body `Wymcp.Plugs.Classify` could not tag — HTTP 404 with empty body.
      The rule gives no id, and an id-bearing reply is what JSON-RPC forbids
      here: a response message's `id` belongs to a request the server itself
      sent, so echoing it would be a second answer to a call the client is
      still waiting on.

  An id-less envelope would *not* be forbidden — the MCP spec names that shape
  for rejected input — so the empty body is a choice, not a constraint. The
  reason it stays empty is that the status is the whole signal: a client
  receiving 404 must start a new session, so there is exactly one next action
  and no diagnostic string would add to it. That is also why the argument which
  decided the 400s does not transfer — a 400 names something the client author
  must fix, and naming it is the point.
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
    send_rejection(
      conn,
      400,
      "Missing Mcp-Session-Id header. Initialize first."
    )
  end

  defp session_terminated(conn, session_id) do
    Wymcp.Telemetry.emit(:session, :not_found, %{}, %{
      session_id: session_id,
      request_id: conn.body_params["id"],
      method: conn.body_params["method"]
    })

    require Logger

    Logger.info(
      "Session terminated (id: #{session_id}). Returning 404 to prompt client re-initialise."
    )

    case rejection_id(conn) do
      nil ->
        conn
        |> send_resp(404, "")
        |> halt()

      id ->
        conn
        |> put_status(404)
        |> send_json(JsonRpc.error_response(:session_not_found, id))
    end
  end

  defp session_not_ready(conn) do
    send_rejection(
      conn,
      400,
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

  defp protocol_version_mismatch(conn) do
    send_rejection(
      conn,
      400,
      "Incorrect MCP-Protocol-Version header. Expected the version negotiated during initialize."
    )
  end
end
