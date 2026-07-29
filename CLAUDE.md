# CLAUDE.md

This file provides guidance when working with code in this repository.

## Commands

```sh
mix precommit                               # full gate before commit (see below)
mix test                                    # run full suite
mix test test/wymcp/router_test.exs         # run one file
mix test test/wymcp/router_test.exs:42      # run one test by line
mix test --only describe:"tools/call"       # run by describe tag
mix compile --warnings-as-errors            # check for warnings
mix format                                  # format code (imports Plug conventions)
mix credo --strict                          # lint (Credo + ex_slop checks)
mix deps.audit                              # scan mix.lock for known CVEs
mix test.watch                              # auto-run on file change (dev)
mix dialyzer                                # static type analysis
```

`mix precommit` is the all-or-nothing gate run before committing. It chains
(in the `:test` env): `compile --warnings-as-errors`, `deps.unlock --unused`,
`format`, `credo --strict`, `deps.audit`, `test --warnings-as-errors`,
`dialyzer`. Run it and get a green exit before committing. (CI should swap `format` → `format
--check-formatted` so unformatted code fails instead of being silently
rewritten.)

Static-analysis tooling is configured in `.credo.exs` (Credo + ex_slop, with
two domain-appropriate tunings noted inline) and `.dialyzer_ignore.exs`. The
rationale and rollout are documented in `docs/coding_tool_setup.md`.

## Architecture

Request flow through the Plug pipeline:

```
POST /
  → Wymcp.Router (Plug.Router, single POST route)
    → Wymcp.Plugs.Pipeline (Plug.Builder)
      ├─ parse_body (Plug.Parsers for JSON)
      ├─ Plugs.Auth (Bearer token via Wymcp.Auth behaviour)
      ├─ Plugs.Validate (MCP schema validation via JSV, compiled at build time from priv/schema.json)
      └─ Plugs.Dispatch (routes by "method" string)
          → Methods.Initialize | Methods.ToolsList | Methods.ToolsCall | Methods.Ping | ...
            → Wymcp.Response.send_json (JSON-RPC envelope, halts conn)
```

**Key design decisions:**
- MCP JSON Schema (`priv/schema.json`, JSON Schema 2020-12) is compiled into a `JSV.Root` at build time via module attributes — zero runtime schema parsing.
- `Response.send_json` halts the connection, preventing downstream plugs from executing after a response is sent.
- Duplicate tool names are validated at `Router.init/1` (compile/startup time), not per-request.

## Code Conventions

### Module Layout

Every module follows the same top-to-bottom structure. The order makes
the module's shape — what it is, what it depends on, what it exposes —
readable from the first screen without scrolling.

1. `@moduledoc`
2. `use` / `import` / `alias` / `require`
3. `@type` and `@typep` definitions
4. `defstruct` (if the module defines a struct)
5. Module attributes — constants and defaults (`@api_version`, `@default_timeout`)
6. Public API
7. Private functions

**Why this order:** types and attributes describe what the module is
made of; public functions describe what it does; private functions are
implementation detail. Reading top-to-bottom, you learn the module's
identity before its behaviour, and its behaviour before its mechanics.

**Notes:**

- `@type` belongs near the top, not interleaved with functions. Types
  are part of the module's header — what it deals in — not part of its
  implementation.
- There is no separate "functions that set constants" section. Constants
  are module attributes; they are the value, not a function around a
  value.
- Skip any section that doesn't apply. A module with no struct just goes
  from attributes straight to public functions.

### Naming

Prefer full-length names (`request`, `config`, `definition`) over
abbreviations (`req`, `cfg`, `defn`). Short names are reserved for
local pattern variables where the type is obvious from context.

## Dialyzer

The project runs with `:unmatched_returns`, `:error_handling`, and
`:underspecs` enabled. When dialyzer flags a warning, prefer these fixes
in order:

1. **Narrow the spec** if it's broader than the function actually returns
   (e.g., drop an unreachable `{:error, term()}` branch, replace `atom()`
   with the concrete union).
2. **Bind discarded results** with `_ =` when the return is intentionally
   ignored (fire-and-forget notifications, telemetry calls, `query!`-style
   calls whose crash-on-error is the point).
3. **Add to `.dialyzer_ignore.exs`** only when the warning originates
   from a library macro expansion or from a helper whose spec is
   intentionally broad (generic accessors, enum-list returns like
   `valid_actions/0`).

The ignore file is grouped by category with a rationale on each block —
read it before adding entries, and keep `list_unused_filters: true`
enabled so stale entries surface.
