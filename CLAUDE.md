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
```

`mix precommit` is the all-or-nothing gate run before committing. It chains
(in the `:test` env): `compile --warnings-as-errors`, `deps.unlock --unused`,
`format`, `credo --strict`, `deps.audit`, and `test --warnings-as-errors`.
Run it and get a green exit before committing. (CI should swap `format` →
`format --check-formatted` so unformatted code fails instead of being
silently rewritten.)

Static-analysis tooling is configured in `.credo.exs` (Credo + ex_slop,
with domain-appropriate tunings noted inline).

## Architecture

Request flow through the Plug pipeline:

```
POST /
  → Wymcp.Router (Plug.Router, single POST route)
    → Wymcp.Plugs.Pipeline (Plug.Builder)
      ├─ Plugs.OriginCheck (Origin allowlist — DNS rebinding protection)
      ├─ parse_body (Plug.Parsers for JSON)
      ├─ Plugs.Classify (tags the JSON-RPC message kind: request / notification / response)
      ├─ Plugs.Auth (Bearer token via Wymcp.Auth behaviour)
      ├─ Plugs.Session (Mcp-Session-Id lookup + MCP-Protocol-Version check)
      ├─ Plugs.Validate (MCP schema validation via JSV, compiled at build time from priv/schema.json)
      └─ Plugs.Dispatch (routes by "method" string)
          → Methods.Initialize | Methods.ToolsList | Methods.ToolsCall | Methods.Ping | ...
            → Wymcp.Response.send_json (JSON-RPC envelope, halts conn)
```

**Key design decisions:**
- MCP JSON Schema (`priv/schema.json`, JSON Schema 2020-12) is compiled into a `JSV.Root` at build time via module attributes — zero runtime schema parsing.
- `Response.send_json` halts the connection, preventing downstream plugs from executing after a response is sent.
- Duplicate tool names are validated at `Router.init/1` (compile/startup time), not per-request.

## Type checking

The type gate is `compile --warnings-as-errors` in `mix precommit`.
