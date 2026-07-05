# 2026-05-05 Icon Schema Compliance Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `serverInfo.icons[]` emitted by `Wymcp.Methods.Initialize` comply with the MCP 2025-11-25 `Icon` schema (`src` + optional `mimeType`, `sizes`, `theme`), so strict MCP clients (e.g. Claude.ai) accept the `initialize` response. Eliminate the unsafe atom-stringify passthrough that produced the bug, drop legacy `:url`/`:media_type` aliases (we are pre-1.0), and validate the response against the canonical JSV schema instead of hand-rolled assertions.

**Architecture:** `Wymcp.Methods.Initialize` owns icon encoding via two private helpers: `maybe_put_icons/2` (presence guard) and `encode_icon/1` (per-icon translation). `encode_icon/1` uses an explicit `@icon_key_map` whitelist — `Map.split` partitions caller input into known and unknown keys, known keys are renamed via `Map.fetch!`, unknown keys are dropped and logged via `Logger.warning`. Tests assert correctness by validating output icons against a strict (`additionalProperties: false`) version of the canonical `Icon` definition from `priv/schema.json`, using the existing `Wymcp.JsonRpc.validate_schema/2` JSV entry point.

**Tech Stack:** Elixir ~> 1.19, Plug ~> 1.15, ExUnit, JSV (already in repo), `ExUnit.CaptureLog` (already imported in `router_test.exs:16`). No new dependencies.

**Documentation standard:** Documentation work in this plan must follow the `elixir-documentation-standards` skill.

## Background reading (do this first, before any coding)

Open these files before starting Task 1. They are your reference for every decision in this plan.

- `priv/schema.json` lines 1303-1348 — canonical `Icon` and `Icons` definitions. `src` is the only required property; the only other supported properties are `mimeType`, `sizes`, `theme`. Note there is **no** `additionalProperties: false` on the spec, so JSON Schema validation alone is permissive — the plan addresses this by injecting `additionalProperties: false` into a test-only copy.
- `lib/wymcp/methods/initialize.ex` — `@moduledoc false`. The bug lives in `maybe_put_icons/2` at lines 102-120: it atom-stringifies every key verbatim and only special-cases `media_type → mediaType`. Result: `:url` becomes `"url"` (spec violation), `:mime_type` becomes `"mime_type"` (spec violation), and any unknown key silently leaks through with the wrong casing.
- `lib/wymcp/json_rpc.ex` lines 60-101 — JSV usage pattern. `validate_schema/2` accepts a raw schema map and returns `:ok | {:error, String.t()}`. Tests will reuse this entry point.
- `lib/wymcp/router.ex` lines 50-54 — public `@moduledoc` for `:server_info`. Currently documents the now-removed `%{url: ..., media_type: ...}` shape.
- `test/wymcp/router_test.exs` lines 182-241 — existing initialize tests covering server_info. `import ExUnit.CaptureLog` is already at line 16 (no new import required). The icon assertion at lines 209-210 currently pins the broken behaviour.
- `mix.exs` line 9 — current `version: "0.4.0"`. Bumps to `"0.4.1"` in Task 5.
- `CHANGELOG.md` — Keep-a-Changelog format. Top entry is `[0.4.0]` dated 2026-05-05. Task 5 inserts a new `[0.4.1]` section above it.
- `CLAUDE.md` — module-layout convention (attributes go before public API; not interleaved between private functions). Dialyzer flags `:unmatched_returns` and `:underspecs` are enabled — the plan binds discarded `Logger.warning/1` returns with `_ =` accordingly.
- `README.md` — grep for `icon`; no current references. (Verified 2026-05-05.)

## Public API change (BREAKING, pre-1.0)

The `:icons` shape inside `:server_info` changes:

| Before                                                | After                                                              |
|-------------------------------------------------------|--------------------------------------------------------------------|
| `%{url: "...", media_type: "..."}`                    | `%{src: "...", mime_type: "..."}`                                  |
| `:url` accepted; emitted as `"url"` (spec violation)  | `:url` no longer accepted (silently dropped + logged)              |
| `:media_type` accepted; emitted as `"mediaType"`      | `:media_type` no longer accepted (silently dropped + logged)       |
| `:sizes`, `:theme` passed through verbatim            | `:sizes`, `:theme` accepted; `:src`, `:mime_type` are the renames  |

