# MCP 2025-11-25 Spec

## Purpose

Map every feature in the MCP 2025-11-25 specification against what wymcp currently
implements, to guide planning for the next development phase.

- [Reference website for specification](https://modelcontextprotocol.io/specification/2025-11-25)

<div data-toc />

## 1. Base Protocol

### 1.1 JSON-RPC 2.0 Message Layer

| Feature                                   | Spec requirement | wymcp status                                               |
|-------------------------------------------|------------------|------------------------------------------------------------|
| Request / Response / Notification framing | MUST             | ✅ Wymcp.JsonRpc (internal)                                |
| `jsonrpc: "2.0"` on every message         | MUST             | ✅                                                         |
| Standard error codes (-32700 … -32603)    | MUST             | ✅ `error_response/3`                                      |
| `_meta` reserved property on all requests | MUST support     | ✅ Parsed and passed via `Context.meta`                    |
| Message classification (req/notif/resp)   | MUST             | ✅ `Plugs.Classify` tags `conn.assigns.wymcp_message_type` |

### 1.2 Lifecycle

| Feature                                                            | Spec requirement | wymcp status                                                                |
|--------------------------------------------------------------------|------------------|-----------------------------------------------------------------------------|
| `initialize` — version + capability negotiation                    | MUST             | ✅ `Methods.Initialize` with dynamic capabilities                           |
| `notifications/initialized`                                        | MUST             | ✅ `Methods.Initialized`                                                    |
| Version negotiation (echo or counter-propose)                      | MUST             | ✅ Always responds with latest supported version                             |
| `MCP-Protocol-Version` HTTP header on subsequent requests          | MUST (HTTP)      | ✅ `Plugs.Session` validates against negotiated version                     |
| Store negotiated client capabilities for the session               | SHOULD           | ✅ Stored in `Session.State.client_capabilities`                            |
| Capability negotiation for sampling/elicitation                    | SHOULD           | ✅ Server advertises only what client declares                              |
| `serverInfo` fields: `title`, `description`, `icons`, `websiteUrl` | MAY              | ✅ Via `:server_info` router option                                         |
| `instructions` field in init response                              | MAY              | ✅ Via `:instructions` router option                                        |

### 1.3 Transports

| Feature                                      | Spec requirement | wymcp status                                                       |
|----------------------------------------------|------------------|--------------------------------------------------------------------|
| Streamable HTTP (POST + optional SSE)        | Defined          | ✅ POST + GET SSE via `StreamManager`                              |
| stdio                                        | Defined          | N/A (library is HTTP-focused)                                      |
| Session management / `Mcp-Session-Id` header | SHOULD (HTTP)    | ✅ Full session lifecycle with idle timeout + sessionless fallback |
| SSE keepalive                                | SHOULD           | ✅ Configurable keepalive timer                                    |
| Stream reconnection via `Last-Event-Id`      | MAY              | ⚠️ Header read but not used for replay                              |

### 1.4 Authorization

| Feature                                          | Spec requirement | wymcp status                                                       |
|--------------------------------------------------|------------------|--------------------------------------------------------------------|
| OAuth 2.1 / Bearer token flow                    | SHOULD (HTTP)    | ⚠️ `Wymcp.Auth` behaviour with Bearer support; no OAuth discovery |
| `WWW-Authenticate` for incremental scope consent | MAY              | ✅ Returns `WWW-Authenticate: Bearer` on 401                      |

---

## 2. Server Features

### 2.1 Tools (model-controlled)
Reference: https://modelcontextprotocol.io/specification/2025-11-25/server/tools/

| Feature                                                | Spec requirement            | wymcp status                                               |
|--------------------------------------------------------|-----------------------------|------------------------------------------------------------|
| `tools/list`                                           | MUST if capability declared | ✅ `Methods.ToolsList`                                     |
| `tools/call`                                           | MUST if capability declared | ✅ `Methods.ToolsCall`                                     |
| `outputSchema` + `structuredContent`                   | MAY                         | ✅ Tools define `output_schema/0`, validated on return     |
| Runtime tool registration                              | N/A (wymcp extension)       | ✅ `Session.register_tool/2`, `unregister_tool/2`          |
| Pagination (`cursor` / `nextCursor`)                   | SHOULD                      | ❌                                                         |
| `listChanged` capability + notification                | MAY                         | ✅ Advertised in capabilities, sent on register/unregister |
| Tool `title` field                                     | MAY                         | ✅ Optional callback, included in `definition()`           |
| Tool `icons` field (array: `src`, `mimeType`, `sizes`) | MAY                         | ❌                                                         |
| Tool `annotations` (audience, priority, etc.)          | MAY                         | ✅ Optional callback, included in `definition()`           |
| `audio` content type in results                        | MAY                         | ❌                                                         |
| `resource_link` content type in results                | MAY                         | ❌                                                         |
| Embedded resource content type in results              | MAY                         | ❌                                                         |
| `execution.taskSupport` field                          | MAY (experimental)          | ❌                                                         |
| Input validation against `inputSchema`                 | SHOULD                      | ✅ JSV validation in ToolsCall before dispatch             |

### 2.2 Resources (application-driven context)

| Feature                                                 | Spec requirement            | wymcp status       |
|---------------------------------------------------------|-----------------------------|--------------------|
| `resources/list`                                        | MUST if capability declared | ❌ Not implemented |
| `resources/read`                                        | MUST if capability declared | ❌                 |
| `resources/templates/list` (URI templates)              | MUST if capability declared | ❌                 |
| `resources/subscribe` + update notifications            | MAY                         | ❌                 |
| `listChanged` notification                              | MAY                         | ❌                 |
| Resource annotations (audience, priority, lastModified) | MAY                         | ❌                 |
| Pagination                                              | SHOULD                      | ❌                 |

### 2.3 Prompts (user-controlled templates)

| Feature                                  | Spec requirement            | wymcp status       |
|------------------------------------------|-----------------------------|--------------------|
| `prompts/list`                           | MUST if capability declared | ❌ Not implemented |
| `prompts/get` with argument substitution | MUST if capability declared | ❌                 |
| Prompt `icons` field                     | MAY                         | ❌                 |
| `listChanged` notification               | MAY                         | ❌                 |
| Pagination                               | SHOULD                      | ❌                 |

---

## 3. Client Features (server → client requests)

These are requests the **server sends to the client** via the SSE channel. The
session's deferred-reply mechanism (`Session.await_client_response/4`) pushes a
JSON-RPC request via SSE, blocks the caller, and unblocks when the client POSTs
back a response. `Plugs.Classify` tags incoming responses so they bypass
validation and route to `Methods.DeliverResponse`.

### 3.1 Sampling (server asks client to run LLM)

| Feature                               | Spec                             | wymcp status                                             |
|---------------------------------------|----------------------------------|----------------------------------------------------------|
| `sampling/createMessage`              | Client capability                | ✅ `Context.sample/3` — blocks until client responds     |
| Capability negotiation                | Part of init                     | ✅ Only advertised when client declares `sampling`       |
| Model preferences (hints, priorities) | Part of request                  | ✅ Passed through via opts                               |
| Tool use within sampling              | Client declares `sampling.tools` | ❌ Not implemented (client-side concern)                 |
| Multi-turn tool loop                  | Part of sampling                 | ❌ Single-turn only                                      |

### 3.2 Elicitation (server asks client for user input)

| Feature                                | Spec                                 | wymcp status                                              |
|----------------------------------------|--------------------------------------|-----------------------------------------------------------|
| `elicitation/create` — form mode       | Client capability `elicitation.form` | ✅ `Context.elicit/3` — sends JSON Schema, blocks for response |
| Capability negotiation                 | Part of init                         | ⚠️ See note below                                        |
| `mode` field in request                | Defaults to `"form"` if omitted      | ⚠️ See note below                                        |
| Sensitive-info constraint              | MUST NOT use form mode               | ⚠️ Not enforced or documented for tool authors            |
| `elicitation/create` — URL mode        | Client capability `elicitation.url`  | ❌ Deferred                                               |
| `notifications/elicitation/complete`   | Server → Client notification         | ❌ (needed for URL mode — carries `elicitationId`)        |
| `URLElicitationRequiredError` (-32042) | Error response                       | ❌ (structured: `data.elicitations[]` with `mode`, `elicitationId`, `url`, `message`) |

> **Implementation notes (form mode):**
>
> 1. **Capability sub-keys not checked.** The spec defines `elicitation.form`
>    and `elicitation.url` as distinct client sub-capabilities. Our
>    `check_capability/2` only tests `Map.has_key?(client_capabilities,
>    "elicitation")` — it does not verify the client declared `form`
>    specifically. Likewise, `Initialize` advertises `"elicitation" => %{}`
>    without declaring which modes the server supports. A spec-strict client
>    could reasonably interpret the empty map as "no modes supported."
>
> 2. **`mode` field omitted from request.** `Context.elicit/4` builds params
>    as `%{"message" => …, "requestedSchema" => …}` without `"mode" =>
>    "form"`. The spec says omitting `mode` defaults to `"form"` for backwards
>    compatibility, so this works today but is implicit. Adding the field
>    explicitly would be more robust.
>
> 3. **Sensitive-information constraint.** The spec states: *"Servers MUST NOT
>    use form mode for sensitive information. URL mode MUST be used for
>    sensitive interactions like credentials."* This is not enforced in code
>    (nor could it easily be), but should be documented as guidance for tool
>    authors using `Context.elicit/3`.

### 3.3 Roots (server asks client for filesystem boundaries)

| Feature                            | Spec              | Notes                                                |
|------------------------------------|-------------------|------------------------------------------------------|
| `roots/list`                       | Client capability | ❌ Not implemented                                   |
| `notifications/roots/list_changed` | Client → Server   | ❌                                                   |

---

## 4. Utilities (cross-cutting)

### 4.1 Ping

| Feature                | Spec | wymcp status      |
|------------------------|------|-------------------|
| `ping` → `{}` response | MUST | ✅ `Methods.Ping` |

### 4.2 Progress Tracking

| Feature                                                      | Spec           | wymcp status  |
|--------------------------------------------------------------|----------------|---------------|
| `_meta.progressToken` in requests                            | MAY            | ✅ `Context.progress_token/1`       |
| `notifications/progress` with `progress`, `total`, `message` | MAY            | ✅ `Context.report_progress/4`      |
| Progress must monotonically increase                         | MUST (if sent) | ⚠️ Caller responsibility (not enforced) |

### 4.3 Cancellation

| Feature                                               | Spec   | wymcp status                     |
|-------------------------------------------------------|--------|----------------------------------|
| `notifications/cancelled` with `requestId` + `reason` | MAY    | ✅ `Methods.Cancelled`           |
| Receiver SHOULD stop work and return error -32800     | SHOULD | ⚠️ Tracked but no in-flight abort |

### 4.4 Logging

| Feature                                                                 | Spec    | wymcp status |
|-------------------------------------------------------------------------|---------|--------------|
| `logging/setLevel` (client → server)                                    | MAY     | ✅ `Methods.LoggingSetLevel`, stores level in session |
| `notifications/message` with level + logger + data                      | MAY     | ✅ `Context.log/3` with level filtering               |
| Levels: debug, info, notice, warning, error, critical, alert, emergency | Defined | ✅ All 8 syslog levels supported                      |

### 4.5 Completion (autocompletion)

| Feature                                                                | Spec                            | wymcp status |
|------------------------------------------------------------------------|---------------------------------|--------------|
| `completion/complete` for prompt args and resource URI template params | Server capability `completions` | ❌           |
| Reference types: `ref/prompt`, `ref/resource`                          | Defined                         | ❌           |
| Context-aware completions (previous arg values)                        | SHOULD                          | ❌           |

### 4.6 Pagination

| Feature                                                       | Spec    | wymcp status |
|---------------------------------------------------------------|---------|--------------|
| Opaque cursor-based pagination on all list operations         | SHOULD  | ❌           |
| `nextCursor` in responses, `cursor` in requests               | Defined | ❌           |

### 4.7 Tasks (experimental — new in 2025-11-25)

| Feature                                                                        | Spec         | wymcp status |
|--------------------------------------------------------------------------------|--------------|--------------|
| Task-augmented requests (durable state machines)                               | Experimental | ❌           |
| `tasks/get` — poll task status                                                 | Defined      | ❌           |
| `tasks/cancel` — cancel running task                                           | Defined      | ❌           |
| `tasks/list` — list active tasks                                               | Defined      | ❌           |
| `tasks/result` — retrieve deferred result                                      | Defined      | ❌           |
| Task statuses: `working`, `completed`, `failed`, `cancelled`, `input_required` | Defined      | ❌           |
| `execution.taskSupport` on tool definitions                                    | Defined      | ❌           |
| `_meta` with `io.modelcontextprotocol/model-immediate-response`                | Defined      | ❌           |

---

## 5. Summary: What wymcp has today

**Implemented:**
- JSON-RPC 2.0 framing with message classification (request/notification/response)
- Schema validation via JSV against the 2025-11-25 schema.json
- Lifecycle: `initialize` with dynamic capability negotiation, `notifications/initialized`, `ping`
- Version negotiation: always responds with latest supported version (counter-proposal ready)
- Full session management: `Mcp-Session-Id`, GenServer-per-session, idle timeout, Registry lookup
- SSE transport: `StreamManager` with keepalive, bidirectional messaging
- Tools: `tools/list`, `tools/call` with `outputSchema` + `structuredContent`
- Tool metadata: optional `title/0` and `annotations/0` callbacks on `Wymcp.Tool`
- `listChanged` capability advertised; `notifications/tools/list_changed` sent on register/unregister
- Runtime tool registration/unregistration per session
- Server callbacks: `Wymcp.Server` behaviour with `init/2` and `terminate/2`
- Context bridge: session assigns + conn.assigns merged into `%Context{}`
- Auth behaviour with Bearer token support and `WWW-Authenticate` header
- Cancellation: `notifications/cancelled` with request tracking
- Sampling: `Context.sample/3` — server asks client's LLM mid-tool-execution
- Elicitation: `Context.elicit/3` — server asks human for structured form input (see §3.2 notes for spec gaps)
- Deferred reply mechanism: `Session.await_client_response/4` + `deliver_response/3`
- Progress tracking: `Context.progress_token/1` + `Context.report_progress/4`
- Logging: `logging/setLevel` method + `Context.log/3` with level filtering
- Telemetry events for session lifecycle

## 6. Missing:

### Tier 1: Low effort, high value (polish what exists)

1. **Pagination** on `tools/list`
2. **In-flight cancellation** — actually abort running tool tasks on `notifications/cancelled`
3. **Stream reconnection replay** — use `Last-Event-Id` to replay missed events
4. **Elicitation spec alignment** — add `mode` field to requests, check `elicitation.form` sub-capability, advertise supported modes in server capabilities (see §3.2 notes)

### Tier 2: Medium effort, high value (new server features)

5. **Resources** — `Wymcp.Resource` behaviour + `resources/list`, `resources/read`
6. **Resource templates** — `resources/templates/list` with URI template expansion
7. **Prompts** — `Wymcp.Prompt` behaviour + `prompts/list`, `prompts/get`
8. **Completion** — `completion/complete` for prompt and resource template args
9. **Additional content types** — `audio`, `resource_link`, embedded resource in tool results

### Tier 3: Remaining client features

10. **Elicitation URL mode** — `elicitation/create` with URL redirect flow + `elicitationId` + `notifications/elicitation/complete` + `URLElicitationRequiredError` (-32042)
11. **Roots** — server → client `roots/list` request
12. **Sampling tool use** — multi-turn tool loop within sampling

### Tier 4: Experimental / future

13. **Tasks** — durable state machines for long-running operations
