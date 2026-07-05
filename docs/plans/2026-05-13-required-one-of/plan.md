# 2026-05-13 `required_one_of` Action Schema Field — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

Documentation work in this plan must follow the elixir-documentation-standards skill.

**Goal:** Add an optional `required_one_of` field to action schemas in `Wymcp.Tool` so consumers can declare OR-of-AND required-field groups (e.g. "either `url` or all of `project_key + repo_slug + pr_id`"). Make `:required` and `:defaults` both optional with sensible defaults (`[]` and `%{}`). Validate the schema shape at server boot so misconfiguration fails loudly at startup, not at the first request.

**Architecture:** Strictly additive change to the existing `Wymcp.Tool` action schema contract. `required_one_of: [[String.t()]]` is a list of groups; at least one group must be fully present in `data`. Validated alongside `required` at dispatch time, surfaced in `help` and `describe` output, and rendered into JSON Schema as `anyOf: [{required: [...]}, ...]` on the `data` variant. A new init-time validator (called from `Router.init/1` alongside `validate_unique_tool_names!/1`) checks the shape of every action schema in every registered tool and crashes the boot if any tool is malformed. Existing consumers continue to work without modification because every new field is optional.

**Tech Stack:** Elixir, ExUnit, JSON Schema (draft-07-style `anyOf`).

---

## Diagram impact

```
[ ] Does this add or remove a domain context?          → No
[ ] Does this add a schema to an existing context?     → No (no Ecto schemas in wymcp)
[ ] Does this add or change a status/lifecycle field?  → No
[ ] Does this add dependencies on new modules?         → No
[ ] Does this change how a coordinating function flows?→ No (additive validation branch + boot-time check)
```

**Diagram impact: none.**

---

## File Structure

| File                              | Role                                                                                                                                   | Change                                                                                         |
|-----------------------------------|----------------------------------------------------------------------------------------------------------------------------------------|------------------------------------------------------------------------------------------------|
| `lib/wymcp/tool.ex`               | Behaviour + dispatcher; owns `check_required`, `action_summary`, `slim_action_schema`, `full_action_listing`, type spec, `@moduledoc`. | Modify                                                                                         |
| `lib/wymcp/tool/schema.ex`        | Builds `inputSchema` from action map (full and slim).                                                                                  | Modify (only `build_variant/2` for full mode — slim mode does not emit per-action constraints) |
| `lib/wymcp/router.ex`             | `Plug.Router` entry point; `init/1` already validates duplicate tool names.                                                            | Modify (wire `Wymcp.Tool.validate_actions!/1` for every registered tool)                       |
| `test/wymcp/tool_test.exs`        | Behaviour-level tests. Already has a `WidgetTool` fixture.                                                                             | Modify (add fixture actions, add tests for dispatch, help, describe)                           |
| `test/wymcp/tool/schema_test.exs` | Schema builder tests.                                                                                                                  | Modify (add tests for `anyOf` rendering)                                                       |
| `test/wymcp/router_test.exs`      | Router init/dispatch tests.                                                                                                            | Modify (add init-time shape-validation tests)                                                  |
| `CHANGELOG.md`                    | Release notes.                                                                                                                         | Modify (new `## [0.5.0]` entry with two `### Added` blocks)                                    |
| `mix.exs`                         | Version bump.                                                                                                                          | Modify (`0.4.1` → `0.5.0` — minor bump because additive feature, pre-1.0)                      |

No new files. No `git mv`.

---

## Self-contained reference: target shape

A consumer schema after this change can look like any of these:

```elixir
# 1. Today's shape — still valid, no changes required:
%{
  description: "Create a thing",
  properties: %{"name" => %{"type" => "string"}},
  required: ["name"],
  defaults: %{}
}

# 2. Bare action — `:required` and `:defaults` both omitted:
%{
  description: "List things",
  properties: %{"limit" => %{"type" => "integer"}}
}

# 3. OR-of-AND only:
%{
  description: "Get pull request details",
  properties: %{
    "url" => %{"type" => "string"},
    "project_key" => %{"type" => "string"},
    "repo_slug" => %{"type" => "string"},
    "pr_id" => %{"type" => "integer"}
  },
  required_one_of: [["url"], ["project_key", "repo_slug", "pr_id"]]
}

# 4. Combined — unconditional `path` AND OR-of-AND for identification:
%{
  description: "Get the diff for one file in a PR",
  properties: %{
    "url" => %{"type" => "string"},
    "project_key" => %{"type" => "string"},
    "repo_slug" => %{"type" => "string"},
    "pr_id" => %{"type" => "integer"},
    "path" => %{"type" => "string"}
  },
  required: ["path"],
  required_one_of: [["url"], ["project_key", "repo_slug", "pr_id"]]
}
```

Validation semantics:
- `required` — every listed field must be present (AND).
- `required_one_of` — at least one inner group must be fully present (OR-of-AND).
- Both checks run; both must pass. `required` runs first; its failure short-circuits the OR-of-AND check.
- Missing `required` defaults to `[]`. Missing `required_one_of` defaults to `[]` (no constraint).
- Missing `defaults` defaults to `%{}`.

Init-time validation rejects:
- `:required_one_of` that isn't a list of non-empty lists of binaries.
- Field names in `:required` or `:required_one_of` that aren't declared in `:properties`.
- Duplicate field names within a `required` list or within a `required_one_of` group.
- Duplicate groups within `:required_one_of`.
- A group that is a strict superset of another group in the same `:required_one_of` (dead code: the smaller group always satisfies first).
- `:notes` that isn't a binary.
- `:related` that isn't a list of binaries.
- `:examples` that isn't a list of maps.

---

## Task 1: Extend the `action_schema` type and document the new fields

**Files:**
- Modify: `lib/wymcp/tool.ex:128-133` (type spec) and `lib/wymcp/tool.ex:40-47` (`@moduledoc` action schema format section)

- [ ] **Step 1.1: Replace the `action_schema` type with optional fields**

Find the existing block at `lib/wymcp/tool.ex:128-133`:

```elixir
@type action_schema :: %{
        description: String.t(),
        properties: map(),
        required: [String.t()],
        defaults: map()
      }
```

Replace with:

```elixir
@type action_schema :: %{
        :description => String.t(),
        :properties => map(),
        optional(:required) => [String.t()],
        optional(:required_one_of) => [[String.t()]],
        optional(:defaults) => map(),
        optional(:notes) => String.t(),
        optional(:related) => [String.t()],
        optional(:examples) => [map()]
      }
```

`:notes`, `:related`, and `:examples` are added as optional because `describe` already reads them via `Map.take`. This is documentation-of-truth for what `Map.take` consumes, not new behaviour. Their shapes are validated at server boot (Task 3) so a typo like `notes: 123` fails fast rather than rendering oddly.

- [ ] **Step 1.2: Update the `## Action schema format` section in `@moduledoc`**

Find the existing block at `lib/wymcp/tool.ex:40-47`:

```elixir
  ## Action schema format

  Each action in the `actions/0` map must have:

  - `:description` — human-readable description (appears in oneOf schema)
  - `:properties` — JSON Schema properties for the action's `data` parameter
  - `:required` — list of required property names (strings)
  - `:defaults` — map of default values merged into `data` before dispatch
```

Replace with:

```elixir
  ## Action schema format

  Each action in the `actions/0` map must have:

  - `:description` — human-readable description (appears in oneOf schema)
  - `:properties` — JSON Schema properties for the action's `data` parameter

  Optional fields:

  - `:required` — list of unconditionally required property names (defaults to `[]`).
    Every listed field must be present in `data` (AND-semantics).
  - `:required_one_of` — list of groups, where each group is a list of property
    names. At least one group must be fully present (OR-of-AND semantics).
    Combines with `:required` — both checks run, both must pass. Surfaces in
    `help` output and is rendered into the `inputSchema` as `anyOf` on the
    action variant's `data`.
  - `:defaults` — map of default values merged into `data` before dispatch
    (defaults to `%{}`).
  - `:notes` — long-form notes returned by `describe` and `help` with topic.
  - `:related` — list of related action name strings returned by `describe`.
  - `:examples` — list of example payload maps returned by `describe`.

  Defaults are applied after validation: values supplied via `:defaults`
  do not count toward satisfying `:required` or `:required_one_of`. Both
  checks run against the caller's `data` as received.

  Action schemas are validated at server boot via `Wymcp.Router.init/1`. A
  malformed schema (e.g. a `:required_one_of` group referencing a field not
  declared in `:properties`) raises `ArgumentError` immediately, surfacing
  the misconfiguration before any request is served.

  ### Example: OR-of-AND required group

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

  ### Slim mode trade-off for `:required_one_of`

  In slim schema mode (`schema_mode/0` returns `:slim`), the `inputSchema`
  emitted by `tools/list` does not encode per-action constraints — it only
  lists action names and one-line descriptions. `:required_one_of` is
  therefore visible to clients only via the `help`/`describe` round-trip.
  Full schema mode (default) renders the constraint as `anyOf` on the
  variant's `data`.
```