Snake-case rationale: `:mime_type` is the natural Elixir snake_case of the spec's `mimeType` (each capital letter → underscore + lowercase). It also keeps the encoder's transformation rule simple and predictable.

## File Structure

| File                                | Change                                                                                                                                                                                                                |
|-------------------------------------|-----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `lib/wymcp/methods/initialize.ex`   | Add `require Logger`. Add `@icon_key_map` to module attributes section (after aliases, before `def run/1`). Rewrite `maybe_put_icons/2` and add `encode_icon/1` + `log_dropped_keys/1` private helpers.                |
| `lib/wymcp/router.ex`               | Update `:server_info` docstring entry (lines 50-54) to document the spec-aligned shape. Drop all mention of `:url`/`:media_type` aliases.                                                                              |
| `test/wymcp/router_test.exs`        | Replace the existing icon assertion with one that validates each icon against a strict (`additionalProperties: false`) Icon JSV schema. Add one new test covering the unknown-key drop + warning log.                 |
| `mix.exs`                           | Bump `version: "0.4.0"` to `"0.4.1"`.                                                                                                                                                                                  |
| `CHANGELOG.md`                      | Insert `[0.4.1]` section above `[0.4.0]` documenting the breaking icon-shape change, the new strict whitelist, and the warning log.                                                                                   |

## Task 1: Red — fail the existing icon test by validating against the canonical Icon schema

**Files:**
- Modify: `test/wymcp/router_test.exs:182-215`

- [ ] **Step 1: Add a JSV-built, strict `Icon` schema as a module attribute**

Add the following module attributes near the top of `Wymcp.RouterTest`, immediately after the existing `import` lines (around line 18, before `defmodule TestTool`):

```elixir
  @schema_json File.read!("priv/schema.json") |> JSON.decode!()
  @defs Map.get(@schema_json, "$defs", %{})

  # Strict copy of the canonical Icon definition: forbids unknown
  # properties so a missed key rename in `encode_icon/1` is caught
  # by JSV instead of silently passing.
  @strict_icon_schema %{
    "$schema" => "https://json-schema.org/draft/2020-12/schema",
    "$ref" => "#/$defs/Icon",
    "$defs" =>
      Map.update!(@defs, "Icon", fn icon ->
        Map.put(icon, "additionalProperties", false)
      end)
  }
```

Notes:
- `@schema_json` and `@defs` mirror the loading pattern at `lib/wymcp/json_rpc.ex:68-69`. Module attributes evaluate at compile time, so the file is read once.
- The `additionalProperties: false` injection is the whole point — the canonical schema is permissive, so without it `"mime_type"` (snake_case leak) would silently validate.

- [ ] **Step 2: Rewrite the existing "includes enriched server_info fields" test**

Replace the test body currently at lines 182-215 with:

```elixir
    test "includes enriched server_info fields and icons conform to the MCP Icon schema" do
      server_info = %{
        title: "My Awesome Server",
        description: "A server that does great things",
        website_url: "https://example.com",
        icons: [
          %{
            src: "https://example.com/icon.svg",
            mime_type: "image/svg+xml",
            sizes: ["any"],
            theme: "dark"
          }
        ]
      }

      body = %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "initialize",
        "params" => %{
          "protocolVersion" => "2025-11-25",
          "capabilities" => %{},
          "clientInfo" => %{"name" => "test", "version" => "1.0"}
        }
      }

      conn = call_router(body, server_info: server_info)
      resp = JSON.decode!(conn.resp_body)

      server_info_resp = resp["result"]["serverInfo"]
      assert server_info_resp["title"] == "My Awesome Server"
      assert server_info_resp["description"] == "A server that does great things"
      assert server_info_resp["websiteUrl"] == "https://example.com"

      # Each emitted icon must validate against the strict canonical
      # Icon schema. This single assertion subsumes hand-rolled checks
      # for `src`, `mimeType`, `sizes`, `theme`, type correctness, and
      # absence of unknown fields like `mime_type`.
      for icon <- server_info_resp["icons"] do
        assert :ok = Wymcp.JsonRpc.validate_schema(@strict_icon_schema, icon),
               "icon #{inspect(icon)} did not validate against the canonical Icon schema"
      end

      # name and version still present from app config
      assert server_info_resp["name"]
      assert server_info_resp["version"]
    end
```

