# Glossary

Canonical domain terms for this project. Code and docs use these terms;
`_Avoid_` synonyms are banned in new names. Conceptual terms are defined
here; code-backed terms are defined at their code home and autolinked from
here. Other documents point at a term's home instead of redefining it.

**action**
A named operation within a tool, selected by the `"action"` key in a call's
arguments; atom internally, string on the wire. The help tool's `action`
parameter also holds an action name — a reference to this concept, not a
second meaning. The elicitation-response `"action"` field
(accept/decline/cancel) is an unrelated, spec-fixed wire collision.

**action summary**
`Wymcp.Tool.Schema.action_summaries/1`
_Avoid_: one-liner, one-line description

**arguments**
The params object of a `tools/call` request, carrying `action` + `data`.
Optional on the wire: absent or JSON-null arguments read as the empty
object.

**Auth behaviour**
`Wymcp.Auth`

**auth check**
The wire check that calls the configured Auth behaviour and answers 401
plus the `WWW-Authenticate` challenge on failure. Implemented by
`Wymcp.Plugs.Auth`; distinct from the Auth behaviour — the consumer
contract it calls.

**consumer-authored text**
Defined at its prose home: the README section "Consumer-authored text".

**dirty tool list**
Defined at its code home: the `Wymcp.Session` moduledoc, section "Tool list
notifications".
_Avoid_: stale tool list, pending notification

**error dialect**
The error-body convention an HTTP answer speaks. Wymcp has three
structured dialects: the JSON-RPC dialect (the enveloped error object
POST answers), the plain-JSON dialect (the flat `%{error: "…"}` object
the GET/DELETE route errors answer), and the tool dialect (the `isError`
tool-result payload). Each route's errors speak one dialect.
_Avoid_: register, error register, error shape

**event ID**
The monotonic per-event SSE identifier (`evt-N`), carried on the wire as
the SSE `id` field and read back from the `Last-Event-ID` request header.
A reconnect resumes the counter; replay of missed events is not
implemented.

**help**
The framework-owned introspection tool — the server's entire introspection
surface; defined at its code home, `Wymcp.Help` (moduledoc).
_Avoid_: describe, built-in action, narrowing, topic

**help pointer**
The copyable help-call suggestion carried under the `"help"` key of a
tool-dialect error payload, telling the LLM which help call explains the
surface it just misused. The pointer string is a legal call, never a
prose hint; its format lives in one internal builder (`Wymcp.Tool`).
_Avoid_: help link, help hint

**keepalive**
The periodic SSE comment (default 15 s) that keeps a stream's connection
from being idle-disconnected by proxies. Distinct from the session idle
timeout.

**list changed**
The `listChanged` capability declared at initialize and the
`notifications/tools/list_changed` notification it promises. Wymcp declares
and sends it for tools only; the resources and prompts variants are
unimplemented.
_Avoid_: list-changed hint, hint (for this notification)

**origin check**
The wire check rejecting requests whose `Origin` header is not on the
configured allowlist — DNS-rebinding protection. Implemented by
`Wymcp.Plugs.OriginCheck` (doc-hidden, hence defined here).

**priming event**
The initial empty SSE event a new stream sends, giving the client an
event ID for reconnection.

**push**
`Wymcp.Session.push/3`
_Avoid_: push event, push_event

**push ack**
The stream loop's answer to one push — `:ok` for a completed chunk write,
an error tuple otherwise. Delivered to whoever awaits the push: the pusher
directly on a plain push, the session on a server-request round trip's
push leg.
_Avoid_: push reply, push result

**rejection**
An HTTP answer that refuses an inbound message instead of processing it,
carrying a status and a diagnostic message in the route's error dialect. A
wire check sends one, and so do `Wymcp.Plugs.Session` and
`Wymcp.Plugs.Validate`; a tool-level failure is not one — it returns an
`isError` result in the tool dialect.

**reserved name**
`Wymcp.Help.uses_reserved_name?/1`

**server-request round trip**
The blocking round trip a server-initiated request (sampling, elicitation)
makes: the session pushes the request over SSE, holds the calling process,
and unblocks it when the client POSTs the response back
(`await_client_response` → `deliver_response`).
_Avoid_: deferred reply

**session**
`Wymcp.Session`

**session opts**
`Wymcp.Testing.build_session_opts/1`
_Avoid_: session-init map

**singleton header**
A request header that may legally carry at most one value. Wymcp's are
`Mcp-Session-Id`, `MCP-Protocol-Version`, `Last-Event-ID`, `Origin`, and
`Authorization`. A duplicate is answered by wymcp policy, not by the MCP
spec, which says nothing about repeated headers; two policies are in use —
**reject**, failing closed with a 400 naming the header, and **degrade**,
proceeding without the header's value and logging a warning.

