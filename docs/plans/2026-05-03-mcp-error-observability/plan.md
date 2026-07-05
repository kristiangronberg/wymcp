# 2026-05-03 MCP Error Observability Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Three independent improvements to wymcp's error and observability surface: spec-compliant tool error reporting, per-request scope plumbing through the `action_context` callback, and structured logging plus telemetry on auth failures. Plus the consumer-side migration in `ymer` for the callback change.

> **Note on motivation.** This plan was originally scoped to fix a Claude.ai disconnect/reconnect loop attributed to `action_context/1` raising on a missing process-dictionary scope. A subsequent log audit of the production droplet did not find that exception pattern (zero matches for `"No MCP scope set"`, zero matches for `Tool .+ raised:`) — the disconnect symptom was caused by something else (see "Known issues found during diagnosis" at the end of the plan). The three tasks here remain individually defensible as architectural and observability improvements, but should not be advertised as fixes for that specific symptom.

**Architecture:** Three discrete changes inside `Wymcp`, then a follow-up migration in `ymer`.

1. **Task 1.** Change the `Wymcp.Tool.action_context` callback from arity 1 to arity 2 so it receives `Wymcp.Context.t()` and consumers can read `ctx.assigns[:current_scope]` directly. Process dictionary for per-request data is fragile — `ctx.assigns` is the right channel and is already populated by the consumer's auth plug.
2. **Task 2.** Convert tool raises in `Methods.ToolsCall` into MCP-spec-compliant `isError: true` content (a successful JSON-RPC response with diagnostic content) instead of a -32603 protocol error. Per the MCP 2025-11-25 schema (`priv/schema.json:200-201`), errors that originate from the tool SHOULD be reported inside the result with `isError: true` so the LLM can see the failure and self-correct. The current behaviour collapses every tool raise into an opaque protocol error — even though no tool actually raised in the recent log window, the next one will, and this is the spec-correct place to handle it.
3. **Task 3.** Add structured logging plus telemetry events at `Plugs.Auth` failure paths so consumers can attribute auth-rejection spikes without grepping logs. The current plug is silent on the expected `{:error, _}` rejection branch.

After Tasks 1–3 land in `wymcp`, the **ymer-side migration** section walks through the consumer changes — moving every `action_context/1` override to arity 2, dropping the `Helpers.put_scope/1` / `current_scope/0` process-dict path, and the auth plug's vestigial `Process.put` call.

**Tech Stack:** Elixir, Plug, `:telemetry`, ExUnit. No new dependencies.

Documentation work in this plan must follow the `elixir-documentation-standards` skill.

**Diagram impact:** Update the mermaid edge in `lib/wymcp/tool.ex` (line 99) from `action_context/1` to `action_context/2`. No new modules, no new processes, no new state machines.

**Breaking change callout:** Task 1 changes `c:Wymcp.Tool.action_context/1` to `c:Wymcp.Tool.action_context/2`. Any consumer that overrode `action_context` will fail to compile until updated. The `ymer` repo is the only known consumer; its migration is sequenced as the final section of this plan and runs against the local `path: "../wymcp"` dependency, so no Hex release is needed between the two sides.

---

## File Structure

**Files modified:**

- `lib/wymcp/tool.ex` — change `action_context` callback arity 1 → 2; update default override; update `dispatch/4` and `handle_result/3` (becomes `/4`) and `maybe_add_context/3` (becomes `/4`) to thread `ctx`. Update `@moduledoc` callback list, prose at line 57, and mermaid diagram at line 99.
- `lib/wymcp/methods/tools_call.ex` — convert the tool-raise `rescue` clause to emit an `isError: true` content response with diagnostic JSON; enrich telemetry metadata.
- `lib/wymcp/plugs/auth.ex` — log structured metadata on `{:error, message}` and rescue branches; emit telemetry events.
- `lib/wymcp/telemetry.ex` — document new `[:wymcp, :auth, :reject]` and `[:wymcp, :auth, :error]` events.
- `mix.exs` — bump version `0.2.0` → `0.3.0` (breaking callback change).
- `CHANGELOG.md` — record breaking change for Task 1 and behavioural changes for Tasks 2 and 3.

**Files created:**

- `test/wymcp/plugs/auth_test.exs` — first-time test coverage for `Wymcp.Plugs.Auth` (existing `test/wymcp/auth_test.exs` only covers the `Auth` *behaviour*, not the plug).

**Files modified (tests):**

