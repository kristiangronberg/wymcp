# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