Notes:
- The test input uses the **new** API (`:src`, `:mime_type`). Before the fix lands, `encode_icon/1` doesn't exist and `maybe_put_icons/2` will atom-stringify `:mime_type` to `"mime_type"`, which fails strict-schema validation because `mime_type` is not a declared property and `additionalProperties: false` rejects it.
- The previous test included a hand-rolled `[%{"url" => ..., "mediaType" => ...}]` assertion. That is the exact behaviour the plan eliminates, so the assertion is gone — the schema validator now owns correctness checking.

- [ ] **Step 3: Run the test and confirm it fails**

Run: `mix test test/wymcp/router_test.exs:182`

Expected: FAIL. The error message will be a `:error` returned from `Wymcp.JsonRpc.validate_schema/2` indicating an additional property `"mime_type"` was rejected. This proves the bug class — snake-case keys leaking through `Atom.to_string/1` — is now caught by the test.

## Task 2: Green — strict whitelist + logged drop in `maybe_put_icons/2`

**Files:**
- Modify: `lib/wymcp/methods/initialize.ex`

- [ ] **Step 1: Add `require Logger` and the `@icon_key_map` attribute**

Update the module header. Replace lines 1-7 of `lib/wymcp/methods/initialize.ex`:

```elixir
defmodule Wymcp.Methods.Initialize do
  @moduledoc false

  import Plug.Conn
  import Wymcp.Response
  alias Wymcp.{JsonRpc, ProtocolVersion, Session}
```

with:

```elixir
defmodule Wymcp.Methods.Initialize do
  @moduledoc false

  import Plug.Conn
  import Wymcp.Response
  require Logger
  alias Wymcp.{JsonRpc, ProtocolVersion, Session}

  # Whitelist of accepted Icon input keys (snake_case atoms) and
  # their MCP wire names. Per CLAUDE.md module-layout convention,
  # this attribute lives between aliases and the public API.
  @icon_key_map %{
    src: "src",
    mime_type: "mimeType",
    sizes: "sizes",
    theme: "theme"
  }
```

- [ ] **Step 2: Replace `maybe_put_icons/2` with the strict-whitelist version**

Replace the current `maybe_put_icons/2` block (lines 102-120 of the original file, now shifted by the `require Logger` + attribute insert from Step 1) with:

```elixir
  @spec maybe_put_icons(map(), [%{atom() => term()}] | nil) :: map()
  defp maybe_put_icons(map, nil), do: map
  defp maybe_put_icons(map, []), do: map

  defp maybe_put_icons(map, icons) when is_list(icons) do
    Map.put(map, "icons", Enum.map(icons, &encode_icon/1))
  end

  @spec encode_icon(%{atom() => term()}) :: %{String.t() => term()}
  defp encode_icon(icon) do
    {known, unknown} = Map.split(icon, Map.keys(@icon_key_map))
    _ = log_dropped_keys(unknown)
    Map.new(known, fn {k, v} -> {Map.fetch!(@icon_key_map, k), v} end)
  end

  @spec log_dropped_keys(map()) :: :ok
  defp log_dropped_keys(unknown) when map_size(unknown) == 0, do: :ok

  defp log_dropped_keys(unknown) do
    Logger.warning(
      "Wymcp.Methods.Initialize: dropping unknown icon keys " <>
        "#{inspect(Map.keys(unknown))}. Accepted keys: " <>
        "#{inspect(Map.keys(@icon_key_map))}."
    )
  end
```

Notes:
- `Map.split/2` partitions in one pass; `Map.keys(@icon_key_map)` is evaluated at compile time inside the body but is cheap regardless.
- `Map.fetch!/2` cannot raise here because we just filtered to keys that are present in `@icon_key_map`. Use of `!` is the explicit signal that this is an invariant, not a runtime check.
- `_ = log_dropped_keys(...)` binds the discarded `:ok` return so dialyzer's `:unmatched_returns` does not warn (per CLAUDE.md).
- The `log_dropped_keys/1` helper splits on `map_size == 0` so the hot path (no unknown keys) does no string formatting.
- All four helpers carry `@spec` per `elixir-documentation-standards`. The module is `@moduledoc false` so no moduledoc obligations apply.

- [ ] **Step 3: Run the Task 1 test and confirm it now passes**

Run: `mix test test/wymcp/router_test.exs:182`

Expected: PASS. The test input uses the new whitelisted keys, all four translate correctly, and the strict Icon schema accepts the output.

- [ ] **Step 4: Run the full router test suite to catch regressions**

Run: `mix test test/wymcp/router_test.exs`