- `test/wymcp/tool_test.exs` — update the `SlimWidgetTool` fixture's `action_context` to arity 2; add a test that the new callback receives the dispatching `ctx`.
- `test/wymcp/integration_test.exs` — update two `action_context/1` overrides at lines 91 and 430 (these fixtures use `@behaviour Wymcp.Tool` directly, so the macro default doesn't cover them).
- `test/wymcp/methods/tools_call_test.exs` — replace the existing `"returns internal_error when tool raises"` test with an `isError: true` content assertion.

---

## Task 1: Change `action_context` callback to arity 2

The current callback at `lib/wymcp/tool.ex:133` is `action_context(action :: atom())`. Consumers like `Ymer.Mcp.Tools.Docs.action_context/1` read scope from `Process.get(:mcp_current_scope)` via `Ymer.Mcp.Tools.Helpers.current_scope/0`, which raises `"No MCP scope set"` when the dictionary entry is absent. The process-dictionary pattern is fragile because it depends on the auth plug having run in the same process that ends up dispatching the callback. Passing `Wymcp.Context.t()` lets the consumer use `ctx.assigns[:current_scope]` instead — the auth plug already populates that assign, and `ctx.assigns` is the explicit per-request channel that doesn't depend on process identity.

**Files:**
- Modify: `lib/wymcp/tool.ex` — callback at line 133, default override at lines 153-154, `defoverridable` list at lines 165-171, `dispatch/4` clauses at lines 218-292, `handle_result/3` at lines 317-351, `maybe_add_context/3` at lines 412-418, `@moduledoc` references at lines 57, 68, and 99.
- Modify: `test/wymcp/tool_test.exs` — fixture at lines 202-203, plus a new test in the `"run/2 — action_context injection"` describe block (lines 448-492).
- Modify: `test/wymcp/integration_test.exs` — fixtures at lines 91 and 430.

- [ ] **Step 1: Update the test fixture `action_context` overrides to arity 2**

In `test/wymcp/tool_test.exs` around lines 202-203, replace:

```elixir
def action_context(:list), do: %{tip: "2 widgets need attention"}
def action_context(_action), do: nil
```

with:

```elixir
def action_context(:list, _ctx), do: %{tip: "2 widgets need attention"}
def action_context(_action, _ctx), do: nil
```

In `test/wymcp/integration_test.exs` at lines 91 and 430, replace each:

```elixir
def action_context(_action), do: nil
```

with:

```elixir
def action_context(_action, _ctx), do: nil
```

These two fixtures use `@behaviour Wymcp.Tool` directly (no `use` macro), so they don't pick up the macro default — they fail to compile after the callback change unless updated here.

- [ ] **Step 2: Add a fixture and test that `action_context/2` receives the dispatching `ctx`**

In `test/wymcp/tool_test.exs`, define a new fixture **at the top of the test module alongside the existing fixtures** (do not nest inside a `test` block — that breaks on re-run with "already defined"):

```elixir
defmodule CtxAwareTool do
  use Wymcp.Tool

  def name, do: "ctx_aware"
  def description, do: "Echoes the assign it sees in action_context"

  def actions do
    %{list: %{description: "List", properties: %{}, required: [], defaults: %{}}}
  end

  def run_action(:list, _data, _ctx), do: {:ok, %{ok: true}}

  def action_context(:list, ctx),
    do: %{seen_scope: ctx.assigns[:current_scope]}

  def action_context(_action, _ctx), do: nil
end
```

Then, inside the existing `describe "run/2 — action_context injection"` block, add:

```elixir
@tag doc: """
Verifies that `action_context/2` receives the same `ctx` the tool's
`run_action/3` receives. Failure means the callback is being invoked
from a different process or with stale context — historically this
broke `Ymer.Mcp.Tools.Docs.action_context(:search)` because it had to
fall back to `Process.get(:mcp_current_scope)` and crashed with
`No MCP scope set` whenever the dispatch ran in a process that had
not been auth-plugged.
"""
test "action_context/2 receives the dispatching ctx" do
  ctx = %Wymcp.Context{
    session_pid: nil,
    session_id: "test",
    request_id: 1,
    meta: nil,
    assigns: %{current_scope: :sentinel}
  }

  {:ok, content} = CtxAwareTool.run(ctx, %{"action" => "list", "data" => %{}})
  body = content |> hd() |> Map.get("text") |> JSON.decode!()

  assert body["context"]["seen_scope"] == "sentinel"
end
```

- [ ] **Step 3: Run the new test to confirm it fails**

Run: `mix test test/wymcp/tool_test.exs -n "action_context/2 receives"`

Expected: FAIL — module compile error (`action_context/2 undefined` from the `CtxAwareTool` fixture, since the callback is still arity 1) or similar.

- [ ] **Step 4: Update the `@callback` declaration**

In `lib/wymcp/tool.ex` at line 133, change:

```elixir
@callback action_context(action :: atom()) :: map() | nil
```

to:

```elixir
@callback action_context(action :: atom(), ctx :: Wymcp.Context.t()) :: map() | nil
```

- [ ] **Step 5: Update the `defoverridable` list and default override**

In `lib/wymcp/tool.ex` at lines 153-154, replace:

```elixir
@spec action_context(atom()) :: map() | nil
def action_context(_action), do: nil
```

with:

```elixir
@spec action_context(atom(), Wymcp.Context.t()) :: map() | nil
def action_context(_action, _ctx), do: nil
```

And in the `defoverridable` list at lines 165-171, change `action_context: 1` to `action_context: 2`.

- [ ] **Step 6: Thread `ctx` through `dispatch/4`, `handle_result/3`, and `maybe_add_context/3`**

There are five call sites of `maybe_add_context/3` plus its definition in `lib/wymcp/tool.ex`. Confirm with:

```bash
grep -n "maybe_add_context" lib/wymcp/tool.ex
```

Expected hits (line numbers approximate, see `git blame` for current values): 229 (`dispatch/4` help/topic), 258 (`dispatch/4` describe/topic), 320 (`handle_result/3` `{:ok, response}`), 331 (`handle_result/3` `{:ok, response, hint_context}`), 344 (`handle_result/3` `{:error, reason, hint_context}`), and the definition at 412.

Update `maybe_add_context/3` (definition at line 412) from:

```elixir
@spec maybe_add_context(map(), module(), atom()) :: map()
defp maybe_add_context(response, module, action) do
  case module.action_context(action) do
    nil -> response
    context when is_map(context) -> Map.put(response, :context, context)
  end
end
```

to:

```elixir
@spec maybe_add_context(map(), module(), atom(), Wymcp.Context.t()) :: map()
defp maybe_add_context(response, module, action, ctx) do
  case module.action_context(action, ctx) do
    nil -> response
    context when is_map(context) -> Map.put(response, :context, context)
  end
end
```

Then update each call site to pass `ctx`:

1. **`dispatch/4` help/topic** (around line 218). The head is currently `def dispatch(module, _ctx, "help", data) do` — change `_ctx` to `ctx` so it's bound, then change the call from `maybe_add_context(response, module, action_atom)` to `maybe_add_context(response, module, action_atom, ctx)`.

2. **`dispatch/4` describe/topic** (around line 236). Same change pattern: bind `ctx` in the head (`def dispatch(module, ctx, "describe", data) do`), pass it to `maybe_add_context`.

3. **`handle_result/3` becomes `handle_result/4`**. The caller at the end of `dispatch/4` (currently `handle_result(module, action, module.run_action(action, merged, ctx))`) becomes `handle_result(module, action, ctx, module.run_action(action, merged, ctx))`. Update the `@spec` and all four function-head clauses (`{:ok, response}`, `{:ok, response, hint_context}`, `{:error, reason, hint_context}`, `{:error, reason}`) — even the last one, which doesn't use `ctx`, must accept it for clause-matching consistency.

After the edits, the new `handle_result/4` `@spec` should read:

```elixir
@spec handle_result(module(), atom(), Wymcp.Context.t(), tuple()) ::
        {:ok, Context.content()} | {:ok, Context.content(), map()} | {:error, String.t()}
```

The `{:error, reason}` clause becomes:

```elixir
defp handle_result(module, _action, _ctx, {:error, reason}) do
  {:error, module.handle_error(reason)}
end
```

The other three clauses pass `ctx` as the fourth argument to `maybe_add_context/4`.

- [ ] **Step 7: Run the new arity-2 test to confirm it passes**

Run: `mix test test/wymcp/tool_test.exs -n "action_context/2 receives"`

Expected: PASS.

- [ ] **Step 8: Run the full tool_test and integration_test files to catch regressions**

Run: `mix test test/wymcp/tool_test.exs test/wymcp/integration_test.exs`

Expected: All tests PASS. The fixture updates from Step 1 should compile cleanly.

- [ ] **Step 9: Update the three doc references in `lib/wymcp/tool.ex`**

Three places mention `action_context/1` in `lib/wymcp/tool.ex`:

- **Line 57** (paragraph in `@moduledoc` about error-with-hints flow): change `"and action_context/1"` to `"and action_context/2"`.
- **Line 68** (callback list bullet): change `action_context/1` to `action_context/2` and update the description:

  ```
  - `action_context/2` — returns a map of runtime context for the given
    action, or `nil`. Receives `(action_atom, ctx)`, where `ctx` is the
    same `Wymcp.Context.t()` passed to `run_action/3`. Called during
    help (with topic), describe (with topic), and normal action
    dispatch. The map appears under a `"context"` key in the response.
    Read per-request data from `ctx.assigns` rather than the process
    dictionary — `action_context` may be invoked from a process that
    did not run the auth plug.
  ```

- **Line 99** (mermaid edge): change `R -->|"module.action_context/1"| CB` to `R -->|"module.action_context/2"| CB`.

- [ ] **Step 10: Bump version and add CHANGELOG entry**

In `mix.exs` line 9, change `version: "0.2.0"` to `version: "0.3.0"`.

Open `CHANGELOG.md` at the repo root. If it doesn't exist, create it with a standard Keep-a-Changelog header. Add an `[Unreleased]` (or `[0.3.0]`) section, then under it:

```markdown
### Changed (BREAKING)

- `c:Wymcp.Tool.action_context/1` is now `c:Wymcp.Tool.action_context/2`.
  The callback receives `(action_atom, ctx)` where `ctx` is the same
  `Wymcp.Context.t()` passed to `run_action/3`. Consumers that override
  `action_context` must update the arity. Read per-request scope from
  `ctx.assigns[:current_scope]` (or wherever the consumer's auth plug
  put it) instead of the process dictionary — `ctx.assigns` is the
  explicit per-request channel and does not depend on which process
  ends up dispatching the callback.
```

## Task 2: Tool raises become `isError: true` content

The current rescue at `lib/wymcp/methods/tools_call.ex:79-93` catches tool exceptions and emits `JsonRpc.error_response(:internal_error, request["id"], %{})` (-32603). Per the MCP 2025-11-25 schema (`priv/schema.json:200-201`):

> Any errors that originate from the tool SHOULD be reported inside the result object, with `isError` set to true, **not** as an MCP protocol-level error response. Otherwise, the LLM would not be able to see that an error occurred and self-correct.

A `raise` inside `run_action/3` is by definition an error originating from the tool. The fix: convert it to a successful JSON-RPC response with `isError: true` and a JSON-encoded diagnostic body in the content. This is the same path already used for `{:error, message}` returns from `run_action/3`, so we reuse `send_tool_result/5`.

**Files:**
- Modify: `lib/wymcp/methods/tools_call.ex:79-93`
- Modify: `test/wymcp/methods/tools_call_test.exs:156-173`

- [ ] **Step 1: Replace the existing rescue test**

Open `test/wymcp/methods/tools_call_test.exs` and replace the existing `"returns internal_error when tool raises"` test (lines 156-173) with:

```elixir
@tag capture_log: true
@tag doc: """
Per MCP 2025-11-25 schema (priv/schema.json:200-201), errors that
originate from the tool — including raises inside `run_action/3` —
must be reported as a successful JSON-RPC response with `isError:
true` in the result. Reporting them as protocol-level -32603 hides
the error from the LLM, which the spec calls out by name as the
reason for the rule. Failure here means a regression to the old
opaque behaviour; check the rescue clause in `tools_call.ex`.
"""
test "tool raises produce isError content, not a protocol error" do
  conn =
    build_conn(
      "tools/call",
      %{
        "name" => "crasher",
        "arguments" => %{"action" => "crash"}
      },
      [CrashingTool]
    )

  result = ToolsCall.run(conn, [CrashingTool])
  body = JSON.decode!(result.resp_body)

  refute Map.has_key?(body, "error")
  assert body["result"]["isError"] == true

  diagnostic =
    body["result"]["content"]
    |> hd()
    |> Map.get("text")
    |> JSON.decode!()

  assert diagnostic["errorType"] == "tool_raised"
  assert diagnostic["tool"] == "crasher"
  assert diagnostic["exception"] == "RuntimeError"
  assert diagnostic["message"] == "boom"
end
```

- [ ] **Step 2: Run the test to confirm it fails**

Run: `mix test test/wymcp/methods/tools_call_test.exs -n "tool raises produce isError"`

Expected: FAIL — current behaviour returns a -32603 protocol error, so `body["error"]` is set and `body["result"]` is missing.

- [ ] **Step 3: Update the rescue clause in `tools_call.ex`**

Open `lib/wymcp/methods/tools_call.ex` and replace the `rescue` block (lines 79-93) with:

```elixir
rescue
  e ->
    duration = System.monotonic_time() - start_time

    Wymcp.Telemetry.emit(:tool, :error, %{duration: duration}, %{
      tool_name: name,
      session_id: ctx.session_id,
      request_id: request["id"],
      exception: inspect(e.__struct__),
      error: Exception.message(e)
    })

    Logger.error("Tool #{name} raised: #{Exception.message(e)}",
      crash_reason: {e, __STACKTRACE__}
    )

    diagnostic = %{
      errorType: "tool_raised",
      tool: name,
      exception: inspect(e.__struct__),
      message: Exception.message(e)
    }

    content = [%{"type" => "text", "text" => JSON.encode!(diagnostic)}]
    send_tool_result(conn, request, tool, content, true)
end
```

`send_tool_result/5` is already in scope and already handles `is_error: true` (see lines 100-112) — it sets `"isError" => true` in the result map and skips structured-content extraction via the existing guard in `maybe_add_structured_content/4`.

- [ ] **Step 4: Run the test to confirm it passes**

Run: `mix test test/wymcp/methods/tools_call_test.exs -n "tool raises produce isError"`

Expected: PASS.

- [ ] **Step 5: Run the full tools_call test file to confirm nothing else regressed**

Run: `mix test test/wymcp/methods/tools_call_test.exs`

Expected: All tests PASS.

- [ ] **Step 6: Update CHANGELOG**

Append to the same `[Unreleased]` (or `[0.3.0]`) section in `CHANGELOG.md`:

```markdown
### Changed

- Tool exceptions in `tools/call` now return a successful JSON-RPC
  response with `isError: true` and a JSON-encoded diagnostic content
  body (`errorType`, `tool`, `exception`, `message`). Previously they
  returned a -32603 protocol error with empty `data`. Per MCP
  2025-11-25, tool-originated errors must be reported as `isError`
  content so the LLM can see and self-correct on them.
```

## Task 3: Structured auth-failure logging and telemetry

`Wymcp.Plugs.Auth` currently logs nothing on the expected `{:error, message}` rejection branch (lines 43-52) and logs only the auth module name + exception message on rescue (line 55). Add structured `Logger` metadata and emit telemetry events so consumers can answer "is this user being repeatedly 401'd, and why?" without grepping production logs.

**Files:**
- Modify: `lib/wymcp/plugs/auth.ex` (entire file rewrite, ~70 → ~110 lines)
- Modify: `lib/wymcp/telemetry.ex` (document new events in `@moduledoc`)
- Create: `test/wymcp/plugs/auth_test.exs`

- [ ] **Step 1: Create the auth-plug test file**

Create `test/wymcp/plugs/auth_test.exs`. Note `async: false` — telemetry handlers attach globally and would otherwise leak across concurrent test modules using the same event name.

```elixir
defmodule Wymcp.Plugs.AuthTest do
  use ExUnit.Case, async: false

  @moduledoc """
  Tests for the `Wymcp.Plugs.Auth` plug.

  The plug owns three responsibilities: dispatching to the configured
  `c:Wymcp.Auth.authenticate/1` callback, returning a spec-compliant
  401 with `WWW-Authenticate: Bearer` on rejection, and emitting
  telemetry + structured logs so consumers can attribute auth-failure
  spikes.

  The previous plug logged nothing on the expected rejection branch.
  Tests here pin the structured-logging contract: a `[:wymcp, :auth,
  :reject]` event on `{:error, _}` and a `[:wymcp, :auth, :error]`
  event on rescue. Failure of these tests means the wire still works
  but observability has regressed.

  This module runs `async: false` because telemetry handler
  attachments are global — concurrent modules attaching to the same
  event would see each other's emissions.
  """

  import ExUnit.CaptureLog
  import Plug.Test
  import Plug.Conn

  alias Wymcp.Plugs.Auth

  defmodule RejectingAuth do
    @behaviour Wymcp.Auth
    def authenticate(_conn), do: {:error, "Invalid token"}
  end

  defmodule RaisingAuth do
    @behaviour Wymcp.Auth
    def authenticate(_conn), do: raise("boom")
  end

  defp build_conn(auth_module) do
    body = %{"jsonrpc" => "2.0", "id" => 42, "method" => "tools/call"}

    conn(:post, "/")
    |> put_req_header("content-type", "application/json")
    |> Map.put(:body_params, body)
    |> assign(:wymcp, %{auth: auth_module})
  end

  describe "rejection path" do
    test "returns 401 with WWW-Authenticate: Bearer" do
      conn = build_conn(RejectingAuth) |> Auth.call([])

      assert conn.status == 401
      assert get_resp_header(conn, "www-authenticate") == ["Bearer"]
    end

    @tag doc: """
    Pins the JSON-RPC error contract: code -32600, the rejection
    message echoed under `data.error`, and the request id preserved
    so clients can correlate. A failure here breaks every existing
    Wymcp client that surfaces auth errors to the user.
    """
    test "JSON-RPC body carries -32600 and the rejection message" do
      conn = build_conn(RejectingAuth) |> Auth.call([])
      body = JSON.decode!(conn.resp_body)

      assert body["id"] == 42
      assert body["error"]["code"] == -32600
      assert body["error"]["data"]["error"] == "Invalid token"
    end

    @tag doc: """
    Verifies the structured-log contract on the expected rejection
    branch. Previous behaviour was silent — operators couldn't
    distinguish "10 rejections from one user" from "one rejection
    repeated 10 times". Failure means the Logger.warning call was
    removed or its metadata keys were renamed.
    """
    test "emits structured Logger.warning with metadata" do
      log =
        capture_log([level: :warning], fn ->
          build_conn(RejectingAuth) |> Auth.call([])
        end)

      assert log =~ "MCP auth rejected"
      assert log =~ "Invalid token"
    end

    @tag capture_log: true
    test "emits [:wymcp, :auth, :reject] telemetry event" do
      ref = make_ref()
      handler_id = "auth-reject-#{inspect(ref)}"

      :telemetry.attach(
        handler_id,
        [:wymcp, :auth, :reject],
        fn _event, _measurements, metadata, _config ->
          send(self(), {:telemetry, ref, metadata})
        end,
        nil
      )

      try do
        build_conn(RejectingAuth) |> Auth.call([])

        assert_received {:telemetry, ^ref, metadata}
        assert metadata.auth_module == RejectingAuth
        assert metadata.reason == "Invalid token"
        assert metadata.request_id == 42
        assert metadata.method == "tools/call"
      after
        :telemetry.detach(handler_id)
      end
    end
  end

  describe "rescue path" do
    @tag capture_log: true
    test "returns 401 when the auth module raises" do
      conn = build_conn(RaisingAuth) |> Auth.call([])

      assert conn.status == 401
      assert get_resp_header(conn, "www-authenticate") == ["Bearer"]
    end

    @tag capture_log: true
    test "emits [:wymcp, :auth, :error] telemetry event with exception class" do
      ref = make_ref()
      handler_id = "auth-error-#{inspect(ref)}"

      :telemetry.attach(
        handler_id,
        [:wymcp, :auth, :error],
        fn _event, _measurements, metadata, _config ->
          send(self(), {:telemetry, ref, metadata})
        end,
        nil
      )

      try do
        build_conn(RaisingAuth) |> Auth.call([])

        assert_received {:telemetry, ^ref, metadata}
        assert metadata.auth_module == RaisingAuth
        assert metadata.exception == "RuntimeError"
        assert metadata.request_id == 42
      after
        :telemetry.detach(handler_id)
      end
    end
  end
end
```

- [ ] **Step 2: Run the new tests to confirm they fail**

Run: `mix test test/wymcp/plugs/auth_test.exs`

Expected: The four "structured logging / telemetry" tests FAIL — current plug emits no telemetry and no warning log. The 401 / WWW-Authenticate / JSON-RPC body assertions should PASS already (existing behaviour).

- [ ] **Step 3: Replace `lib/wymcp/plugs/auth.ex`**

Open `lib/wymcp/plugs/auth.ex` and replace its contents with:

```elixir
defmodule Wymcp.Plugs.Auth do
  @moduledoc """
  Authentication plug for MCP requests.

  Reads the auth module from router opts (`conn.assigns[:wymcp][:auth]`)
  and calls its `c:Wymcp.Auth.authenticate/1` callback. When no auth
  module is configured, defaults to `Wymcp.Auth.Noop` (pass-through).

  On authentication failure, returns HTTP 401 with a
  `WWW-Authenticate: Bearer` header as required by the MCP 2025-11-25
  specification. The response body is a JSON-RPC error with code
  -32600 (Invalid Request).

  ## Observability

  The plug emits two telemetry events alongside the wire response:

  * `[:wymcp, :auth, :reject]` — the auth module returned `{:error,
    reason}`. Metadata includes `auth_module`, `reason`, `request_id`,
    and `method`.
  * `[:wymcp, :auth, :error]` — the auth module raised. Metadata
    includes `auth_module`, `exception`, `error`, `request_id`, and
    `method`.

  Both branches also emit a structured `Logger` line with the same
  metadata so operators without a telemetry handler still get
  attribution.

  ## Related Modules

  See: `Wymcp.Auth`, `Wymcp.Auth.Noop`, `Wymcp.Telemetry`
  """

  require Logger

  import Wymcp.Response
  import Plug.Conn
  alias Wymcp.JsonRpc

  @behaviour Plug

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(%Plug.Conn{} = conn, _opts) do
    auth_module = get_in(conn.assigns, [:wymcp, :auth]) || Wymcp.Auth.Noop
    do_authenticate(conn, auth_module)
  end

  @spec do_authenticate(Plug.Conn.t(), module()) :: Plug.Conn.t()
  defp do_authenticate(conn, auth_module) do
    case auth_module.authenticate(conn) do
      {:ok, conn} ->
        conn

      {:error, message} ->
        log_and_emit_reject(conn, auth_module, message)
        send_unauthorized(conn, message)
    end
  rescue
    e ->
      log_and_emit_error(conn, auth_module, e, __STACKTRACE__)
      send_unauthorized(conn, "Authentication error")
  end

  @spec log_and_emit_reject(Plug.Conn.t(), module(), String.t()) :: :ok
  defp log_and_emit_reject(conn, auth_module, reason) do
    request_id = request_field(conn, "id")
    method = request_field(conn, "method")

    Wymcp.Telemetry.emit(:auth, :reject, %{}, %{
      auth_module: auth_module,
      reason: reason,
      request_id: request_id,
      method: method
    })

    Logger.warning("MCP auth rejected",
      auth_module: inspect(auth_module),
      reason: reason,
      request_id: request_id,
      method: method
    )

    :ok
  end

  @spec log_and_emit_error(Plug.Conn.t(), module(), Exception.t(), Exception.stacktrace()) ::
          :ok
  defp log_and_emit_error(conn, auth_module, exception, stacktrace) do
    request_id = request_field(conn, "id")
    method = request_field(conn, "method")
    exception_class = inspect(exception.__struct__)

    Wymcp.Telemetry.emit(:auth, :error, %{}, %{
      auth_module: auth_module,
      exception: exception_class,
      error: Exception.message(exception),
      request_id: request_id,
      method: method
    })

    Logger.error("MCP auth raised: #{Exception.message(exception)}",
      auth_module: inspect(auth_module),
      exception: exception_class,
      request_id: request_id,
      method: method,
      crash_reason: {exception, stacktrace}
    )

    :ok
  end

  @spec send_unauthorized(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  defp send_unauthorized(conn, reason) do
    request_id = request_field(conn, "id")
    data = %{error: reason}
    response = JsonRpc.error_response(:invalid_request, request_id, data)

    conn
    |> put_resp_header("www-authenticate", "Bearer")
    |> put_status(401)
    |> send_json(response)
  end

  # body_params can be %Plug.Conn.Unfetched{} if Plug.Parsers hasn't run.
  # Guard so the observability path itself doesn't raise.
  @spec request_field(Plug.Conn.t(), String.t()) :: term() | nil
  defp request_field(%Plug.Conn{body_params: %{} = params}, key), do: Map.get(params, key)
  defp request_field(_conn, _key), do: nil
end
```

- [ ] **Step 4: Run the auth-plug tests to confirm they pass**

Run: `mix test test/wymcp/plugs/auth_test.exs`

Expected: All tests PASS.

- [ ] **Step 5: Document the new telemetry events in `Wymcp.Telemetry`**

Open `lib/wymcp/telemetry.ex` and extend the `@moduledoc` event list. After the existing `:tool, :error` block, add:

```
  * `[:wymcp, :auth, :reject]` — auth module returned `{:error, reason}`
    - Measurements: `%{system_time: integer()}`
    - Metadata: `%{auth_module: module(), reason: String.t(),
      request_id: term(), method: String.t() | nil}`

  * `[:wymcp, :auth, :error]` — auth module raised an exception
    - Measurements: `%{system_time: integer()}`
    - Metadata: `%{auth_module: module(), exception: String.t(),
      error: String.t(), request_id: term(),
      method: String.t() | nil}`
```

- [ ] **Step 6: Append to CHANGELOG**

Append to the same `[Unreleased]` (or `[0.3.0]`) section in `CHANGELOG.md`:

```markdown
### Added

- `[:wymcp, :auth, :reject]` and `[:wymcp, :auth, :error]` telemetry
  events from `Wymcp.Plugs.Auth`. See `Wymcp.Telemetry` for metadata
  shape.
- `Wymcp.Plugs.Auth` now emits a structured `Logger.warning` on the
  expected rejection branch and a structured `Logger.error` on the
  rescue branch, both with `auth_module`, `request_id`, and `method`
  metadata.
```

## Task 4: Final verification (wymcp)

- [ ] **Step 1: Run the full test suite**

Run: `mix test`

Expected: All tests PASS. If anything fails, the regression is in this plan — fix before proceeding.

- [ ] **Step 2: Run the formatter and compiler with warnings-as-errors**

Run: `mix format --check-formatted && mix compile --warnings-as-errors`

Expected: Both commands exit 0 with no output.

- [ ] **Step 3: Run dialyzer**

Run: `mix dialyzer`

Expected: No new warnings. The callback signature change in Task 1 may surface unmatched-return warnings if the dispatch threading is wrong — fix at the source rather than adding to `.dialyzer_ignore.exs`.

- [ ] **Step 4: Confirm the CHANGELOG renders the breaking change clearly**

Open `CHANGELOG.md` and visually scan the `[Unreleased]` (or `[0.3.0]`) section. The breaking change must be the first item under `### Changed (BREAKING)` so a consumer skimming the file sees it before the additive items.

---

## Ymer-side migration (run after wymcp Tasks 1–4 land)

`ymer/mix.exs:147` pins wymcp via `path: "../wymcp"`, so this migration runs against the local working copy — no Hex release between the two sides. Until the migration completes, ymer fails to compile against the new wymcp.

The ymer auth plugs already populate `conn.assigns[:current_scope]` (see `lib/ymer/mcp/auth.ex:41` and `lib/ymer/mcp/dev_auth.ex:54`), so the migration is purely callback-side: stop reading from the process dictionary, start reading from `ctx.assigns`.

**Files modified in ymer:**

- `lib/ymer/mcp/tools/events.ex` — three `action_context/N` clauses at lines 43, 62, 68
- `lib/ymer/mcp/tools/docs.ex` — two clauses at lines 42, 51
- `lib/ymer/mcp/tools/projects.ex` — two clauses at lines 43, 59
- `lib/ymer/mcp/auth.ex` — drop `Helpers.put_scope(scope)` at line 40
- `lib/ymer/mcp/dev_auth.ex` — drop `Helpers.put_scope(scope)` at line 53
- `lib/ymer/ai/tool_bridge.ex` — drop `Helpers.put_scope(scope)` at line 76; update moduledoc at lines 21-23
- `lib/ymer/mcp/tools/helpers.ex` — delete `put_scope/1` and `current_scope/0` (lines 10-22)

**Files removed from ymer (test fixtures, if any):** none expected — `grep -rn "put_scope\|current_scope" test/` should return zero hits after the lib changes.

- [ ] **Step 1: Migrate `events.ex`**

In `/Users/kgronber/Projects/ymer/lib/ymer/mcp/tools/events.ex`:

Change line 43-46 from:

```elixir
def action_context(:list) do
  scope = Ymer.Mcp.Tools.Helpers.current_scope()
  ...
```

to:

```elixir
def action_context(:list, ctx) do
  scope = ctx.assigns[:current_scope]
  ...
```

Same shape for `action_context(:create)` at line 62. For the catch-all at line 68, change:

```elixir
def action_context(_action), do: nil
```

to:

```elixir
def action_context(_action, _ctx), do: nil
```

- [ ] **Step 2: Migrate `docs.ex`**

In `/Users/kgronber/Projects/ymer/lib/ymer/mcp/tools/docs.ex`, apply the same shape to `action_context(:search)` at line 42 (this is the original crasher) and the catch-all at line 51.

- [ ] **Step 3: Migrate `projects.ex`**

In `/Users/kgronber/Projects/ymer/lib/ymer/mcp/tools/projects.ex`, apply the same shape to `action_context(:list)` at line 43 and the catch-all at line 59.

- [ ] **Step 4: Drop `Helpers.put_scope` calls**

After Steps 1-3, `current_scope/0` has no callers. Drop the `put_scope/1` calls now so the helper module can be removed in Step 5:

In `lib/ymer/mcp/auth.ex` line 40, delete `Ymer.Mcp.Tools.Helpers.put_scope(scope)`. The `Plug.Conn.assign(conn, :current_scope, scope)` on line 41 is the sole remaining scope-passing mechanism.

In `lib/ymer/mcp/dev_auth.ex` line 53, same deletion.

In `lib/ymer/ai/tool_bridge.ex` line 76, delete `Ymer.Mcp.Tools.Helpers.put_scope(scope)`. The `ctx = %Wymcp.Context{assigns: %{current_scope: scope}}` on line 77 already passes scope through `ctx.assigns`. Also update the `@moduledoc` paragraph at lines 21-23 — drop the "deprecated process dictionary ... is also set for backward compatibility" sentence.

- [ ] **Step 5: Delete `Helpers.put_scope/1` and `current_scope/0`**

In `lib/ymer/mcp/tools/helpers.ex`, delete lines 10-22 (the two deprecated functions and their doc/spec attributes). Verify with:

```bash
grep -rn "put_scope\|current_scope\|mcp_current_scope" /Users/kgronber/Projects/ymer
```

Expected: zero hits in `lib/`. Hits in `test/` mean test fixtures still reference the removed helpers — migrate them the same way.

- [ ] **Step 6: Run the ymer test suite**

Run from `/Users/kgronber/Projects/ymer`: `mix test`

Expected: All tests PASS. If any fail with `No MCP scope set` or `function current_scope/0 is undefined`, a `Helpers.current_scope()` call was missed.

- [ ] **Step 7: Optional — subscribe to the new wymcp auth telemetry events**

If production attribution for auth-rejection spikes is wanted, audit telemetry handlers in `lib/ymer/application.ex` (or wherever `:telemetry.attach_many/4` is configured) and add `[:wymcp, :auth, :reject]` and `[:wymcp, :auth, :error]` to the subscription list. Skip if the project doesn't currently consume any wymcp telemetry events.

- [ ] **Step 8: Smoke-test the end-to-end flow against Claude.ai**

Connect Claude.ai to the running ymer instance, exercise the tools whose `action_context` callbacks were migrated (`docs.search`, `events.list`, `events.create`, `projects.list`), and confirm:

1. Each tool returns content as expected.
2. `Logger` shows no `"No MCP scope set"` raise on the ymer side, and no `function current_scope/0 is undefined` errors.
3. If any unrelated tool happens to raise during the test, the response is a successful JSON-RPC body with `isError: true` (Task 2 behaviour) rather than a -32603 protocol error.

---

## Known issues found during diagnosis (out of scope — separate plans)

While auditing production logs to validate the original "ymer disconnect/reconnect" framing of this plan, two real issues surfaced that this plan does **not** address. They are recorded here so they don't get lost; each warrants its own plan.

### 1. SSE stream owner mismatch under Bandit

Production logs show this warning repeating every time an SSE stream is opened:

```
[warning] Failed to start SSE stream:
  {%RuntimeError{message: "Adapter functions must be called by stream owner"},
   [{Bandit.Adapter, :validate_calling_process!, ...},
    {Bandit.Adapter, :chunk, 2, ...},
    {Plug.Conn, :chunk, 2, ...},
    {Wymcp.Transport.StreamManager, :send_priming_event, 2, line: 205},
    {Wymcp.Transport.StreamManager, :init, 1, line: 129},
    ...]}
```

**Root cause:** Bandit requires `Plug.Conn.chunk/2` (and other adapter functions) to be called from the original request process. `StreamManager.init/1` runs in a freshly-spawned GenServer process, and `send_priming_event/2` calls `chunk/2` from there, so Bandit refuses with `"Adapter functions must be called by stream owner"`. Since Phoenix 1.7+ defaults to Bandit, every SSE stream attempt fails. Clients that depend on server-initiated notifications (`notifications/progress`, `sampling/createMessage`, `elicitation/create`) are degraded or broken.

**Fix shape (for the future plan):** the request process must own the chunked-response lifecycle. Options: (a) keep `StreamManager` but have it send messages back to the request process which performs the actual `chunk/2` calls; (b) restructure so the request process itself drives the SSE event loop and `StreamManager` is just a registry/state holder. Option (b) is the standard Phoenix/Bandit pattern.

**Files:** `lib/wymcp/transport/stream_manager.ex:129,205`, plus the request handler that hands off to it.

### 2. Stale `Mcp-Session-Id` retry storm after server restart

Production logs around the time of the most recent disconnect:

```
09:26:37 [warning] Session not found or expired (id: Y1czsRkIFb...). Operating sessionless.
09:26:40 [warning] Session not found or expired (id: Y1czsRkIFb...). Operating sessionless.
09:26:46 [warning] Session not found or expired (id: Y1czsRkIFb...). Operating sessionless.
09:26:49 [warning] Session not found or expired (id: Y1czsRkIFb...). Operating sessionless.
```

Four retries in 12 seconds with the same stale session ID, after a server restart wiped the in-memory session registry. The wymcp sessionless fallback works at the transport level, but the client (Claude.ai) keeps retrying with the dead session ID rather than re-initializing — eventually visible to the user as broken behaviour requiring manual disconnect/reconnect.

**Fix shape (for the future plan):** when a request arrives with an unknown `Mcp-Session-Id`, return a structured response that signals "session-gone, re-initialize" rather than silently operating sessionless. The MCP spec discusses session lifecycle in `priv/schema.json`; check whether there is a defined response shape (e.g. a specific error code or `_meta` field) clients should receive to trigger re-initialization. Pair with optional session persistence so a graceful restart doesn't lose sessions in the first place.

**Files:** the dispatch path that resolves a session ID to a pid (likely `lib/wymcp/plugs/session.ex` or similar — confirm during implementation), plus session telemetry.

---

## Out of scope

- Hex release of wymcp (the local `path:` dependency means no version bump propagation is needed; the version bump in `mix.exs` is hygiene for when a release does happen).
- Reworking the JSON-RPC -32600 code used for auth failures (semantically off — -32600 means "Invalid Request", not "Unauthenticated" — but inherited from existing behaviour and not the focus of this plan).
- Sanitization of `Exception.message/1` content sent over the wire. Tools whose exception messages embed user data (PII, tokens) should not put that data in `raise`'d strings to begin with; tightening this is a separate audit.
- The two known issues documented above (SSE stream owner mismatch, stale-session-id retry storm) — recorded here for traceability but tracked as separate plans.