- [ ] **Step 1.3: Compile to verify no warnings**

Run: `cd /Users/kgronber/Projects/wymcp && mix compile --warnings-as-errors`
Expected: compiles cleanly.

---

## Task 2: Make `:required` and `:defaults` optional in dispatcher reads

This task is the pure-defaulting warm-up — no `:required_one_of` work yet. Every existing site that read `schema.required` or `schema.defaults` directly must switch to `Map.get(schema, key, default)` to honour Task 1's optionality.

**Files:**
- Modify: `lib/wymcp/tool.ex:319-326` (`check_required/3`)
- Modify: `lib/wymcp/tool.ex:283-306` (`dispatch/4` — `apply_defaults` call site and the `:missing_required` error tuple)
- Modify: `lib/wymcp/tool.ex:394-402` (`action_summary/2`)
- Modify: `lib/wymcp/tool.ex:425-433` (`slim_action_schema/1`)
- Modify: `test/wymcp/tool_test.exs` (add `bare` fixture action that omits both fields)

- [ ] **Step 2.1: Add a failing test for `:required` and `:defaults` omission**

Open `test/wymcp/tool_test.exs`. Inside the existing `WidgetTool` `actions/0` map (around line 32-62), add a new action that omits both:

```elixir
        bare: %{
          description: "Action with no required and no defaults",
          properties: %{"x" => %{"type" => "string"}}
        }
```

Add the matching `run_action` clause inside `WidgetTool` (around line 76-77):

```elixir
    @impl Wymcp.Tool
    def run_action(:bare, data, _ctx), do: {:ok, %{got: data}}
```

Add a new test in the `describe "run/2 — error handling"` block (around line 316-337):

```elixir
    test "schema without :required and :defaults dispatches with empty defaults" do
      result = WidgetTool.run(build_ctx(), %{"action" => "bare", "data" => %{}})
      content = decode_json_content(result)
      assert content["got"] == %{}
    end
```

- [ ] **Step 2.2: Run the test and confirm it fails**

Run: `cd /Users/kgronber/Projects/wymcp && mix test test/wymcp/tool_test.exs`
Expected: the new `bare` test FAILS — `KeyError` on `:required` (current code does `schema.required` which crashes when the key is absent).

- [ ] **Step 2.3: Update `check_required/3` to read `:required` defensively**

Find at `lib/wymcp/tool.ex:319-326`:

```elixir
  @spec check_required(map(), action_schema(), String.t()) :: :ok | {:error, tuple()}
  defp check_required(data, schema, action_str) do
    missing = Enum.reject(schema.required, &Map.has_key?(data, &1))

    if missing == [],
      do: :ok,
      else: {:error, {:missing_required, missing, action_str, schema}}
  end
```

Replace with:

```elixir
  @spec check_required(map(), action_schema(), String.t()) :: :ok | {:error, tuple()}
  defp check_required(data, schema, action_str) do
    required = Map.get(schema, :required, [])
    missing = Enum.reject(required, &Map.has_key?(data, &1))

    if missing == [],
      do: :ok,
      else: {:error, {:missing_required, missing, action_str, schema}}
  end
```

- [ ] **Step 2.4: Update `dispatch/4` to read `:defaults` defensively (call site only)**

Find at `lib/wymcp/tool.ex:283-287`:

```elixir
    with {:ok, action} <- parse_action(action_str, actions),
         schema = Map.fetch!(actions, action),
         :ok <- check_required(data, schema, action_str),
         merged = apply_defaults(data, schema.defaults) do
      handle_result(module, action, ctx, module.run_action(action, merged, ctx))
```

Replace `merged = apply_defaults(data, schema.defaults)` with `merged = apply_defaults(data, Map.get(schema, :defaults, %{}))`. The full block becomes:

```elixir
    with {:ok, action} <- parse_action(action_str, actions),
         schema = Map.fetch!(actions, action),
         :ok <- check_required(data, schema, action_str),
         merged = apply_defaults(data, Map.get(schema, :defaults, %{})) do
      handle_result(module, action, ctx, module.run_action(action, merged, ctx))
```

(Task 4 chains in `check_required_one_of/3` here. For now, only the `:defaults` read changes.)

- [ ] **Step 2.5: Update the `:missing_required` error tuple to read both fields defensively**

Find at `lib/wymcp/tool.ex:292-304`:

```elixir
      {:error, {:missing_required, missing, action_str, schema}} ->
        {:ok,
         Context.json(%{
           error: "missing_required_fields",
           message: "Required fields missing: #{Enum.join(missing, ", ")}",
           missing: missing,
           action: action_str,
           input_schema: %{
             properties: schema.properties,
             required: schema.required,
             defaults: schema.defaults
           }
         })}
```

