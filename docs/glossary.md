# Glossary

Canonical domain terms for this project. Code and docs use these terms;
`_Avoid_` synonyms are banned in new names. Definitions live only here —
other documents point here instead of redefining.

## Grandfathered (pending define)

Swept from the existing code and docs on 2026-07-05 (glossary bootstrap).
Each entry records the term's *apparent* meaning and where it lives —
recorded, not blessed. Grandfathered terms are canonical by default (do not
invent synonyms for them) but each awaits a define session. **Overloaded:**
marks a term carrying more than one meaning; the cross-cutting flags at the
end collect the synonym sets that span entries.

### Tools & actions

- **tool** — a module implementing the `Wymcp.Tool` behaviour, exposing named actions to LLM clients; the only MCP primitive wymcp implements. **Overloaded:** also a string tool *name* (`Hint.tool`), a capability flag (`capabilities.tools`), and a sampling tool definition (`CreateMessageRequestParams.tools`). (`Wymcp.Tool`, README)
- **action** — a named operation within a tool, selected by the `"action"` param; atom internally, string on the wire. **Overloaded:** also the elicitation-response field `"action"` (values accept/decline/cancel) — same JSON key, unrelated semantics. (`Wymcp.Tool`, README §2)
- **action-dispatched pattern** — the design idiom where one tool name multiplexes many actions. (`Wymcp.Tool` moduledoc)
- **action schema** — the per-action definition map: `:description`, `:properties`, `:required`, `:required_one_of`, `:defaults`, `:notes`, `:related`, `:examples`. (`Wymcp.Tool` `@type action_schema`)
- **data** — the action-specific parameter sub-object inside a call's `arguments`. (`Wymcp.Tool`, `Wymcp.Tool.Schema`)
- **arguments** — the `tools/call` params object carrying `action` + `data`. (`Wymcp.Methods.ToolsCall`)
- **dispatch** — routing a call to its handler. **Overloaded:** action-level (`Wymcp.Tool.dispatch/4` → `run_action`), method-level (`Wymcp.Plugs.Dispatch` → `Methods.*`), and the stock `Plug.Router` `plug(:dispatch)`. (`Wymcp.Tool`, `Wymcp.Plugs.Dispatch`)
- **required** — unconditionally required property names, AND-semantics. **Overloaded:** also the JSON Schema keyword (array) and `PromptArgument.required` (boolean) in the protocol schema. (`Wymcp.Tool`)
- **required_one_of** — list of property groups; at least one group must be fully present (OR-of-AND), rendered as `anyOf`. (`Wymcp.Tool`, CHANGELOG 0.5.0)
- **defaults** — default values merged into `data` after validation, before dispatch. (`Wymcp.Tool`)
- **notes / related / examples** — optional documentation fields on an action schema, surfaced by describe. (`Wymcp.Tool`, CHANGELOG 0.5.0)
- **strict params** — rejection of `data` keys not declared in `:properties` (`strict_params?` callback, default true; `unknown_params` error). (`Wymcp.Tool`, CHANGELOG 0.6.0)
- **definition** — a tool's full MCP wire definition emitted in `tools/list`: name, description, inputSchema, optional title/annotations/outputSchema. (`Wymcp.Tool`)
- **input schema** (`inputSchema` on the wire) — the JSON Schema for a tool's arguments, generated from its actions. (`Wymcp.Tool.Schema`)
- **output schema** (`outputSchema`) — optional JSON Schema validating a tool's structured result; enables `structuredContent`; version-gated. (`Wymcp.Tool`, `Wymcp.Methods.ToolsCall`)
- **structuredContent** — the structured response object validated against the output schema, sent alongside `content`. (`Wymcp.Methods.ToolsCall`)
- **schema mode** (`:full` / `:slim`) — whether `tools/list` emits the full `oneOf` schema or the slim schema. (`Wymcp.Tool`, README §2b)
- **slim schema** — compact input schema: action enum + one-line descriptions, ~7× smaller `tools/list` payload. (`Wymcp.Tool.Schema`)
- **oneOf variant** — the per-action discriminated schema branch in full mode, const-tagged on `action`. (`Wymcp.Tool.Schema`)
- **help** — built-in introspection action: terse action summaries, or the slim schema for one topic; operational — "how to call". (`Wymcp.Tool`, README §2b)
- **describe** — built-in introspection action: full schema plus notes/examples/patterns; contextual — "what to know". (`Wymcp.Tool`, README §2b)
- **topic** (help/describe argument) — the single action to detail. Collides with the development-process "topic" in the roadmap (excluded from this glossary). (`Wymcp.Tool.dispatch`)
- **annotations** — optional tool metadata (readOnlyHint, destructiveHint, idempotentHint, openWorldHint). **Overloaded:** the protocol schema also has `Annotations` for *content* metadata (audience, priority, lastModified) — two different definitions. (`Wymcp.Tool`, priv/schema.json)
- **title** — human-readable display name for a tool or the server; version-gated to ≥ 2025-06-18. (`Wymcp.Tool`, `Wymcp.ProtocolVersion`)
- **isError** — flag marking a `tools/call` result as a tool-originated error, returned as a *successful* JSON-RPC response with error content so the LLM can self-correct. (`Wymcp.Methods.ToolsCall`, CHANGELOG 0.3.0)
- **runtime tools** — tools registered on a live session via `register_tool/2`; win over compile-time tools on name collision; trigger listChanged. (`Wymcp.Session`)
- **compile-time tools** — tools passed in the Router `:tools` option. Antonym pair with runtime tools. (`Wymcp.Router`, `Wymcp.Session`)

