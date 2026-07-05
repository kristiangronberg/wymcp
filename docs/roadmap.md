# wymcp — Roadmap

> The topic index for wymcp's development process: one row per topic, updated
> by each process phase at its boundary. A row set to **implemented** is the
> topic's completion record; its directory under `docs/plans/` holds the phase
> artifacts. What wymcp is and how to use it: [`README.md`](../README.md).
>
> **Status vocabulary:** `idea → brainstormed → surveyed → specced → planned →
> hardened → implemented` (a topic enters at the first phase whose input it
> lacks and may skip phases; see the development-process README in
> `~/.claude/skills/`).

wymcp is an **MCP server library for Elixir**: a Plug-based implementation of
the MCP JSON-RPC 2.0 protocol (Streamable HTTP) with tools support, optional
Bearer-token auth, and per-session protocol-version negotiation across the
three current MCP revisions. See [`README.md`](../README.md) for the full
feature surface and getting-started guide.

## Pending topics, in order

Kristian owns sequencing. **Implementation starts only on Kristian's
go-ahead.**

| # | Topic | Status | Notes |
|---|-------|--------|-------|
| 1 | media-attachments | idea | Binary/image content in tool results + an ingest path (base64-in-args is token-costly — likely a separate upload route). Pull trigger: cai's work-item media attachments thread (parked there until cai's basic feature set stabilises). Overlaps potential item "additional content types" below. |

## Potential topics — MCP feature gaps (not decided)

What the MCP 2025-11-25 spec defines that wymcp does not implement, from the
feature map in
[`mcp-spec-2025-11-25-overview.md`](mcp-spec-2025-11-25-overview.md) (§6 —
see there for detail). These are candidates, not commitments; a topic enters
the pending table above only when Kristian decides to take it on.

- **Tier 1 — polish what exists:** pagination on `tools/list`; in-flight
  cancellation (abort running tool tasks); stream reconnection replay via
  `Last-Event-Id`; elicitation spec alignment (`mode` field, `elicitation.form`
  sub-capability, advertised modes).
- **Tier 2 — new server features:** resources (`Wymcp.Resource` behaviour +
  `resources/list`/`read`); resource templates; prompts (`Wymcp.Prompt`
  behaviour); completion (`completion/complete`); additional content types in
  tool results (`audio`, `resource_link`, embedded resource).
- **Tier 3 — remaining client features:** elicitation URL mode; roots
  (`roots/list`); sampling multi-turn tool loop.
- **Tier 4 — experimental:** tasks (durable state machines for long-running
  operations, new in 2025-11-25).

## Implemented

Each row is the topic's completion record; the linked directory holds its
artifacts (historical topics carry `plan.md` only — they predate the
per-phase artifact convention).

| Date | Topic | Thread |
|------|-------|--------|
| 2026-05-13 | [required-one-of](plans/2026-05-13-required-one-of/plan.md) | Tool schema — `required_one_of` OR-of-AND groups; `:required`/`:defaults` made optional; boot-time schema validation |
| 2026-05-05 | [icon-schema-compliance](plans/2026-05-05-icon-schema-compliance/plan.md) | Spec compliance — `serverInfo.icons[]` conforms to the MCP `Icon` schema |
| 2026-05-04 | [spec-compliant-stale-session](plans/2026-05-04-spec-compliant-stale-session/plan.md) | Sessions — unknown `Mcp-Session-Id` rejected with 404 + `-32001` per spec |
| 2026-05-03 | [mcp-error-observability](plans/2026-05-03-mcp-error-observability/plan.md) | Errors/observability — `isError: true` tool results, `action_context/2` scope plumbing, auth-failure logging + telemetry |
| 2026-04-27 | [mcp-version-support](plans/2026-04-27-mcp-version-support/plan.md) | Protocol — negotiation across `2025-03-26`/`2025-06-18`/`2025-11-25` with per-feature version gating |