Expected: all tests pass. Pay particular attention to `"includes only provided server_info fields"` (around line 217) which exercises the no-icons path — the `nil`/`[]` clauses must keep working.

## Task 3: Add coverage for unknown-key drop + warning log

**Files:**
- Modify: `test/wymcp/router_test.exs` — add a new test directly after the `"includes only provided server_info fields"` test (after line 241 in the original numbering; line numbers will have shifted from Task 1).

- [ ] **Step 1: Write the test**

Add this test inside the same `describe "POST /"` block as the other server_info tests:

```elixir
    test "drops unknown icon keys and logs a warning naming them" do
      server_info = %{
        icons: [
          %{
            src: "https://example.com/icon.png",
            mime_type: "image/png",
            # Unknown keys — should be dropped and logged.
            url: "https://legacy.example.com/icon.png",
            media_type: "image/png",
            colour: "blue"
          }
        ]
      }

      body = %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "initialize",
        "params" => %{
          "protocolVersion" => "2025-11-25",
          "capabilities" => %{},
          "clientInfo" => %{"name" => "test", "version" => "1.0"}
        }
      }

      {conn, log} =
        with_log(fn ->
          call_router(body, server_info: server_info)
        end)

      resp = JSON.decode!(conn.resp_body)
      [icon] = resp["result"]["serverInfo"]["icons"]

      # Output validates against the canonical Icon schema (strict
      # variant prepared in Task 1).
      assert :ok = Wymcp.JsonRpc.validate_schema(@strict_icon_schema, icon)

      # Unknown keys are absent from the wire output.
      refute Map.has_key?(icon, "url")
      refute Map.has_key?(icon, "media_type")
      refute Map.has_key?(icon, "mediaType")
      refute Map.has_key?(icon, "colour")

      # Warning log names every unknown key so an upgrading caller
      # can find the source of the drop in their logs.
      assert log =~ "dropping unknown icon keys"
      assert log =~ ":url"
      assert log =~ ":media_type"
      assert log =~ ":colour"
    end
```

Notes:
- `with_log/1` is from `ExUnit.CaptureLog`, already imported at `test/wymcp/router_test.exs:16`. It returns `{result, log}` so the conn produced inside the captured block is reused for the response assertions.
- The `:url` and `:media_type` cases are the legacy aliases this plan removes — explicitly testing that they are dropped (not silently translated) prevents accidental re-introduction of back-compat code.
- The `:colour` case covers an arbitrary unknown key (e.g. a future spec field a caller pre-populates). Same drop + log path.

- [ ] **Step 2: Run the test and confirm it passes**

Run: `mix test test/wymcp/router_test.exs`

Expected: the new test passes green. The dropped icon contains only `"src"` and `"mimeType"`, and the captured log names `:url`, `:media_type`, and `:colour`.

## Task 4: Update the public `Wymcp.Router` docstring

**Files:**
- Modify: `lib/wymcp/router.ex:50-54`

- [ ] **Step 1: Replace the `:server_info` entry in the `@moduledoc` Options list**

Find these lines (currently lines 50-54):

```elixir
  - `:server_info` — a map of optional server identity fields displayed by MCP
    clients. Supported keys: `:title` (human-readable name), `:description`,
    `:website_url`, and `:icons` (list of `%{url: ..., media_type: ...}` maps).
    These are merged with the `name` and `version` from application config
    (optional)
```

Replace with:

```elixir
  - `:server_info` — a map of optional server identity fields displayed by MCP
    clients. Supported keys: `:title` (human-readable name), `:description`,
    `:website_url`, and `:icons`. Each icon is a map with `:src` (required
    URL or `data:` URI) and the optional keys `:mime_type` (e.g. `"image/png"`),
    `:sizes` (list of `"WxH"` strings or `"any"`), and `:theme` (`"light"` or
    `"dark"`). Any other key in an icon map is dropped and a warning is
    logged. These fields are merged with `name` and `version` from
    application config (optional).
```

Why: per `elixir-documentation-standards` Layer 2, the `@moduledoc` is the public contract. Naming the spec-aligned keys removes ambiguity, and explicitly stating the unknown-key drop behaviour saves callers from chasing missing fields when they typo a key.

- [ ] **Step 2: Verify the docs still compile**

Run: `mix docs`

Expected: clean build for `Wymcp.Router`. Pre-existing warnings unrelated to this change can be ignored.

## Task 5: Bump version and update CHANGELOG