### Hints & context

- **hint** — a follow-up action suggestion (`%Wymcp.Hint{}`: tool, action, description, optional example) injected into responses via the `hints/2` callback. **Overloaded:** the protocol schema also has `ModelHint` (sampling model-name preference) and the `ToolAnnotations.*Hint` behavioral flags. (`Wymcp.Hint`, README §2c)
- **hint context** — the third element of a 3-tuple `run_action` return, passed to `hints/2`; works on both success and error returns. (`Wymcp.Tool`)
- **context** — **Overloaded, three meanings:** (1) `%Wymcp.Context{}`, the per-call execution context passed to `run_action` (session refs, request_id, meta, assigns, result builders); (2) the `"context"` response key filled by `action_context/2`; (3) hint context, above. (`Wymcp.Context`, `Wymcp.Tool`, README §2b)
- **action context** — per-action dynamic runtime info a tool injects under the `"context"` response key, via `action_context/2`. (`Wymcp.Tool`, CHANGELOG 0.3.0)
- **assigns** — merged per-request `conn.assigns` + per-session state exposed as `ctx.assigns` (session wins on collision, internal wymcp keys filtered); tools persist state by returning an assigns-updates map as the third tuple element. (`Wymcp.Context`, `Wymcp.Session`)
- **content** — the MCP content array of blocks (text, json/structured, image, audio) a tool returns. (`Wymcp.Context` `@type content`)
- **result builders** — the pure helpers `text/1`, `json/1`, `image/2`, `audio/2` producing MCP-compliant content blocks. (`Wymcp.Context`)

### Session & lifecycle

