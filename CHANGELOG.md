# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.4.0]

**DATE:** 2026-05-05

### Changed (BREAKING)

- Messages carrying an unrecognised `Mcp-Session-Id` are now rejected
  with HTTP 404. The previous behaviour was to silently fall through
  to "sessionless" mode (HTTP 200, compile-time tools, response
  decorated with `_meta.warnings`). The new behaviour matches MCP
  2025-11-25 Streamable HTTP / Session Management clauses 3 and 4,
  so compliant clients receive the signal they need to re-initialise.
  The 404 body branches on JSON-RPC message kind so JSON-RPC 2.0 is
  not violated for non-request traffic:
    * **Request** — `{"jsonrpc":"2.0","id":<id>,"error":{"code":
      -32001,"message":"Session terminated"}}`. This wire shape
      (code, message, no `data` field) matches the official
      TypeScript SDK exactly
      (`modelcontextprotocol/typescript-sdk`,
      `packages/server/src/server/streamableHttp.ts`).
    * **Notification** (no `id`) — HTTP 404 with empty body.
    * **Response message** — HTTP 404 with empty body.

  Consumers that relied on the workaround must either upgrade their
  client to one that handles 404 by issuing a fresh
  `InitializeRequest`, or — if the server genuinely has no
  per-session state — bypass the session layer at the consumer
  boundary; wymcp itself no longer offers a silent-fallthrough mode.

### Added

- `[:wymcp, :session, :not_found]` telemetry event emitted whenever a
  message bearing an unrecognised `Mcp-Session-Id` is rejected. See
  `Wymcp.Telemetry` for metadata shape (`session_id`, `request_id`,
  `method`).
- `Wymcp.JsonRpc.error_response/2` — emits an `error` object with no
  `data` field. Used by the request-kind 404 to match the TypeScript
  SDK wire shape exactly. Existing call sites that pass `data`
  continue to use the 3-arity form.

### Removed

- `:wymcp_session_warning` conn assign and the `_meta.warnings`
  decoration on `tools/list` and `tools/call` responses. Both existed
  to surface the silent-fallthrough state; both are now unreachable.
- `Wymcp.Methods.ToolsList`'s and `Wymcp.Methods.ToolsCall`'s
  compile-time-tools fallback when `:wymcp_session_pid` is absent.
  The fallback was only reachable via the deleted fallthrough path.
- Defensive `if session_pid` / `Process.alive?(session_pid)` guards in
  `Wymcp.Methods.Initialized.run/1`,
  `Wymcp.Methods.Cancelled.run/1`,
  `Wymcp.Methods.DeliverResponse.run/1`,
  `Wymcp.Methods.ToolsCall.build_context/1`, and
  `Wymcp.Methods.ToolsCall.persist_assigns/2`. With session
  presence enforced upstream by `Plugs.Session`, these guards became
  unreachable; removing them makes the
  "`:wymcp_session_pid` is an invariant for non-exempt methods"
  contract explicit. A dead-session edge case (e.g. session
  terminated between plug and method) now crashes rather than
  silently no-ops.

## [0.3.0]

### Changed (BREAKING)

- `c:Wymcp.Tool.action_context/1` is now `c:Wymcp.Tool.action_context/2`.
  The callback receives `(action_atom, ctx)` where `ctx` is the same
  `Wymcp.Context.t()` passed to `run_action/3`. Consumers that override
  `action_context` must update the arity. Read per-request scope from
  `ctx.assigns[:current_scope]` (or wherever the consumer's auth plug
  put it) instead of the process dictionary — `ctx.assigns` is the
  explicit per-request channel and does not depend on which process
  ends up dispatching the callback.

### Changed

- Tool exceptions in `tools/call` now return a successful JSON-RPC
  response with `isError: true` and a JSON-encoded diagnostic content
  body (`errorType`, `tool`, `exception`, `message`). Previously they
  returned a -32603 protocol error with empty `data`. Per MCP
  2025-11-25, tool-originated errors must be reported as `isError`
  content so the LLM can see and self-correct on them.

### Added

- `[:wymcp, :auth, :reject]` and `[:wymcp, :auth, :error]` telemetry
  events from `Wymcp.Plugs.Auth`. See `Wymcp.Telemetry` for metadata
  shape.
- `Wymcp.Plugs.Auth` now emits a structured `Logger.warning` on the
  expected rejection branch and a structured `Logger.error` on the
  rescue branch, both with `auth_module`, `request_id`, and `method`
  metadata.