**Files:**
- Modify: `mix.exs:9`
- Modify: `CHANGELOG.md` (insert new section above the `[0.4.0]` block at line 8)

- [ ] **Step 1: Bump the project version**

Replace line 9 of `mix.exs`:

```elixir
      version: "0.4.0",
```

with:

```elixir
      version: "0.4.1",
```

- [ ] **Step 2: Add the `[0.4.1]` CHANGELOG section**

Insert this block in `CHANGELOG.md` between line 7 (the closing line of the preamble — `and this project adheres to [Semantic Versioning]...`) and line 8 (`## [0.4.0]`):

```markdown
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
```

Why these subsections: Keep-a-Changelog convention groups by change type. The `Changed (BREAKING)` heading mirrors the format used for `[0.4.0]` (line 12 of the existing changelog).

- [ ] **Step 3: Verify the changelog parses cleanly**

Run: `head -30 CHANGELOG.md` and visually confirm the new `[0.4.1]` block sits above `[0.4.0]` with a blank line between them. (No tool enforces this; a quick eyeball is sufficient.)

## Task 6: Precommit — format, warnings-as-errors, full suite, dialyzer

**Files:** none (verification only)

- [ ] **Step 1: Format**

Run: `mix format`

Expected: exits 0 with no output. If it rewrites files, re-read `lib/wymcp/methods/initialize.ex` and `test/wymcp/router_test.exs` and confirm diffs are cosmetic only.

- [ ] **Step 2: Compile with warnings as errors**

Run: `mix compile --warnings-as-errors`

Expected: clean compile. Likely failure modes if anything is wrong:
- `unused alias Logger` — happens if `require Logger` was removed in a refactor; restore it.
- `function log_dropped_keys/1 is unused` — happens if `encode_icon/1` doesn't call it; verify the `_ = log_dropped_keys(unknown)` line.
- `module attribute @icon_key_map is unused` — happens if `encode_icon/1` was wired to a different keymap; verify the `Map.split` and `Map.fetch!` calls reference `@icon_key_map`.

- [ ] **Step 3: Run the full test suite**

Run: `mix test`

Expected: all tests pass, including the rewritten `"includes enriched server_info fields..."` test (Task 1) and the new `"drops unknown icon keys..."` test (Task 3).

- [ ] **Step 4: Run dialyzer**

Run: `mix dialyzer`

Expected: clean. Per CLAUDE.md, `:underspecs` and `:unmatched_returns` are enabled. Specs in this plan are typed `[%{atom() => term()}] | nil` and `%{atom() => term()} -> %{String.t() => term()}` precisely to satisfy `:underspecs`. The `_ =` binding on `log_dropped_keys/1` satisfies `:unmatched_returns`. If a warning appears, the most likely cause is a spec that does not list every literal return — narrow it before reaching for `.dialyzer_ignore.exs`.

## Self-Review Notes

The plan covers the agreed-upon deliverables:

1. **Schema-compliant `Icon` output** — Task 2 (`@icon_key_map` whitelist).
2. **No back-compat aliases** — Task 2 omits `:url`/`:media_type` from the keymap; Task 3 explicitly verifies they are dropped and logged.
3. **Validation against the canonical schema** — Task 1 builds a strict (`additionalProperties: false`) variant of the spec's `Icon` definition and uses `Wymcp.JsonRpc.validate_schema/2` to assert correctness, replacing the previous hand-rolled assertions.
4. **Logged drops for unknown keys** — Task 2's `log_dropped_keys/1` helper, exercised by Task 3's `with_log/1`-wrapped test.
5. **Public docstring reflects the new contract** — Task 4.
6. **Version + CHANGELOG bump to 0.4.1** — Task 5, with `Changed (BREAKING)`, `Fixed`, and `Added` subsections per the existing changelog format.
7. **Module-layout compliance** — Task 2 places `@icon_key_map` between `alias` and the first `def`, matching the CLAUDE.md ordering.
8. **Dialyzer cleanliness** — typed specs, `_ =` binding for the discarded log return, no ignore-file edits.

No placeholders. Every code block is complete. Every command has an expected outcome. The only documentation surface touched is the `Wymcp.Router` `@moduledoc` (Task 4) and the CHANGELOG (Task 5); `Wymcp.Methods.Initialize` is `@moduledoc false` so no diagram or moduledoc obligations from `elixir-documentation-standards` apply to the implementation file.