- **session** — one client connection's state (negotiated version, capabilities, tools, assigns, log level, pending requests) held in a GenServer; created at initialize, ended by DELETE, disconnect, or idle timeout. (`Wymcp.Session`)
- **session ID** (`Mcp-Session-Id`) — 32-byte URL-safe base64 identifier carried in the header; unknown IDs are rejected with 404 + `-32001`. (`Wymcp.Session`, `Wymcp.Plugs.Session`)
- **session status** (`:initializing` / `:ready`) — session lifecycle states; `notifications/initialized` marks ready. **Overloaded:** the protocol schema's `TaskStatus` is an unrelated state machine sharing the word. (`Wymcp.Session.State`)
- **lifecycle gate** — the plug check rejecting non-exempt methods while a session is `:initializing`. (`Wymcp.Plugs.Session`)
- **session-exempt methods** — methods that skip session lookup entirely (initialize, ping). (`Wymcp.Plugs.Session`)
- **lifecycle-exempt methods** — methods allowed during `:initializing` (adds tools/list, tools/call, notifications/initialized). (`Wymcp.Plugs.Session`)
- **idle timeout** — configurable inactivity expiry (default 30 min) that terminates a session; every request touches the timer. Distinct from the SSE keepalive. (`Wymcp.Session`)
- **touch** — resetting a session's idle timer on request activity. (`Wymcp.Session`, `Wymcp.Plugs.Session`)
- **Server behaviour** — the consumer's session-lifecycle hooks: `init/2` on ready, `terminate/2` on shutdown; deliberately no request hook. **Overloaded:** "server" also means the MCP server itself, `serverInfo`, and the "server" in server-initiated requests. (`Wymcp.Server`)
- **session terminated** (`-32001`, `:session_not_found`) — the MCP error for an unrecognized session ID, prompting the client to re-initialize. (`Wymcp.JsonRpc`, `Wymcp.Plugs.Session`)
- **sessionless fallback** (removed) — pre-0.4.0 behavior where unknown session IDs fell through to compile-time tools with `_meta.warnings`; also called "sessionless mode" and "silent-fallthrough". (CHANGELOG 0.4.0)

### Protocol & versioning

- **protocol version** — a dated MCP spec revision; supported: 2025-11-25, 2025-06-18, 2025-03-26; the split-endpoint 2024-11-05 is out of scope. Prose also says "revision". (`Wymcp.ProtocolVersion`, README)
- **negotiated version** — the protocol version pinned on a session at initialize; `Session.negotiated_version/1` is the single resolver (session pid → header → latest). Appears as `protocol_version` (state field) and `protocolVersion` (wire). (`Wymcp.Session`)
- **counter-proposal** — the server answering an unsupported requested version with its own latest in `InitializeResult.protocolVersion`. (`Wymcp.ProtocolVersion`, `Wymcp.Methods.Initialize`)
- **floor** — the lowest supported protocol version (2025-03-26). (README version table)
- **version gating** — omitting or stripping version-gated features for older-version sessions, via the `supports_*?` predicates and `strip_*` helpers. (`Wymcp.ProtocolVersion`)
- **initialize** — the handshake request that negotiates version + capabilities and creates the session. (`Wymcp.Methods.Initialize`)
- **initialized** — `notifications/initialized`, completing the handshake: transitions the session to ready and runs `Server.init/2`. (`Wymcp.Methods.Initialized`)
- **capability** — a declared client or server feature (tools, logging, sampling, elicitation, listChanged) exchanged at initialize; server-initiated features are gated on the client's declared capabilities. (`Wymcp.Methods.Initialize`, `Wymcp.Context.check_capability`)
- **serverInfo** — the server identity map in the initialize result: name, version, title, description, websiteUrl, icons. (`Wymcp.Router` `:server_info`, `Wymcp.Methods.Initialize`)
- **clientInfo** — the client identity from initialize params, stored on the session as `client_info`. (`Wymcp.Methods.Initialize`, `Wymcp.Session`)
- **instructions** — the initialize-result string guiding how an LLM should use the server's tools. (`Wymcp.Router` `:instructions`)
- **icon** — a serverInfo icon entry: src, mimeType, sizes, theme (legacy url/media_type dropped). (`Wymcp.Methods.Initialize`, CHANGELOG 0.4.1)
- **MCP-Protocol-Version header** — HTTP header echoing the negotiated version on post-init requests; enforced ≥ 2025-06-18, skipped on 2025-03-26. (`Wymcp.ProtocolVersion`, README)

### Transport & streaming