**singleton-header check**
The wire check that enforces the cardinality of the singleton headers it
owns, before the request touches any session state: `Mcp-Session-Id` and
`MCP-Protocol-Version` reject on a duplicate, `Last-Event-ID` degrades.
Downstream readers of those headers therefore face a two-way present /
absent decision. Implemented by `Wymcp.Plugs.SingletonHeaders`. `Origin` is
not among the headers it owns — the origin check runs first, so nothing has
validated that header by the time it reads it; `Authorization` belongs to
the consumer's Auth behaviour implementation.
_Avoid_: header check

**stream**
`Wymcp.Transport.Stream`
_Avoid_: StreamManager, stream manager

**stream-answered push**
The push design in which the stream loop answers the pusher itself: the
session hands the message and the caller's reply reference to the loop
and never blocks on a socket write.
_Avoid_: forwarded ack

**wire check**
A plug that may reject a request at the HTTP boundary, before the request
touches any session state. Wymcp has three: the origin check, the auth
check, and the singleton-header check, run in that order.
_Avoid_: wire-level guard, guard (for rejecting plugs), gate (for
rejecting plugs)

**wire-check invariant**
`Wymcp.Router`

## Grandfathered (pending define)

Swept from the existing code and docs on 2026-07-05 (glossary bootstrap).
Each entry records the term's *apparent* meaning and where it lives —
recorded, not blessed. Grandfathered terms are canonical by default (do not
invent synonyms for them) but each awaits a define session. **Overloaded:**
marks a term carrying more than one meaning; the cross-cutting flags at the
end collect the synonym sets that span entries.

### Tools & actions

- **tool** — a module implementing the `Wymcp.Tool` behaviour, exposing named actions to LLM clients; the only MCP primitive wymcp implements. **Overloaded:** also a string tool *name* (`Hint.tool`), a capability flag (`capabilities.tools`), and a sampling tool definition (`CreateMessageRequestParams.tools`). (`Wymcp.Tool`, README)
- **action-dispatched pattern** — the design idiom where one tool name multiplexes many actions. (`Wymcp.Tool` moduledoc)
- **action schema** — the per-action definition map: `:description`, `:properties`, `:required`, `:required_one_of`, `:defaults`, `:notes`, `:related`, `:examples`. (`Wymcp.Tool` `@type action_schema`)
- **data** — the action-specific parameter sub-object inside a call's `arguments`. (`Wymcp.Tool`, `Wymcp.Tool.Schema`)
- **dispatch** — routing a call to its handler. **Overloaded:** action-level (`Wymcp.Tool.dispatch/4` → `run_action`), method-level (`Wymcp.Plugs.Dispatch` → `Methods.*`), and the stock `Plug.Router` `plug(:dispatch)`. (`Wymcp.Tool`, `Wymcp.Plugs.Dispatch`)
- **required** — unconditionally required property names, AND-semantics. **Overloaded:** also the JSON Schema keyword (array) and `PromptArgument.required` (boolean) in the protocol schema. (`Wymcp.Tool`)
- **required_one_of** — list of property groups; at least one group must be fully present (OR-of-AND), enforced at dispatch and surfaced by the help tool. (`Wymcp.Tool`, CHANGELOG 0.5.0)
- **defaults** — default values merged into `data` after validation, before dispatch. (`Wymcp.Tool`)
- **notes / related / examples** — optional documentation fields on an action schema; surfaced by the help tool at tool and action level. (`Wymcp.Tool`, CHANGELOG 0.5.0)
- **definition** — a tool's full MCP wire definition emitted in `tools/list`: name, description, inputSchema, optional title/annotations/outputSchema. (`Wymcp.Tool`)
- **input schema** (`inputSchema` on the wire) — the JSON Schema for a tool's arguments, generated from its actions: an action enum whose description carries the action summaries, plus a bare `data` object. (`Wymcp.Tool.Schema`)
- **output schema** (`outputSchema`) — optional JSON Schema validating a tool's structured result; enables `structuredContent`; version-gated. (`Wymcp.Tool`, `Wymcp.Methods.ToolsCall`)
- **structuredContent** — the structured response object validated against the output schema, sent alongside `content`. (`Wymcp.Methods.ToolsCall`)
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
- **message classification** — tagging each inbound JSON-RPC message as `:request` / `:notification` / `:response` / `:unknown` (`conn.assigns.wymcp_message_type`) so responses bypass validation and reach deliver_response. (`Wymcp.Plugs.Classify`)

### Server-initiated requests

