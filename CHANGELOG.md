# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.7.0]

### Added

- `:www_authenticate` router option — keyword list of RFC 6750 auth-params
  appended to the `Bearer` challenge in the 401 `WWW-Authenticate` header
  (e.g. an RFC 9728 `resource_metadata` pointer and a `scope` hint, completing
  the OAuth discovery chain for spec-following MCP clients such as mcp-remote).
  Values are strings or `{module, function, args}` tuples resolved per request.
  Without the option the challenge stays bare `Bearer` — existing consumers
  are unaffected. If rendering an entry raises (e.g. a misconfigured MFA), the
  challenge degrades to bare `Bearer` for that request and an error is logged
  — the 401 contract survives misconfiguration.

## [0.6.0]

### Added

- `strict_params?/0` optional `Wymcp.Tool` callback (defaults to `true`).

### Changed

- **BREAKING (default behavior):** `Wymcp.Tool.dispatch` now rejects data keys
  not declared in an action's `:properties` by default (`strict_params?/0`
  defaults to `true`), returning an `unknown_params` error instead of silently
  ignoring them. Set `def strict_params?, do: false` per tool to restore the
  permissive behavior. **Consumers upgrading to 0.6.0 must first audit their
  tools** — confirm no action reads (directly, via a forwarded `data`/params
  map, or `Map.get/3`) a key absent from that action's `:properties`; declare
  any legitimate caller-facing key, and leave server-injected keys undeclared
  (rejection-if-sent is the intended, more-secure outcome).

## [0.5.0]

**DATE:** 2026-05-08

### Added

- `Wymcp.Tool` action schemas may now omit `:required` and `:defaults`
  entirely. Omitted is equivalent to `required: []` / `defaults: %{}`. The
  `action_schema` type was tightened to document this and to declare
  `:notes`, `:related`, and `:examples` as the optional fields they have
  always been at the runtime level.

  Bare action — `:required` and `:defaults` both omitted:

      list: %{
        description: "List things",
        properties: %{"limit" => %{"type" => "integer"}}
      }

- `Wymcp.Tool` action schemas now support an optional `:required_one_of`
  field for declaring OR-of-AND required-field groups. Each group is a list
  of field names; at least one group must be fully present in `data`.
  Combines with `:required` (both checks run, both must pass). Surfaces in
  `help` and `describe` output and is rendered into `inputSchema` as
  `anyOf` constraints on the action variant's `data`.

  Example:

      get_pull_request: %{
        description: "Get pull request details",
        properties: %{
          "url" => %{"type" => "string"},
          "project_key" => %{"type" => "string"},
          "repo_slug" => %{"type" => "string"},
          "pr_id" => %{"type" => "integer"}
        },
        required_one_of: [["url"], ["project_key", "repo_slug", "pr_id"]]
      }

- `Wymcp.Router.init/1` now validates the shape of every action schema in
  every registered tool at boot via `Wymcp.Tool.validate_actions!/1`.
  Misconfiguration (a `:required_one_of` group that isn't a list of
  binaries, references a field not declared in `:properties`, is empty, is
  a duplicate, or is a strict superset of another group) raises
  `ArgumentError` immediately, surfacing the problem at startup rather
  than at the first request. Boot-time validation also rejects bad
  documentation-field shapes: `:notes` that isn't a binary, `:related`
  that isn't a list of binaries, and `:examples` that isn't a list of
  maps — so a typo like `notes: 123` fails fast instead of rendering
  oddly in `describe` output.

### Changed

- The `:missing_required_fields` error response now uses `error:
  "missing_required_group"` (with `required_one_of:` and a human-readable
  `message:` payload) when the failure is on the new `:required_one_of`
  constraint, distinguishing it from the existing `error:
  "missing_required_fields"` (with `missing:`) used for `:required`. Both
  error responses now expose the full schema summary (including
  `:required_one_of` when declared) under `input_schema:` so clients see
  every active constraint regardless of which one tripped.

## [0.4.1]

**DATE:** 2026-05-05

### Changed (BREAKING)

- `serverInfo.icons[]` emitted by `initialize` now strictly conforms
  to the MCP 2025-11-25 `Icon` schema. The accepted input shape for
  `:icons` inside `Wymcp.Router`'s `:server_info` option changed:
    * Required: `:src` (was previously `:url`).
    * Optional: `:mime_type` (was previously `:media_type`), `:sizes`,
      `:theme`.
  Legacy `:url` and `:media_type` keys are no longer recognised — they
  are dropped from the response and surfaced via a `Logger.warning/1`
  naming every unknown key. Update call sites accordingly. There is no
  back-compat shim; the project is pre-1.0 and cleaning up the encoder
  was the priority.

### Fixed

- Strict MCP clients (notably Claude.ai) previously tore down the
  session on `initialize` because the response carried `"url"` /
  `"media_type"` keys that the spec does not define. The new encoder
  uses an explicit whitelist (`:src`, `:mime_type`, `:sizes`,
  `:theme`) so the response matches the spec exactly.

### Added

- `Wymcp.Methods.Initialize` now logs a `Logger.warning/1` whenever a
  caller passes an unrecognised key inside an icon map. The warning
  names every dropped key and the accepted set, so a misconfigured
  caller can find the source quickly without diffing JSON payloads.

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