Replace with (Task 4 will pull `input_schema` out into a shared `schema_summary/1` helper that also surfaces `:required_one_of`; for now it's still inline so the diff in Task 2 stays small):

```elixir
      {:error, {:missing_required, missing, action_str, schema}} ->
        {:ok,
         Context.json(%{
           error: "missing_required_fields",
           message: "Required fields missing: #{Enum.join(missing, ", ")}",
           missing: missing,
           action: action_str,
           input_schema: %{
             properties: schema.properties,
             required: Map.get(schema, :required, []),
             defaults: Map.get(schema, :defaults, %{})
           }
         })}
```

- [ ] **Step 2.6: Update `slim_action_schema/1`**

Find at `lib/wymcp/tool.ex:425-433`:

```elixir
  @spec slim_action_schema(action_schema()) :: map()
  defp slim_action_schema(schema) do
    properties =
      Map.new(schema.properties, fn {name, prop} ->
        {name, Map.take(prop, ["type", "description"])}
      end)

    %{description: schema.description, required: schema.required, properties: properties}
  end
```

Replace with (Task 5 adds `:required_one_of` surfacing here; for now it's a pure read-defensiveness change):

```elixir
  @spec slim_action_schema(action_schema()) :: map()
  defp slim_action_schema(schema) do
    properties =
      Map.new(schema.properties, fn {name, prop} ->
        {name, Map.take(prop, ["type", "description"])}
      end)

    %{
      description: schema.description,
      required: Map.get(schema, :required, []),
      properties: properties
    }
  end
```

- [ ] **Step 2.7: Update `action_summary/2` to read `:required` defensively**

Find at `lib/wymcp/tool.ex:394-402`:

```elixir
  @spec action_summary(module(), map()) :: map()
  defp action_summary(module, actions) do
    summary =
      Map.new(actions, fn {action, schema} ->
        {Atom.to_string(action), %{description: schema.description, required: schema.required}}
      end)

    %{tool: module.name(), actions: summary}
  end
```

Replace with (Task 5 extends this further to surface `:required_one_of`; for now it's a pure read-defensiveness change so the new `bare` fixture doesn't crash the `help` no-topic path through `action_summary`):

```elixir
  @spec action_summary(module(), map()) :: map()
  defp action_summary(module, actions) do
    summary =
      Map.new(actions, fn {action, schema} ->
        {Atom.to_string(action),
         %{description: schema.description, required: Map.get(schema, :required, [])}}
      end)

    %{tool: module.name(), actions: summary}
  end
```

Without this step, the existing tests `help with no data returns summary of all actions` and `describe with no topic differs from help with no topic` would crash with `KeyError` on the `bare` fixture's missing `:required` key.

- [ ] **Step 2.8: Run the test suite and confirm all pass**

Run: `cd /Users/kgronber/Projects/wymcp && mix test test/wymcp/tool_test.exs`
Expected: all tests PASS, including the new `bare` test.

---

## Task 3: Init-time shape validation

Add `Wymcp.Tool.validate_actions!/1` and call it from `Wymcp.Router.init/1` for every registered tool. A misconfigured action schema crashes the boot with a descriptive error rather than failing on the first request.

**Files:**
- Modify: `lib/wymcp/tool.ex` (add public `validate_actions!/1` plus private helpers)
- Modify: `lib/wymcp/router.ex:88-94` (`init/1`) and add `validate_action_schemas!/1`
- Modify: `test/wymcp/router_test.exs` (init-time validation tests)

- [ ] **Step 3.1: Add failing tests for init-time shape validation**

Open `test/wymcp/router_test.exs`. Add the fixture tool modules at the top level of the test file (alongside the existing `TestTool` and `DuplicateTool` fixtures — not nested inside any `describe`). Then add a new `describe` block that asserts `Wymcp.Router.init/1` raises `ArgumentError` for every fixture. The fixtures cover both the shape validations from Task 3 (`:required`, `:required_one_of`) and the documentation-field validations introduced by B2 (`:notes`, `:related`, `:examples`).

Place the following fixture modules near the other top-level fixtures in `test/wymcp/router_test.exs` (above any `describe` block):

```elixir
  defmodule BadShapeRequiredTool do
    @behaviour Wymcp.Tool

    def name, do: "bad_required"
    def description, do: "Required is not a list of binaries"

    def actions do
      %{
        op: %{
          description: "Bad",
          properties: %{"x" => %{"type" => "string"}},
          required: [:x]
        }
      }
    end

    def run_action(_, _, _), do: {:ok, %{}}
    def hints(_, _), do: []
    def handle_error(_), do: ""
    def schema_mode, do: :full
    def action_context(_, _), do: nil
    def title, do: nil
    def annotations, do: nil
    def output_schema, do: nil
  end

  defmodule UnknownFieldRequiredTool do
    @behaviour Wymcp.Tool

    def name, do: "unknown_required"
    def description, do: "Required references a field not in properties"

    def actions do
      %{
        op: %{
          description: "Bad",
          properties: %{"x" => %{"type" => "string"}},
          required: ["y"]
        }
      }
    end

    def run_action(_, _, _), do: {:ok, %{}}
    def hints(_, _), do: []
    def handle_error(_), do: ""
    def schema_mode, do: :full
    def action_context(_, _), do: nil
    def title, do: nil
    def annotations, do: nil
    def output_schema, do: nil
  end

  defmodule BadShapeRequiredOneOfTool do
    @behaviour Wymcp.Tool

    def name, do: "bad_one_of"
    def description, do: "required_one_of group is a string"

    def actions do
      %{
        op: %{
          description: "Bad",
          properties: %{"x" => %{"type" => "string"}},
          required_one_of: [["x"], "y"]
        }
      }
    end

    def run_action(_, _, _), do: {:ok, %{}}
    def hints(_, _), do: []
    def handle_error(_), do: ""
    def schema_mode, do: :full
    def action_context(_, _), do: nil
    def title, do: nil
    def annotations, do: nil
    def output_schema, do: nil
  end

  defmodule UnknownFieldRequiredOneOfTool do
    @behaviour Wymcp.Tool

    def name, do: "unknown_one_of"
    def description, do: "required_one_of references field not in properties"

    def actions do
      %{
        op: %{
          description: "Bad",
          properties: %{"x" => %{"type" => "string"}},
          required_one_of: [["x"], ["y"]]
        }
      }
    end

    def run_action(_, _, _), do: {:ok, %{}}
    def hints(_, _), do: []
    def handle_error(_), do: ""
    def schema_mode, do: :full
    def action_context(_, _), do: nil
    def title, do: nil
    def annotations, do: nil
    def output_schema, do: nil
  end

  defmodule EmptyGroupTool do
    @behaviour Wymcp.Tool

    def name, do: "empty_group"
    def description, do: "required_one_of has an empty group"

    def actions do
      %{
        op: %{
          description: "Bad",
          properties: %{"x" => %{"type" => "string"}},
          required_one_of: [["x"], []]
        }
      }
    end

    def run_action(_, _, _), do: {:ok, %{}}
    def hints(_, _), do: []
    def handle_error(_), do: ""
    def schema_mode, do: :full
    def action_context(_, _), do: nil
    def title, do: nil
    def annotations, do: nil
    def output_schema, do: nil
  end

  defmodule SupersetGroupTool do
    @behaviour Wymcp.Tool

    def name, do: "superset"
    def description, do: "required_one_of has a strict-superset group (dead code)"

    def actions do
      %{
        op: %{
          description: "Bad",
          properties: %{
            "a" => %{"type" => "string"},
            "b" => %{"type" => "string"}
          },
          required_one_of: [["a"], ["a", "b"]]
        }
      }
    end

    def run_action(_, _, _), do: {:ok, %{}}
    def hints(_, _), do: []
    def handle_error(_), do: ""
    def schema_mode, do: :full
    def action_context(_, _), do: nil
    def title, do: nil
    def annotations, do: nil
    def output_schema, do: nil
  end

  defmodule BadNotesTool do
    @behaviour Wymcp.Tool

    def name, do: "bad_notes"
    def description, do: ":notes is not a binary"

    def actions do
      %{
        op: %{
          description: "Bad",
          properties: %{"x" => %{"type" => "string"}},
          notes: 123
        }
      }
    end

    def run_action(_, _, _), do: {:ok, %{}}
    def hints(_, _), do: []
    def handle_error(_), do: ""
    def schema_mode, do: :full
    def action_context(_, _), do: nil
    def title, do: nil
    def annotations, do: nil
    def output_schema, do: nil
  end

  defmodule BadRelatedTool do
    @behaviour Wymcp.Tool

    def name, do: "bad_related"
    def description, do: ":related is not a list of binaries"

    def actions do
      %{
        op: %{
          description: "Bad",
          properties: %{"x" => %{"type" => "string"}},
          related: [:identify]
        }
      }
    end

    def run_action(_, _, _), do: {:ok, %{}}
    def hints(_, _), do: []
    def handle_error(_), do: ""
    def schema_mode, do: :full
    def action_context(_, _), do: nil
    def title, do: nil
    def annotations, do: nil
    def output_schema, do: nil
  end

  defmodule BadExamplesTool do
    @behaviour Wymcp.Tool

    def name, do: "bad_examples"
    def description, do: ":examples is not a list of maps"

    def actions do
      %{
        op: %{
          description: "Bad",
          properties: %{"x" => %{"type" => "string"}},
          examples: ["payload-1"]
        }
      }
    end

    def run_action(_, _, _), do: {:ok, %{}}
    def hints(_, _), do: []
    def handle_error(_), do: ""
    def schema_mode, do: :full
    def action_context(_, _), do: nil
    def title, do: nil
    def annotations, do: nil
    def output_schema, do: nil
  end
```

Then add the matching `describe` block (this one goes alongside the other `describe` blocks in the file):

```elixir
  describe "init/1 — action schema validation" do
    test "raises when :required is not a list of binaries" do
      assert_raise ArgumentError, ~r/required/, fn ->
        Wymcp.Router.init(tools: [BadShapeRequiredTool])
      end
    end

    test "raises when :required references a field absent from :properties" do
      assert_raise ArgumentError, ~r/(unknown|not declared)/i, fn ->
        Wymcp.Router.init(tools: [UnknownFieldRequiredTool])
      end
    end

    test "raises when a :required_one_of group is not a list of binaries" do
      assert_raise ArgumentError, ~r/required_one_of/, fn ->
        Wymcp.Router.init(tools: [BadShapeRequiredOneOfTool])
      end
    end

    test "raises when :required_one_of references a field absent from :properties" do
      assert_raise ArgumentError, ~r/(unknown|not declared)/i, fn ->
        Wymcp.Router.init(tools: [UnknownFieldRequiredOneOfTool])
      end
    end

    test "raises when a :required_one_of group is empty" do
      assert_raise ArgumentError, ~r/empty/i, fn ->
        Wymcp.Router.init(tools: [EmptyGroupTool])
      end
    end

    test "raises when a :required_one_of group is a strict superset of another" do
      assert_raise ArgumentError, ~r/(superset|dead)/i, fn ->
        Wymcp.Router.init(tools: [SupersetGroupTool])
      end
    end

    test "raises when :notes is not a binary" do
      assert_raise ArgumentError, ~r/:notes/, fn ->
        Wymcp.Router.init(tools: [BadNotesTool])
      end
    end

    test "raises when :related is not a list of binaries" do
      assert_raise ArgumentError, ~r/:related/, fn ->
        Wymcp.Router.init(tools: [BadRelatedTool])
      end
    end

    test "raises when :examples is not a list of maps" do
      assert_raise ArgumentError, ~r/:examples/, fn ->
        Wymcp.Router.init(tools: [BadExamplesTool])
      end
    end
  end
```

- [ ] **Step 3.2: Run the new tests and confirm they fail**

Run: `cd /Users/kgronber/Projects/wymcp && mix test test/wymcp/router_test.exs`
Expected: all nine new tests FAIL — there is no validator yet, so `Router.init/1` happily accepts the malformed tools.

- [ ] **Step 3.3: Add `validate_actions!/1` to `Wymcp.Tool`**

Place this block in `lib/wymcp/tool.ex` immediately before the `# -- Dispatch (called by generated run/2) --` comment (currently around line 227):

```elixir
  # -- Boot-time validation --

  @doc """
  Validate every action schema in `module`. Raises `ArgumentError` with a
  descriptive message on the first malformed action.

  Called by `Wymcp.Router.init/1` so that misconfigured tools fail at boot
  rather than at the first request.
  """
  @spec validate_actions!(module()) :: :ok
  def validate_actions!(module) when is_atom(module) do
    actions = module.actions()

    Enum.each(actions, fn {action, schema} ->
      validate_action_schema!(module, action, schema)
    end)

    :ok
  end

  @spec validate_action_schema!(module(), atom(), map()) :: :ok
  defp validate_action_schema!(module, action, schema) do
    properties = Map.get(schema, :properties, %{})

    validate_required!(module, action, Map.get(schema, :required, []), properties)

    validate_required_one_of!(
      module,
      action,
      Map.get(schema, :required_one_of, []),
      properties
    )

    validate_doc_fields!(module, action, schema)

    :ok
  end

  @spec validate_required!(module(), atom(), term(), map()) :: :ok
  defp validate_required!(module, action, required, properties) do
    unless is_list(required) and Enum.all?(required, &is_binary/1) do
      raise ArgumentError,
            "Tool #{inspect(module)} action #{inspect(action)}: " <>
              ":required must be a list of binaries, got #{inspect(required)}"
    end

    if length(required) != length(Enum.uniq(required)) do
      raise ArgumentError,
            "Tool #{inspect(module)} action #{inspect(action)}: " <>
              ":required has duplicate entries: #{inspect(required)}"
    end

    case Enum.reject(required, &Map.has_key?(properties, &1)) do
      [] ->
        :ok

      unknown ->
        raise ArgumentError,
              "Tool #{inspect(module)} action #{inspect(action)}: " <>
                ":required references field(s) not declared in :properties: " <>
                inspect(unknown)
    end
  end

  @spec validate_required_one_of!(module(), atom(), term(), map()) :: :ok
  defp validate_required_one_of!(_module, _action, [], _properties), do: :ok

  defp validate_required_one_of!(module, action, groups, properties) do
    unless is_list(groups) and
             Enum.all?(groups, fn g ->
               is_list(g) and Enum.all?(g, &is_binary/1)
             end) do
      raise ArgumentError,
            "Tool #{inspect(module)} action #{inspect(action)}: " <>
              ":required_one_of must be a list of lists of binaries, got " <>
              inspect(groups)
    end

    Enum.each(groups, fn group ->
      cond do
        group == [] ->
          raise ArgumentError,
                "Tool #{inspect(module)} action #{inspect(action)}: " <>
                  ":required_one_of contains an empty group"

        length(group) != length(Enum.uniq(group)) ->
          raise ArgumentError,
                "Tool #{inspect(module)} action #{inspect(action)}: " <>
                  ":required_one_of group has duplicate entries: #{inspect(group)}"

        true ->
          unknown = Enum.reject(group, &Map.has_key?(properties, &1))

          if unknown != [] do
            raise ArgumentError,
                  "Tool #{inspect(module)} action #{inspect(action)}: " <>
                    ":required_one_of group references field(s) not declared " <>
                    "in :properties: #{inspect(unknown)}"
          end
      end
    end)

    if length(groups) != length(Enum.uniq(groups)) do
      raise ArgumentError,
            "Tool #{inspect(module)} action #{inspect(action)}: " <>
              ":required_one_of has duplicate groups: #{inspect(groups)}"
    end

    check_no_strict_superset!(module, action, groups)
    :ok
  end

  @spec check_no_strict_superset!(module(), atom(), [[String.t()]]) :: :ok
  defp check_no_strict_superset!(module, action, groups) do
    indexed = groups |> Enum.map(&MapSet.new/1) |> Enum.with_index()

    Enum.each(indexed, fn {a, i} ->
      Enum.each(indexed, fn {b, j} ->
        if i != j and MapSet.subset?(a, b) and a != b do
          raise ArgumentError,
                "Tool #{inspect(module)} action #{inspect(action)}: " <>
                  ":required_one_of group #{inspect(Enum.at(groups, j))} is a " <>
                  "strict superset of #{inspect(Enum.at(groups, i))} (dead code: " <>
                  "the smaller group always satisfies first)"
        end
      end)
    end)

    :ok
  end

  @spec validate_doc_fields!(module(), atom(), map()) :: :ok
  defp validate_doc_fields!(module, action, schema) do
    validate_notes!(module, action, schema)
    validate_related!(module, action, schema)
    validate_examples!(module, action, schema)
    :ok
  end

  @spec validate_notes!(module(), atom(), map()) :: :ok
  defp validate_notes!(module, action, schema) do
    case Map.fetch(schema, :notes) do
      :error ->
        :ok

      {:ok, value} when is_binary(value) ->
        :ok

      {:ok, value} ->
        raise ArgumentError,
              "Tool #{inspect(module)} action #{inspect(action)}: " <>
                ":notes must be a binary, got #{inspect(value)}"
    end
  end

  @spec validate_related!(module(), atom(), map()) :: :ok
  defp validate_related!(module, action, schema) do
    case Map.fetch(schema, :related) do
      :error ->
        :ok

      {:ok, value} ->
        if is_list(value) and Enum.all?(value, &is_binary/1) do
          :ok
        else
          raise ArgumentError,
                "Tool #{inspect(module)} action #{inspect(action)}: " <>
                  ":related must be a list of binaries, got #{inspect(value)}"
        end
    end
  end

  @spec validate_examples!(module(), atom(), map()) :: :ok
  defp validate_examples!(module, action, schema) do
    case Map.fetch(schema, :examples) do
      :error ->
        :ok

      {:ok, value} ->
        if is_list(value) and Enum.all?(value, &is_map/1) do
          :ok
        else
          raise ArgumentError,
                "Tool #{inspect(module)} action #{inspect(action)}: " <>
                  ":examples must be a list of maps, got #{inspect(value)}"
        end
    end
  end
```

`check_no_strict_superset!/3` uses two nested `Enum.each/2` rather than a `for` comprehension because the comprehension would return a list value that is then discarded — under `:unmatched_returns` (enabled in this project) Dialyzer flags that. `Enum.each/2` returns `:ok` and is the idiomatic side-effecting iteration.

- [ ] **Step 3.4: Wire `validate_actions!/1` into `Router.init/1`**

Find at `lib/wymcp/router.ex:88-94`:

```elixir
  @spec init(keyword()) :: keyword()
  def init(opts) do
    tools = Keyword.get(opts, :tools, [])
    validate_unique_tool_names!(tools)
    validate_server_module(Keyword.get(opts, :server))
    super(opts)
  end
```

Replace with:

```elixir
  @spec init(keyword()) :: keyword()
  def init(opts) do
    tools = Keyword.get(opts, :tools, [])
    validate_unique_tool_names!(tools)
    validate_action_schemas!(tools)
    validate_server_module(Keyword.get(opts, :server))
    super(opts)
  end

  @spec validate_action_schemas!([module()]) :: :ok
  defp validate_action_schemas!(tools) do
    Enum.each(tools, &Wymcp.Tool.validate_actions!/1)
    :ok
  end
```

- [ ] **Step 3.5: Run the new tests and confirm they pass**

Run: `cd /Users/kgronber/Projects/wymcp && mix test test/wymcp/router_test.exs`
Expected: all nine new validation tests PASS.

- [ ] **Step 3.6: Run the full suite and confirm nothing else regressed**

Run: `cd /Users/kgronber/Projects/wymcp && mix test`
Expected: full suite PASS. (`WidgetTool` and friends in `tool_test.exs` don't go through `Router.init/1`, so they aren't affected.)

---

## Task 4: Add runtime `check_required_one_of` validation

Chain a second check into `dispatch/4`. Use a distinct error code (`missing_required_group`) so callers and telemetry can distinguish the two failure modes. Extract a private `schema_summary/1` so both error branches return a consistent `input_schema` payload that includes `:required_one_of` whenever the action declares it.

**Files:**
- Modify: `lib/wymcp/tool.ex:279-306` (`dispatch/4` action branch — chain check, share helper, add new error branch)
- Modify: `lib/wymcp/tool.ex` near `check_required/3` (add `check_required_one_of/3`, `format_groups/1`, `schema_summary/1`)
- Modify: `test/wymcp/tool_test.exs` — add fixture actions and tests including all four interaction corners

- [ ] **Step 4.1: Add fixture actions and failing tests**

In `test/wymcp/tool_test.exs`, add three new actions to `WidgetTool.actions/0`. The third action (`identify_with_default`) is used by the A1 test that pins the semantics of `:defaults` vs `:required_one_of` — see the last test in this step.

```elixir
        identify: %{
          description: "Identify a widget by id or by (name + color)",
          properties: %{
            "id" => %{"type" => "integer"},
            "name" => %{"type" => "string"},
            "color" => %{"type" => "string"}
          },
          required_one_of: [["id"], ["name", "color"]]
        },
        locate: %{
          description: "Locate at a path, identified by id or by (name + color)",
          properties: %{
            "path" => %{"type" => "string"},
            "id" => %{"type" => "integer"},
            "name" => %{"type" => "string"},
            "color" => %{"type" => "string"}
          },
          required: ["path"],
          required_one_of: [["id"], ["name", "color"]]
        },
        identify_with_default: %{
          description:
            "Identify by id or (name + color); :defaults seeds color but must NOT satisfy required_one_of",
          properties: %{
            "id" => %{"type" => "integer"},
            "name" => %{"type" => "string"},
            "color" => %{"type" => "string"}
          },
          required_one_of: [["id"], ["name", "color"]],
          defaults: %{"color" => "blue"}
        }
```

Add the matching `run_action` clauses:

```elixir
    @impl Wymcp.Tool
    def run_action(:identify, data, _ctx), do: {:ok, %{found: data}}

    @impl Wymcp.Tool
    def run_action(:locate, data, _ctx), do: {:ok, %{located: data}}

    @impl Wymcp.Tool
    def run_action(:identify_with_default, data, _ctx), do: {:ok, %{found: data}}
```

Add tests in `describe "run/2 — error handling"`:

```elixir
    test "required_one_of: passes when first group is fully present" do
      result = WidgetTool.run(build_ctx(), %{"action" => "identify", "data" => %{"id" => 1}})
      assert {:ok, _} = result
    end

    test "required_one_of: passes when second group is fully present" do
      result =
        WidgetTool.run(build_ctx(), %{
          "action" => "identify",
          "data" => %{"name" => "alpha", "color" => "red"}
        })

      assert {:ok, _} = result
    end

    test "required_one_of: fails with missing_required_group when no group is fully present" do
      result =
        WidgetTool.run(build_ctx(), %{
          "action" => "identify",
          "data" => %{"name" => "alpha"}
        })

      content = decode_json_content(result)
      assert content["error"] == "missing_required_group"
      assert content["required_one_of"] == [["id"], ["name", "color"]]
      assert content["message"] =~ "(id) OR (name + color)"
    end

    test "required_one_of: error response input_schema surfaces required_one_of" do
      result =
        WidgetTool.run(build_ctx(), %{
          "action" => "identify",
          "data" => %{"name" => "alpha"}
        })

      content = decode_json_content(result)
      assert content["input_schema"]["required_one_of"] == [["id"], ["name", "color"]]
    end

    test "required + required_one_of: passes when both satisfied" do
      result =
        WidgetTool.run(build_ctx(), %{
          "action" => "locate",
          "data" => %{"path" => "/x", "id" => 1}
        })

      assert {:ok, _} = result
    end

    test "required + required_one_of: required failure surfaces required_one_of in input_schema" do
      result =
        WidgetTool.run(build_ctx(), %{
          "action" => "locate",
          "data" => %{"id" => 1}
        })

      content = decode_json_content(result)
      assert content["error"] == "missing_required_fields"
      assert content["missing"] == ["path"]
      assert content["input_schema"]["required_one_of"] == [["id"], ["name", "color"]]
    end

    test "required + required_one_of: required_one_of failure when required is satisfied" do
      result =
        WidgetTool.run(build_ctx(), %{
          "action" => "locate",
          "data" => %{"path" => "/x"}
        })

      content = decode_json_content(result)
      assert content["error"] == "missing_required_group"
      assert content["required_one_of"] == [["id"], ["name", "color"]]
    end

    test "required + required_one_of: required loses race when both unsatisfied" do
      result =
        WidgetTool.run(build_ctx(), %{
          "action" => "locate",
          "data" => %{}
        })

      content = decode_json_content(result)
      assert content["error"] == "missing_required_fields"
      assert content["missing"] == ["path"]
    end

    @tag doc: """
    Pins design decision A1: `:defaults` is applied AFTER validation, so values
    provided via `:defaults` cannot satisfy `:required_one_of`. The
    `identify_with_default` fixture has `defaults: %{"color" => "blue"}` and
    `required_one_of: [["id"], ["name", "color"]]`. Calling with only
    `{"name": "alpha"}` would satisfy the second group IF defaults applied
    pre-validation — they don't, so this must fail with `missing_required_group`.
    """
    test "defaults do not satisfy required_one_of" do
      result =
        WidgetTool.run(build_ctx(), %{
          "action" => "identify_with_default",
          "data" => %{"name" => "alpha"}
        })

      content = decode_json_content(result)
      assert content["error"] == "missing_required_group"
      assert content["required_one_of"] == [["id"], ["name", "color"]]
    end
```

- [ ] **Step 4.2: Run the new tests and confirm they fail**

Run: `cd /Users/kgronber/Projects/wymcp && mix test test/wymcp/tool_test.exs`
Expected: the new tests FAIL — `:required_one_of` is currently ignored, so calls with no group satisfied succeed (incorrectly), and the error-shape assertions fail because `missing_required_group` does not exist yet.

- [ ] **Step 4.3: Add `check_required_one_of/3`, `format_groups/1`, and `schema_summary/1`**

In `lib/wymcp/tool.ex`, immediately after `check_required/3` (currently lines 319-326), add three private helpers:

```elixir
  @spec check_required_one_of(map(), action_schema(), String.t()) ::
          :ok | {:error, tuple()}
  defp check_required_one_of(data, schema, action_str) do
    case Map.get(schema, :required_one_of, []) do
      [] ->
        :ok

      groups ->
        if Enum.any?(groups, fn group ->
             Enum.all?(group, &Map.has_key?(data, &1))
           end) do
          :ok
        else
          {:error, {:missing_required_groups, groups, action_str, schema}}
        end
    end
  end

  @spec format_groups([[String.t()]]) :: String.t()
  defp format_groups(groups) do
    groups
    |> Enum.map(fn group -> "(" <> Enum.join(group, " + ") <> ")" end)
    |> Enum.join(" OR ")
  end

  @spec schema_summary(action_schema()) :: map()
  defp schema_summary(schema) do
    base = %{
      properties: schema.properties,
      required: Map.get(schema, :required, []),
      defaults: Map.get(schema, :defaults, %{})
    }

    case Map.get(schema, :required_one_of, []) do
      [] -> base
      groups -> Map.put(base, :required_one_of, groups)
    end
  end
```

So `[["url"], ["project_key", "repo_slug", "pr_id"]]` formats as `(url) OR (project_key + repo_slug + pr_id)`.

- [ ] **Step 4.4: Chain `check_required_one_of/3` into `dispatch/4` and update both error branches to use `schema_summary/1`**

Find at `lib/wymcp/tool.ex:279-306` (after Task 2 the `with` and `:missing_required` branch read defensively but `input_schema` is still inline):

```elixir
  def dispatch(module, ctx, action_str, data) do
    actions = module.actions()
    data = data || %{}

    with {:ok, action} <- parse_action(action_str, actions),
         schema = Map.fetch!(actions, action),
         :ok <- check_required(data, schema, action_str),
         merged = apply_defaults(data, Map.get(schema, :defaults, %{})) do
      handle_result(module, action, ctx, module.run_action(action, merged, ctx))
    else
      {:error, :unknown_action} ->
        {:error, "Unknown action: #{action_str}"}

      {:error, {:missing_required, missing, action_str, schema}} ->
        {:ok,
         Context.json(%{
           error: "missing_required_fields",
           message: "Required fields missing: #{Enum.join(missing, ", ")}",
           missing: missing,
           action: action_str,
           input_schema: %{
             properties: schema.properties,
             required: Map.get(schema, :required, []),
             defaults: Map.get(schema, :defaults, %{})
           }
         })}
    end
  end
```

Replace with:

```elixir
  def dispatch(module, ctx, action_str, data) do
    actions = module.actions()
    data = data || %{}

    with {:ok, action} <- parse_action(action_str, actions),
         schema = Map.fetch!(actions, action),
         :ok <- check_required(data, schema, action_str),
         :ok <- check_required_one_of(data, schema, action_str),
         merged = apply_defaults(data, Map.get(schema, :defaults, %{})) do
      handle_result(module, action, ctx, module.run_action(action, merged, ctx))
    else
      {:error, :unknown_action} ->
        {:error, "Unknown action: #{action_str}"}

      {:error, {:missing_required, missing, action_str, schema}} ->
        {:ok,
         Context.json(%{
           error: "missing_required_fields",
           message: "Required fields missing: #{Enum.join(missing, ", ")}",
           missing: missing,
           action: action_str,
           input_schema: schema_summary(schema)
         })}

      {:error, {:missing_required_groups, groups, action_str, schema}} ->
        {:ok,
         Context.json(%{
           error: "missing_required_group",
           message:
             "At least one of these field groups must be fully present: " <>
               format_groups(groups),
           required_one_of: groups,
           action: action_str,
           input_schema: schema_summary(schema)
         })}
    end
  end
```

Both error branches now route through `schema_summary/1`, so an action with both `:required` and `:required_one_of` always exposes both constraints in the error payload regardless of which one tripped.

- [ ] **Step 4.5: Run the new tests and confirm they pass**

Run: `cd /Users/kgronber/Projects/wymcp && mix test test/wymcp/tool_test.exs`
Expected: all tests PASS, including the eight new `required_one_of` and combined-interaction tests added in 4.1.

---

## Task 5: Surface `:required_one_of` in `help` output

Help has two shapes: no-topic (an `action_summary/2` map) and with-topic (a `slim_action_schema/1` map). Both must surface `:required_one_of` when the action declares it, and omit the key otherwise.

**Files:**
- Modify: `lib/wymcp/tool.ex:394-402` (`action_summary/2`)
- Modify: `lib/wymcp/tool.ex:425-433` (`slim_action_schema/1` — already updated in Task 2, now extends to surface `:required_one_of`)
- Modify: `test/wymcp/tool_test.exs`

- [ ] **Step 5.1: Add failing tests for `help` surfacing**

In `test/wymcp/tool_test.exs`, inside the existing `describe "run/2 — help action"` block, add:

```elixir
    test "help (no topic) includes required_one_of for actions that declare it" do
      result = WidgetTool.run(build_ctx(), %{"action" => "help"})
      content = decode_json_content(result)
      identify = content["actions"]["identify"]

      assert identify["required_one_of"] == [["id"], ["name", "color"]]
      assert identify["required"] == []
    end

    test "help (no topic) omits required_one_of for actions that don't declare it" do
      result = WidgetTool.run(build_ctx(), %{"action" => "help"})
      content = decode_json_content(result)

      refute Map.has_key?(content["actions"]["create"], "required_one_of")
    end

    test "help with topic surfaces required_one_of in slim schema" do
      result =
        WidgetTool.run(build_ctx(), %{"action" => "help", "data" => %{"topic" => "identify"}})

      content = decode_json_content(result)
      assert content["schema"]["required_one_of"] == [["id"], ["name", "color"]]
    end

    test "help with topic omits required_one_of when action doesn't declare it" do
      result =
        WidgetTool.run(build_ctx(), %{"action" => "help", "data" => %{"topic" => "create"}})

      content = decode_json_content(result)
      refute Map.has_key?(content["schema"], "required_one_of")
    end
```

- [ ] **Step 5.2: Run the new tests and confirm they fail**

Run: `cd /Users/kgronber/Projects/wymcp && mix test test/wymcp/tool_test.exs`
Expected: the four new help tests FAIL — `action_summary/2` and `slim_action_schema/1` do not yet surface `:required_one_of`.

- [ ] **Step 5.3: Update `action_summary/2`**

Find at `lib/wymcp/tool.ex:394-402`:

```elixir
  @spec action_summary(module(), map()) :: map()
  defp action_summary(module, actions) do
    summary =
      Map.new(actions, fn {action, schema} ->
        {Atom.to_string(action), %{description: schema.description, required: schema.required}}
      end)

    %{tool: module.name(), actions: summary}
  end
```

Replace with:

```elixir
  @spec action_summary(module(), map()) :: map()
  defp action_summary(module, actions) do
    summary =
      Map.new(actions, fn {action, schema} ->
        entry = %{
          description: schema.description,
          required: Map.get(schema, :required, [])
        }

        entry =
          case Map.get(schema, :required_one_of, []) do
            [] -> entry
            groups -> Map.put(entry, :required_one_of, groups)
          end

        {Atom.to_string(action), entry}
      end)

    %{tool: module.name(), actions: summary}
  end
```

- [ ] **Step 5.4: Extend `slim_action_schema/1` to surface `:required_one_of`**

Find at `lib/wymcp/tool.ex:425-433` (after Task 2 the `:required` read is defensive; the body is now):

```elixir
  @spec slim_action_schema(action_schema()) :: map()
  defp slim_action_schema(schema) do
    properties =
      Map.new(schema.properties, fn {name, prop} ->
        {name, Map.take(prop, ["type", "description"])}
      end)

    %{
      description: schema.description,
      required: Map.get(schema, :required, []),
      properties: properties
    }
  end
```

Replace with:

```elixir
  @spec slim_action_schema(action_schema()) :: map()
  defp slim_action_schema(schema) do
    properties =
      Map.new(schema.properties, fn {name, prop} ->
        {name, Map.take(prop, ["type", "description"])}
      end)

    base = %{
      description: schema.description,
      required: Map.get(schema, :required, []),
      properties: properties
    }

    case Map.get(schema, :required_one_of, []) do
      [] -> base
      groups -> Map.put(base, :required_one_of, groups)
    end
  end
```

- [ ] **Step 5.5: Run the new tests and confirm they pass**

Run: `cd /Users/kgronber/Projects/wymcp && mix test test/wymcp/tool_test.exs`
Expected: all tests PASS, including the four new help tests.

---

## Task 6: Surface `:required_one_of` in `describe` output

`describe` uses `Map.take/2` (twice — `dispatch/4` for topic mode at lines 260-269, `full_action_listing/2` for no-topic mode at lines 404-423). `Map.take/2` silently skips missing keys, so adding `:required_one_of` to the take list is safe and non-breaking for actions that don't declare it.

**Files:**
- Modify: `lib/wymcp/tool.ex:260-269` (describe with topic)
- Modify: `lib/wymcp/tool.ex:404-423` (describe without topic)
- Modify: `test/wymcp/tool_test.exs`

- [ ] **Step 6.1: Add failing tests for `describe` surfacing**

In `test/wymcp/tool_test.exs`, inside `describe "run/2 — describe action"`, add:

```elixir
    test "describe (no topic) includes required_one_of when declared" do
      result = WidgetTool.run(build_ctx(), %{"action" => "describe"})
      content = decode_json_content(result)

      assert content["actions"]["identify"]["required_one_of"] == [
               ["id"],
               ["name", "color"]
             ]
    end

    test "describe (no topic) omits required_one_of when not declared" do
      result = WidgetTool.run(build_ctx(), %{"action" => "describe"})
      content = decode_json_content(result)

      refute Map.has_key?(content["actions"]["create"], "required_one_of")
    end

    test "describe with topic includes required_one_of when declared" do
      result =
        WidgetTool.run(build_ctx(), %{"action" => "describe", "data" => %{"topic" => "identify"}})

      content = decode_json_content(result)
      assert content["schema"]["required_one_of"] == [["id"], ["name", "color"]]
    end

    test "describe with topic omits required_one_of when not declared" do
      result =
        WidgetTool.run(build_ctx(), %{"action" => "describe", "data" => %{"topic" => "create"}})

      content = decode_json_content(result)
      refute Map.has_key?(content["schema"], "required_one_of")
    end
```

- [ ] **Step 6.2: Run the tests and confirm they fail**

Run: `cd /Users/kgronber/Projects/wymcp && mix test test/wymcp/tool_test.exs`
Expected: the two positive describe tests FAIL — currently `Map.take` does not list `:required_one_of`, so the key is absent. (The two `refute` tests pass already.)

- [ ] **Step 6.3: Add `:required_one_of` to both `Map.take` calls**

Find at `lib/wymcp/tool.ex:260-269` (inside the `describe` topic branch of `dispatch/4`):

```elixir
          full =
            Map.take(schema, [
              :description,
              :properties,
              :required,
              :defaults,
              :notes,
              :related,
              :examples
            ])
```

Replace with:

```elixir
          full =
            Map.take(schema, [
              :description,
              :properties,
              :required,
              :required_one_of,
              :defaults,
              :notes,
              :related,
              :examples
            ])
```

Find at `lib/wymcp/tool.ex:404-420` (`full_action_listing/2`):

```elixir
  @spec full_action_listing(module(), map()) :: map()
  defp full_action_listing(module, actions) do
    actions_map =
      Enum.into(actions, %{}, fn {action_atom, schema} ->
        full =
          Map.take(schema, [
            :description,
            :properties,
            :required,
            :defaults,
            :notes,
            :related,
            :examples
          ])

        {Atom.to_string(action_atom), full}
      end)

    %{tool: module.name(), actions: actions_map}
  end
```

Replace with:

```elixir
  @spec full_action_listing(module(), map()) :: map()
  defp full_action_listing(module, actions) do
    actions_map =
      Enum.into(actions, %{}, fn {action_atom, schema} ->
        full =
          Map.take(schema, [
            :description,
            :properties,
            :required,
            :required_one_of,
            :defaults,
            :notes,
            :related,
            :examples
          ])

        {Atom.to_string(action_atom), full}
      end)

    %{tool: module.name(), actions: actions_map}
  end
```

- [ ] **Step 6.4: Run the tests and confirm they pass**

Run: `cd /Users/kgronber/Projects/wymcp && mix test test/wymcp/tool_test.exs`
Expected: all tests PASS, including the four new describe tests.

---

## Task 7: Render `required_one_of` as `anyOf` in JSON Schema

When `Wymcp.Tool.Schema.build/1` (full mode) produces the per-action variant, the OR-of-AND constraint should appear in the variant's `data` schema as `anyOf: [{"required": [...]}, ...]`. This communicates the constraint to MCP clients and LLMs reading `tools/list`.

`anyOf` (not `oneOf`) is correct: a caller that supplies both `url` and `(project_key + repo_slug + pr_id)` is acceptable per the runtime check.

Slim mode does not emit per-action constraints (it only lists action names with one-line descriptions), so no slim-mode change is needed. The slim-mode trade-off is documented in `@moduledoc` (Task 1.2).

**Files:**
- Modify: `lib/wymcp/tool/schema.ex:103-131` (`build_variant/2`)
- Modify: `test/wymcp/tool/schema_test.exs`

- [ ] **Step 7.1: Add failing tests for `anyOf` rendering**

Open `test/wymcp/tool/schema_test.exs`. Inside the existing `@actions` map (lines 22-48), add:

```elixir
    identify: %{
      description: "Identify by id or by (name + color)",
      properties: %{
        "id" => %{"type" => "integer"},
        "name" => %{"type" => "string"},
        "color" => %{"type" => "string"}
      },
      required_one_of: [["id"], ["name", "color"]],
      defaults: %{}
    }
```

Add new tests inside `describe "build/1"`:

```elixir
    @tag doc: "required_one_of becomes anyOf on the variant's data schema"
    test "variant with required_one_of renders anyOf on data" do
      schema = Schema.build(@actions)
      identify = find_variant(schema, "identify")

      assert identify["properties"]["data"]["anyOf"] == [
               %{"required" => ["id"]},
               %{"required" => ["name", "color"]}
             ]
    end

    @tag doc:
           "required_one_of forces data to be required on the variant even when :required is empty"
    test "variant with required_one_of marks data as required" do
      schema = Schema.build(@actions)
      identify = find_variant(schema, "identify")

      assert "data" in identify["required"]
    end

    test "variant without required_one_of does not include anyOf" do
      schema = Schema.build(@actions)
      list = find_variant(schema, "list")

      refute Map.has_key?(list["properties"]["data"], "anyOf")
    end
```

- [ ] **Step 7.2: Run the tests and confirm they fail**

Run: `cd /Users/kgronber/Projects/wymcp && mix test test/wymcp/tool/schema_test.exs`
Expected: the three new tests FAIL — `build_variant` currently ignores `:required_one_of`.

- [ ] **Step 7.3: Update `build_variant/2`**

Find at `lib/wymcp/tool/schema.ex:103-131`:

```elixir
  @spec build_variant(atom(), map()) :: json_schema()
  defp build_variant(action_name, schema) do
    action_str = Atom.to_string(action_name)

    data_schema = %{"type" => "object", "properties" => schema.properties}

    data_schema =
      if schema.required != [],
        do: Map.put(data_schema, "required", schema.required),
        else: data_schema

    required =
      if schema.required != [],
        do: ["action", "data"],
        else: ["action"]

    variant = %{
      "properties" => %{
        "action" => %{"const" => action_str},
        "data" => data_schema
      },
      "required" => required
    }

    case Map.get(schema, :description) do
      nil -> variant
      desc -> Map.put(variant, "description", desc)
    end
  end
```

Replace with:

```elixir
  @spec build_variant(atom(), map()) :: json_schema()
  defp build_variant(action_name, schema) do
    action_str = Atom.to_string(action_name)
    required = Map.get(schema, :required, [])
    one_of_groups = Map.get(schema, :required_one_of, [])

    data_schema = %{"type" => "object", "properties" => schema.properties}

    data_schema =
      if required != [],
        do: Map.put(data_schema, "required", required),
        else: data_schema

    data_schema =
      case one_of_groups do
        [] ->
          data_schema

        groups ->
          any_of = Enum.map(groups, fn group -> %{"required" => group} end)
          Map.put(data_schema, "anyOf", any_of)
      end

    variant_required =
      if required != [] or one_of_groups != [],
        do: ["action", "data"],
        else: ["action"]

    variant = %{
      "properties" => %{
        "action" => %{"const" => action_str},
        "data" => data_schema
      },
      "required" => variant_required
    }

    case Map.get(schema, :description) do
      nil -> variant
      desc -> Map.put(variant, "description", desc)
    end
  end
```

(Note: `schema.required` was the old direct read — replaced by `Map.get(schema, :required, [])` to honour Task 1's optionality. The `variant_required` rename avoids shadowing `required`.)

- [ ] **Step 7.4: Run the tests and confirm they pass**

Run: `cd /Users/kgronber/Projects/wymcp && mix test test/wymcp/tool/schema_test.exs`
Expected: all tests in this file PASS.

- [ ] **Step 7.5: Add end-to-end pipeline tests for both schema modes**

Design decision C2 (revised). `Wymcp.Plugs.Validate` only validates the JSON-RPC envelope against `priv/schema.json` (`JSONRPCMessage`) — it does NOT apply per-tool `inputSchema` to `tools/call` arguments. So the runtime validator in `dispatch/4` is the enforcer for `:required_one_of` in *both* schema modes. The difference between modes is purely descriptive: full mode advertises the constraint via `anyOf` in `tools/list`; slim mode omits per-action constraints.

This step pins both halves of that story end-to-end through the router pipeline.

Open `test/wymcp/router_test.exs`. Add two fixture modules at top level (alongside the other top-level fixtures from Task 3.1):

```elixir
  defmodule OneOfTool do
    use Wymcp.Tool

    def name, do: "oneof"
    def description, do: "OR-of-AND test tool"

    def actions do
      %{
        identify: %{
          description: "Identify by id or (name + color)",
          properties: %{
            "id" => %{"type" => "integer"},
            "name" => %{"type" => "string"},
            "color" => %{"type" => "string"}
          },
          required_one_of: [["id"], ["name", "color"]]
        }
      }
    end

    def run_action(:identify, data, _ctx), do: {:ok, %{found: data}}
  end

  defmodule SlimOneOfTool do
    use Wymcp.Tool

    def name, do: "slim_oneof"
    def description, do: "OR-of-AND test tool, slim mode"
    def schema_mode, do: :slim

    def actions do
      %{
        identify: %{
          description: "Identify by id or (name + color)",
          properties: %{
            "id" => %{"type" => "integer"},
            "name" => %{"type" => "string"},
            "color" => %{"type" => "string"}
          },
          required_one_of: [["id"], ["name", "color"]]
        }
      }
    end

    def run_action(:identify, data, _ctx), do: {:ok, %{found: data}}
  end
```

Then add a new `describe` block:

```elixir
  describe "tools/list + tools/call with :required_one_of (end-to-end)" do
    @tag doc: """
    Full mode advertises the constraint to clients via `anyOf` on the
    variant's `data`. This is descriptive only — see the runtime test
    below for enforcement.
    """
    test "full mode: tools/list exposes anyOf for required_one_of" do
      session_id = initialize(tools: [OneOfTool])

      body = %{"jsonrpc" => "2.0", "id" => 1, "method" => "tools/list"}
      conn = call_with_session(body, session_id, tools: [OneOfTool])
      resp = JSON.decode!(conn.resp_body)

      [tool] = resp["result"]["tools"]
      [variant] = tool["inputSchema"]["oneOf"]

      assert variant["properties"]["data"]["anyOf"] == [
               %{"required" => ["id"]},
               %{"required" => ["name", "color"]}
             ]
    end

    @tag doc: """
    Slim mode emits a bare `data: {type: "object"}`, so the constraint is
    NOT advertised in the inputSchema. Clients learn about it via the
    framework-provided `help`/`describe` actions.
    """
    test "slim mode: tools/list omits anyOf (slim has no per-action constraints)" do
      session_id = initialize(tools: [SlimOneOfTool])

      body = %{"jsonrpc" => "2.0", "id" => 1, "method" => "tools/list"}
      conn = call_with_session(body, session_id, tools: [SlimOneOfTool])
      resp = JSON.decode!(conn.resp_body)

      [tool] = resp["result"]["tools"]
      refute Map.has_key?(tool["inputSchema"], "oneOf")
      refute Map.has_key?(tool["inputSchema"]["properties"]["data"], "anyOf")
    end

    @tag doc: """
    Full mode runtime enforcement: a tools/call with no group satisfied
    is caught by `dispatch/4`'s `check_required_one_of/3` (NOT by JSV,
    which only validates the JSON-RPC envelope). The response is a
    successful JSON-RPC result containing the in-band
    `missing_required_group` error payload.
    """
    test "full mode: tools/call with no group satisfied returns missing_required_group" do
      session_id = initialize(tools: [OneOfTool])

      body = %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "tools/call",
        "params" => %{
          "name" => "oneof",
          "arguments" => %{"action" => "identify", "data" => %{"name" => "alpha"}}
        }
      }

      conn = call_with_session(body, session_id, tools: [OneOfTool])
      resp = JSON.decode!(conn.resp_body)

      content = resp["result"]["content"] |> hd() |> Map.get("text") |> JSON.decode!()
      assert content["error"] == "missing_required_group"
      assert content["required_one_of"] == [["id"], ["name", "color"]]
    end

    @tag doc: """
    Slim mode runtime enforcement: same code path as full mode. The
    constraint is invisible in `tools/list` but still enforced at
    dispatch time, proving the runtime check is the sole enforcer.
    """
    test "slim mode: tools/call with no group satisfied returns missing_required_group" do
      session_id = initialize(tools: [SlimOneOfTool])

      body = %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "tools/call",
        "params" => %{
          "name" => "slim_oneof",
          "arguments" => %{"action" => "identify", "data" => %{"name" => "alpha"}}
        }
      }

      conn = call_with_session(body, session_id, tools: [SlimOneOfTool])
      resp = JSON.decode!(conn.resp_body)

      content = resp["result"]["content"] |> hd() |> Map.get("text") |> JSON.decode!()
      assert content["error"] == "missing_required_group"
      assert content["required_one_of"] == [["id"], ["name", "color"]]
    end
  end
```

- [ ] **Step 7.6: Run the new tests and confirm they pass**

Run: `cd /Users/kgronber/Projects/wymcp && mix test test/wymcp/router_test.exs`
Expected: all four new tests PASS. They are regression coverage on top of Tasks 4 and 7 (no new production code is needed for them to pass).

---

## Task 8: Run the full test suite, compile, and dialyzer

- [ ] **Step 8.1: Run the full test suite**

Run: `cd /Users/kgronber/Projects/wymcp && mix test`
Expected: all tests PASS, no warnings.

- [ ] **Step 8.2: Compile with warnings-as-errors**

Run: `cd /Users/kgronber/Projects/wymcp && mix compile --warnings-as-errors --force`
Expected: clean compile.

- [ ] **Step 8.3: Run dialyzer if it's wired up**

Run: `cd /Users/kgronber/Projects/wymcp && mix dialyzer 2>&1 | tail -40`
Expected: no new warnings introduced by the changes. If pre-existing warnings exist (unrelated lines), note but do not fix.

If `mix dialyzer` is not available or PLTs are not built, skip this step rather than blocking. Wymcp's CI should catch any spec mismatches.

---

## Task 9: Update CHANGELOG and bump version

**Files:**
- Modify: `CHANGELOG.md`
- Modify: `mix.exs`

- [ ] **Step 9.1: Add a CHANGELOG entry**

Open `CHANGELOG.md`. Insert a new section above the existing `## [0.4.1]` section:

```markdown
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
```

- [ ] **Step 9.2: Bump the version**

Find in `mix.exs`:

```elixir
      version: "0.4.1",
```

Replace with:

```elixir
      version: "0.5.0",
```

- [ ] **Step 9.3: Verify lockfile and compile**

Run: `cd /Users/kgronber/Projects/wymcp && mix compile`
Expected: clean compile reflecting the new version.

---

## Self-Review Notes

**Spec coverage:**

- Add `required_one_of` field to action schema → Tasks 1, 4, 5, 6, 7
- Make `required` optional with default `[]` → Tasks 1, 2
- Make `defaults` optional with default `%{}` → Tasks 1, 2
- Init-time shape validation (boot crash on misconfig) → Task 3
- Surface in `help` (no topic) → Task 5 (`action_summary/2`)
- Surface in `help` (with topic) → Task 5 (`slim_action_schema/1`)
- Surface in `describe` (both forms) → Task 6
- Render in JSON Schema (`anyOf` on variant) → Task 7
- Validation at dispatch time → Task 4
- Distinct error code `missing_required_group` for the new failure mode → Task 4
- Consistent `input_schema` payload across both error branches → Task 4 (`schema_summary/1`)
- Tests covering the four `:required` × `:required_one_of` interaction corners → Task 4 (Step 4.1)
- Pinned human-readable message format → Task 4 (Step 4.1)
- Negative-case tests (action without `:required_one_of` does not surface the key) → Tasks 5, 6
- Documentation in `@moduledoc` and `CHANGELOG` (incl. slim-mode trade-off) → Task 1 (Step 1.2), Task 9
- Pin semantics: `:defaults` is applied AFTER validation and cannot satisfy `:required` or `:required_one_of` (design choice A1) → Task 1 (Step 1.2 moduledoc), Task 4 (Step 4.1 test)
- Init-time shape validation for documentation fields `:notes`/`:related`/`:examples` (design choice B2) → Task 3 (Steps 3.1 + 3.3)
- End-to-end pipeline tests covering both schema modes (design choice C2, revised after discovering `Plugs.Validate` only checks the JSON-RPC envelope) → Task 7 (Step 7.5)

**Type-consistency check:**

- `:required_one_of` shape: `[[String.t()]]` — used identically in type spec (Task 1.1), init-time validator (Task 3.3), runtime validator (Task 4.3), summary/slim/full renderers (Tasks 5.3, 5.4, 6.3), and JSON Schema rendering (Task 7.3).
- Error tag `:missing_required_groups` (internal) maps to error code `"missing_required_group"` (wire) — produced in Task 4.3, consumed in Task 4.4. Singular wire form matches the convention (one *group* of fields per action call must satisfy).
- `format_groups/1` — produced in Task 4.3, consumed in Task 4.4.
- `schema_summary/1` — produced in Task 4.3, consumed by both error branches in Task 4.4.
- All `Map.get(schema, :required, [])` and `Map.get(schema, :defaults, %{})` reads use the same defaulting — no sites read `schema.required` or `schema.defaults` directly after Task 2.

**Deliberate non-goals (deferred):**

- Round-trip tests for `:related` and `:examples` (asserting these keys appear in `describe` output when declared). Shape validation at boot (Task 3) catches obvious typos, but a concrete consumer that round-trips these keys would still be the right trigger for pinning the behaviour in tests.
- Extracting a `Wymcp.Tool.SchemaValidation` module. Validation logic for one new constraint plus three documentation fields fits comfortably inside `Wymcp.Tool`. If later changes add more constraints (e.g. `uniqueItems`, `min/maxLength`, conditional schemas), extracting validation into its own module is the natural next step. Out of scope for this plan.
- Enriching slim-mode `tools/list` with per-action constraint hints. Slim mode is, by definition, the compact representation; surfacing `:required_one_of` only via `help`/`describe` is the documented trade-off (Task 1.2) and the runtime validator is the sole enforcer in slim mode (proved by Task 7's Step 7.5 end-to-end tests).

**Placeholder scan:** No `TBD`, no `add appropriate handling`, no `similar to Task N`. Every code block is the exact final content.