- **sampling** — the server asking the client's LLM for a completion mid-tool-execution (`sampling/createMessage` via `Context.sample/3`); blocks until the client replies. (`Wymcp.Context`)
- **elicitation** — the server asking the human user, via the client, for structured input (`elicitation/create` via `Context.elicit`); form mode implemented, URL mode deferred. (`Wymcp.Context`)
- **requestedSchema** — the flat JSON Schema an elicitation sends for the client to render as a form. (`Wymcp.Context.elicit`)
- **accept / decline / cancel** — the elicitation response outcomes, carried in its `"action"` field (see the action overload). (`Wymcp.Context.elicit`)
- **model preferences** — sampling hints and priorities (cost/speed/intelligence priorities, model-name hints). (`Wymcp.Context.sample`, priv/schema.json)
- **pending requests** — in-flight client→server requests tracked on the session (`track_request` / `complete_request`). (`Wymcp.Session.State`)
- **pending server requests** — in-flight server→client requests (sampling/elicitation) awaiting a client reply. (`Wymcp.Session.State`)

### Notifications & utility methods

- **ping** — the liveness method; returns an empty result. (`Wymcp.Methods.Ping`)
- **cancellation** — `notifications/cancelled`, a client aborting a request by requestId + reason; tracked, but no in-flight abort yet. (`Wymcp.Methods.Cancelled`)
- **progress** — `notifications/progress` updates (progress, total, message) via `Context.report_progress`, sent only when the request opted in. (`Wymcp.Context`)
- **progress token** — the `_meta` token opting a request into progress notifications. (`Wymcp.Context`, priv/schema.json)
- **_meta** — the reserved JSON-RPC metadata property, exposed as `Context.meta` (spelled `meta` on the Elixir side). (`Wymcp.Context`)
- **logging** — server→client `notifications/message` log entries filtered against the session's log level; the client sets it via `logging/setLevel`; eight syslog levels debug→emergency. (`Wymcp.Context.log`, `Wymcp.Methods.LoggingSetLevel`)

### Auth & validation

- **Noop auth** — the default pass-through Auth implementation. (`Wymcp.Auth.Noop`)
- **envelope validation** — validating every inbound message against the MCP schema's `JSONRPCMessage` definition (priv/schema.json, JSON Schema 2020-12, compiled at build time). (`Wymcp.Plugs.Validate`, `Wymcp.JsonRpc`)
- **validation layers** — four distinct stages share the word "validate": action-schema validation at boot and at runtime registration (`validate_actions!`), envelope validation (`Plugs.Validate`), tools/call argument validation (`validate_arguments` / `validate_schema`), and in-dispatch checks (required, required_one_of, unknown params). Flagged as overload debt. (`Wymcp.Tool`, `Wymcp.Plugs.Validate`, `Wymcp.Methods.ToolsCall`)

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
- **dispatch ×3** — action-level vs method-level vs `Plug.Router` internals.
- **server ×3** — MCP server / `Wymcp.Server` behaviour / server-initiated requests.
- **status ×2** — session lifecycle vs task execution state machine.
- **schema ×many** — action schema (authoring map) vs JSON Schema maps vs priv/schema.json (protocol document) vs inputSchema/outputSchema/requestedSchema (wire fields).
- **annotations ×2** — tool behavior hints vs content metadata.
- **name ×many** — tool name, action name, serverInfo.name, property name.
- **description ×4** — tool-level `description()` callback vs action-schema `:description` vs the JSON Schema property `"description"` vs `serverInfo.description`.
- **run ×3** — `Methods.*.run`, generated `Tool.run/2`, `run_action/3`.
- **request_id ×5** — the id a rejection echoes (`Wymcp.Response`) vs the JSON-RPC envelope builders' parameter (`Wymcp.JsonRpc`) vs a telemetry/Logger metadata key vs the `%Wymcp.Context{}` field vs **the server-minted id of a server→client sampling or elicitation request** (`Wymcp.Session`, `Wymcp.Context.generate_request_id/0`). The first and last name ids minted by opposite parties, and they meet at `Wymcp.Methods.DeliverResponse`.
- **response ×6** — the `Wymcp.Response` module vs the `:response` message kind vs the HTTP response vs `Wymcp.JsonRpc`'s response builders vs `deliver_response` vs `Wymcp.Testing`'s assertion helpers. Three of the six meet inside `Wymcp.Response.rejection_id/1`.
- **negotiated version ≈ protocol version ≈ revision ≈ protocolVersion** — one concept, four spellings across resolver, state, prose, and wire.
- **session assigns ≈ per-session state ≈ per-session assigns** — one concept in prose.
- **camelCase ↔ snake_case** — wire vs Elixir spellings of the same fields (inputSchema/input_schema, serverInfo/server_info, `_meta`/meta, Mcp-Session-Id/session_id).