- **Streamable HTTP** — the MCP transport wymcp implements: POST + optional GET-SSE + DELETE on one endpoint; the older split-endpoint HTTP+SSE transport is deliberately unsupported. (README, `Wymcp.Router`)
- **stream** — the chunked SSE connection for one session; one active stream per session, a new GET replaces the old. (`Wymcp.Transport.StreamManager`)
- **StreamManager** — the GenServer owning a session's SSE connection, a separate process from the Session. (`Wymcp.Transport.StreamManager`)
- **push event** — sending a JSON-RPC message to the client over SSE; `Session.push_event` delegates to `StreamManager.push` (near-synonym pair). (`Wymcp.Session`, `Wymcp.Transport.StreamManager`)
- **priming event** — the initial empty SSE event giving the client an event ID for reconnection. (`Wymcp.Transport.StreamManager`)
- **keepalive** — the periodic SSE comment preventing proxy idle-disconnect (default 15 s). Distinct from the session idle timeout. (`Wymcp.Transport.Stream`, `Wymcp.Transport.StreamManager`)
- **event ID** (`evt-N`, `Last-Event-ID`) — the monotonic per-event SSE identifier for resumability; the header is read but replay is not implemented. (`Wymcp.Transport.StreamManager`, `Wymcp.Transport.SSE`)
- **message classification** — tagging each inbound JSON-RPC message as `:request` / `:notification` / `:response` / `:unknown` (`conn.assigns.wymcp_message_type`) so responses bypass validation and reach deliver_response. (`Wymcp.Plugs.Classify`)

### Server-initiated requests

- **sampling** — the server asking the client's LLM for a completion mid-tool-execution (`sampling/createMessage` via `Context.sample/3`); blocks until the client replies. (`Wymcp.Context`)
- **elicitation** — the server asking the human user, via the client, for structured input (`elicitation/create` via `Context.elicit`); form mode implemented, URL mode deferred. (`Wymcp.Context`)
- **requestedSchema** — the flat JSON Schema an elicitation sends for the client to render as a form. (`Wymcp.Context.elicit`)
- **accept / decline / cancel** — the elicitation response outcomes, carried in its `"action"` field (see the action overload). (`Wymcp.Context.elicit`)
- **model preferences** — sampling hints and priorities (cost/speed/intelligence priorities, model-name hints). (`Wymcp.Context.sample`, priv/schema.json)
- **deferred reply** — the blocking round-trip for server-initiated requests: push the request over SSE, hold the caller (`await_client_response`), unblock when the client POSTs the response (`deliver_response`). (`Wymcp.Session`, `Wymcp.Methods.DeliverResponse`)
- **pending requests** — in-flight client→server requests tracked on the session (`track_request` / `complete_request`). (`Wymcp.Session.State`)
- **pending server requests** — in-flight server→client requests (sampling/elicitation) awaiting a client reply. (`Wymcp.Session.State`)

### Notifications & utility methods

- **ping** — the liveness method; returns an empty result. (`Wymcp.Methods.Ping`)
- **cancellation** — `notifications/cancelled`, a client aborting a request by requestId + reason; tracked, but no in-flight abort yet. (`Wymcp.Methods.Cancelled`)
- **progress** — `notifications/progress` updates (progress, total, message) via `Context.report_progress`, sent only when the request opted in. (`Wymcp.Context`)
- **progress token** — the `_meta` token opting a request into progress notifications. (`Wymcp.Context`, priv/schema.json)
- **_meta** — the reserved JSON-RPC metadata property, exposed as `Context.meta` (spelled `meta` on the Elixir side). (`Wymcp.Context`)
- **logging** — server→client `notifications/message` log entries filtered against the session's log level; the client sets it via `logging/setLevel`; eight syslog levels debug→emergency. (`Wymcp.Context.log`, `Wymcp.Methods.LoggingSetLevel`)
- **list changed** — the `listChanged` capability plus `notifications/tools/list_changed`, sent when runtime tools are registered or unregistered. (`Wymcp.Session.notify_tools_list_changed`)

### Auth & validation

- **Auth behaviour** — the consumer contract validating a request's Bearer token (`authenticate/1`), adding identity to conn assigns; failures get 401 + `WWW-Authenticate: Bearer`. (`Wymcp.Auth`, `Wymcp.Plugs.Auth`)
- **Noop auth** — the default pass-through Auth implementation. (`Wymcp.Auth.Noop`)
- **origin check** — allowlist rejection of requests by `Origin` header; DNS-rebinding protection. (`Wymcp.Plugs.OriginCheck`)
- **envelope validation** — validating every inbound message against the MCP schema's `JSONRPCMessage` definition (priv/schema.json, JSON Schema 2020-12, compiled at build time). (`Wymcp.Plugs.Validate`, `Wymcp.JsonRpc`)
- **validation layers** — four distinct stages share the word "validate": boot-time action-schema validation (`validate_actions!`), envelope validation (`Plugs.Validate`), tools/call argument validation (`validate_arguments` / `validate_schema`), and in-dispatch checks (required, required_one_of, unknown params). Flagged as overload debt. (`Wymcp.Tool`, `Wymcp.Plugs.Validate`, `Wymcp.Methods.ToolsCall`)

### Adopted but unimplemented spec surface

Terms the roadmap and spec overview use for planned work — present in
priv/schema.json, absent from lib/:

- **resources** — application-driven context (`resources/list`, `resources/read`); planned. (roadmap, spec overview §2.2)
- **resource template** — URI-template-based resources (`resources/templates/list`); planned. (spec overview §2.2)
- **prompts** — user-controlled templates (`prompts/list`, `prompts/get`); planned. (roadmap, spec overview §2.3)
- **tasks** — experimental durable state machines for long-running operations; statuses working / input_required / completed / failed / cancelled (the `status` overload). (roadmap, spec overview §4.7)
- **roots** — client-declared filesystem boundaries (`roots/list`). (spec overview §3.3)
- **completion** — argument autocompletion (`completion/complete`). (spec overview §4.5)
- **pagination / cursor** — opaque cursor-based paging on list methods (`nextCursor`). (roadmap, spec overview §4.6)
- **resource link / embedded resource** — resource-referencing content block types. (roadmap, spec overview §2.1)
- **URL-mode elicitation** — elicitation via an external URL (`elicitation.url`, `URLElicitationRequiredError` -32042); deferred. (spec overview §3.2)

### Cross-cutting flags

Synonym sets and overloads spanning entries — the priority queue for future
define sessions:

- **context ×3** — `%Wymcp.Context{}` struct vs the `"context"` response key vs hint context.
- **hint ×3** — follow-up action suggestion vs `ModelHint` vs `ToolAnnotations.*Hint`.
- **action ×2** — tool operation vs elicitation-response outcome field.
- **dispatch ×3** — action-level vs method-level vs `Plug.Router` internals.
- **server ×3** — MCP server / `Wymcp.Server` behaviour / server-initiated requests.
- **status ×2** — session lifecycle vs task execution state machine.
- **schema ×many** — action schema (authoring map) vs JSON Schema maps vs priv/schema.json (protocol document) vs inputSchema/outputSchema/requestedSchema (wire fields).
- **annotations ×2** — tool behavior hints vs content metadata.
- **name ×many** — tool name, action name, serverInfo.name, property name.
- **run ×3** — `Methods.*.run`, generated `Tool.run/2`, `run_action/3`.
- **negotiated version ≈ protocol version ≈ revision ≈ protocolVersion** — one concept, four spellings across resolver, state, prose, and wire.
- **session assigns ≈ per-session state ≈ per-session assigns** — one concept in prose.
- **push_event ≈ push** — Session vs StreamManager naming of the same send.
- **help vs describe** — a deliberate dyad (operational vs contextual), easy to conflate.
- **camelCase ↔ snake_case** — wire vs Elixir spellings of the same fields (inputSchema/input_schema, serverInfo/server_info, `_meta`/meta, Mcp-Session-Id/session_id).
