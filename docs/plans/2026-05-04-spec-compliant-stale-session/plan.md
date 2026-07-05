# 2026-05-04 Spec-Compliant Stale Session Handling Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace wymcp's silent "operate sessionless" fallthrough on unknown `Mcp-Session-Id` with the MCP 2025-11-25 spec-mandated 404 response. The wire shape branches on message kind so JSON-RPC 2.0 is not violated for non-request traffic: a request gets HTTP 404 + JSON-RPC `-32001` ("Session terminated", matching the official TypeScript SDK exactly); a notification or a response message gets HTTP 404 with empty body (no envelope, since JSON-RPC forbids responding to notifications and to responses).

**Architecture:** The behavioural change is local to `Wymcp.Plugs.Session.session_fallthrough/1`, which becomes `session_terminated/2`. After the change, every message with a session-bearing header that misses the registry is rejected at the plug layer — downstream methods never observe a missing session pid. That promotes `:wymcp_session_pid` to an invariant for all non-exempt methods. Several previously-reachable defensive paths therefore become dead code and are removed in the same plan: the compile-time-tools fallback in `Methods.ToolsList`/`Methods.ToolsCall`, the `_meta.warnings` decoration in both, and the `if session_pid` / `Process.alive?` guards in `Methods.Initialized`, `Methods.Cancelled`, `Methods.DeliverResponse`, and `Methods.ToolsCall.build_context`/`persist_assigns`.

**Current behaviour verified against local ymer (port 4000) on 2026-05-03:**

| Scenario | Current observed | After this plan |
|---|---|---|
| Stale `Mcp-Session-Id` + `tools/list` (request) | HTTP 200, `_meta.warnings` decoration, full tools list | HTTP 404 + JSON-RPC `-32001` "Session terminated" (no `data` field) |
| Stale `Mcp-Session-Id` + `notifications/initialized` (notification) | HTTP 200, `%{}` body | HTTP 404 + empty body |
| Stale `Mcp-Session-Id` + JSON-RPC response message | HTTP 200, `_meta.warnings` decoration | HTTP 404 + empty body |
| No `Mcp-Session-Id` header + `tools/list` | HTTP 400 + JSON-RPC `-32600` "Missing Mcp-Session-Id header" | Unchanged |

The missing-header path is already spec-aligned; only the stale-header path moves.

The spec text driving the change ([MCP 2025-11-25 — Streamable HTTP / Session Management](https://modelcontextprotocol.io/specification/2025-11-25/basic/transports#session-management), clauses 3 and 4):

> 3. The server **MAY** terminate the session at any time, after which it **MUST** respond to requests containing that session ID with HTTP 404 Not Found.
> 4. When a client receives HTTP 404 in response to a request containing an `MCP-Session-Id`, it **MUST** start a new session by sending a new `InitializeRequest` without a session ID attached.

A server-restart-wiped session is, from the spec's perspective, an instance of clause 3. Code `-32001` and message `"Session terminated"` match the official TypeScript SDK exactly — including the absence of a `data` field on the error object — see `packages/server/src/server/streamableHttp.ts` in `modelcontextprotocol/typescript-sdk`, where the SDK throws `new McpError(-32001, "Session terminated")`. Identical wire shape is what claude.ai and other Anthropic-side clients see in production from compliant servers.

**Tech Stack:** Elixir, Plug, ExUnit, ExUnit.CaptureLog. No new dependencies.

Documentation work in this plan must follow the `elixir-documentation-standards` skill.

**Diagram impact:** no change to the architecture-level mermaid in `lib/wymcp/router.ex:56-70` — no new module dependency, no new coordination flow, the router still routes POST through the Pipeline which still contains Session. Inside `Wymcp.Plugs.Session` itself, however, this plan introduces a three-outcome branching contract (pass / 400 / 404, with the 404 sub-branching on message kind) that is non-trivial to read off the function names alone. Task 6 therefore adds a moduledoc-level mermaid flowchart of the plug's own logic — local to the module's documentation, not promoted to the architecture diagrams.

**Breaking change callout:** Wire-level breaking change. Clients that currently rely on wymcp's silent fallthrough (i.e. clients that ignore the spec MUST in clause 4 and keep sending the dead session ID expecting a 200) will get 404 instead. The blast radius covers three consumer surfaces, each verified separately:

  * **claude.ai** — verified end-to-end via Task 8. Per the project's stance, ymer is the product surface and must follow the spec; if claude.ai does not re-initialize cleanly, the rough edge is documented but the change still ships.
  * **Claude Code (the CLI client)** — verified via Task 8b. The auto-memory observation from 2026-03-27 noted Claude Code dropped `Mcp-Session-Id` on `tools/call`; the 2026-05-03 ymer probe confirms the codebase already returns HTTP 400 for missing headers, so a Claude Code that still drops the header is already broken (independent of this plan). This plan only widens the breakage to *stale* headers — relevant only if Claude Code now sends the header.
  * **cai** — internal product surface that re-uses wymcp; will be updated to handle 404 by re-initializing if needed.

A "stateless server" opt-out flag would paper over this; with spec-compliance, no flag is needed unless Task 8/8b verification surfaces unrecoverable client breakage (Outcome D), in which case a follow-up plan adds the flag — do not retrofit it into this plan.

The spec text drives the *status code* in all three cases (404). The *body shape* per message kind is driven by JSON-RPC 2.0: notifications MUST NOT receive a response, and you do not respond to a response. Returning an empty 404 satisfies both the MCP spec MUST-respond-with-404 and the JSON-RPC MUST-NOT-respond rule simultaneously.

**Versioning:** Bump `mix.exs` from `0.3.0` to `0.4.0`. The wire change is observable by any client and warrants a minor bump on a 0.x project (per Semantic Versioning, anything goes pre-1.0, but the project has been bumping minors for breaking changes — consistent with the 0.2 → 0.3 bump in the previous plan).

---

## File Structure

| File | Responsibility in this plan |
|------|----------------------------|
| `lib/wymcp/json_rpc.ex` | Add `:session_not_found` (-32001, `"Session terminated"`) to `@error_type_map` and the `error_type()` union type. Add an `error_response/2` overload that omits the `data` field — used by the request-kind 404 to match the TypeScript SDK exactly. |
| `lib/wymcp/plugs/session.ex` | Replace `session_fallthrough/1` with `session_terminated/2`. The function branches on message kind: request → HTTP 404 + JSON-RPC `-32001` envelope; notification (no `id`) or response message → HTTP 404 with empty body. Emits `[:wymcp, :session, :not_found]` telemetry. Promote `@moduledoc false` to a real `@moduledoc` (with mermaid flow diagram) documenting the session-lifecycle contract this plug implements. |
| `lib/wymcp/session.ex` | Update the `negotiated_version/1` docstring — its path-2 rationale referenced "Claude Code drops the Mcp-Session-Id header on tools/call", a scenario this plug now rejects with 400. |
| `lib/wymcp/telemetry.ex` | Document the new `[:wymcp, :session, :not_found]` event in `@moduledoc` alongside the existing `:session :start` and `:session :expired` entries. |
| `lib/wymcp/methods/tools_list.ex` | Remove `maybe_add_warning/2` (dead). Simplify `resolve_tools/2` — after this change, `:wymcp_session_pid` is always set when this method runs, so the compile-tools fallback is unreachable. |
| `lib/wymcp/methods/tools_call.ex` | Remove `maybe_add_warning/2` (dead). Simplify `resolve_tools/2`. Drop the `if session_pid && Process.alive?(session_pid)` guards in `build_context/1` and `persist_assigns/2` — `:wymcp_session_pid` is now an invariant established by `Plugs.Session`, and `Process.alive?` was a racy guard that masked rather than caught a dead-session bug. |
| `lib/wymcp/methods/initialized.ex` | Drop the `if session_pid do … else send_json(conn, %{}) end` branch. `notifications/initialized` is not session-exempt, so `:wymcp_session_pid` is always set when this method runs. |
| `lib/wymcp/methods/cancelled.ex` | Drop the `session_pid &&` half of the guard around `Session.complete_request/2`. `notifications/cancelled` is not session-exempt, so `:wymcp_session_pid` is always set. |
| `lib/wymcp/methods/deliver_response.ex` | Drop the `if session_pid do … end` guard around `Session.deliver_response/3`. Response messages without a session header are rejected upstream, so `:wymcp_session_pid` is always set on this path. |
| `test/wymcp/plugs/session_test.exs` | Replace the "falls through sessionless" unit test with three new-behaviour tests covering request, notification, and response-message branches. Update `@moduledoc` narrative to drop the sessionless-fallthrough paragraph and add the spec-driven termination paragraph (with per-message-kind body shapes). |
| `test/wymcp/router_test.exs` | Replace the four "stale session" integration tests with new-behavior equivalents. Two assert wire shape (status, code, message); two are deleted (the `_meta.warnings` checks describe behavior that no longer exists). |
| `mix.exs` | Bump `version: "0.3.0"` → `version: "0.4.0"`. |
| `CHANGELOG.md` | Add `[0.4.0]` section documenting the breaking wire change, the new telemetry event, and the consumer-side guidance for cai/ymer/Claude Code. |

Companion skill artifacts are interleaved, not deferred:

- `Wymcp.Plugs.Session` `@moduledoc` upgrade lands in **Task 6**, after the behavioural change is in place so the documented contract matches reality.
- `Wymcp.Plugs.SessionTest` `@moduledoc` narrative update lands alongside the test changes in **Task 4**.
- Every new function ships with a `@spec`. The new error atom is added to the `error_type()` union in `JsonRpc`.

---

## Task 1: Add `:session_not_found` to the JsonRpc error registry

**Files:**
- Modify: `lib/wymcp/json_rpc.ex:4-11` — `@error_type_map` and `@error_types`.
- Modify: `lib/wymcp/json_rpc.ex:22-27` — the `@type error_type` union.

`Wymcp.JsonRpc.error_response/3` is enum-driven. Before the plug can emit `-32001`, the atom has to exist in the registry. Doing this as Task 1 means the plug change in Task 2 has the helper it needs without inline error-tuple plumbing.

- [ ] **Step 1: Extend the error map**

In `lib/wymcp/json_rpc.ex`, replace lines 4-11:

```elixir
  @error_type_map %{
    parse_error: {-32700, "Parse error"},
    invalid_request: {-32600, "Invalid Request"},
    method_not_found: {-32601, "Method not found"},
    invalid_params: {-32602, "Invalid params"},
    internal_error: {-32603, "Internal error"}
  }
  @error_types Map.keys(@error_type_map)
```

with:

```elixir
  @error_type_map %{
    parse_error: {-32700, "Parse error"},
    invalid_request: {-32600, "Invalid Request"},
    method_not_found: {-32601, "Method not found"},
    invalid_params: {-32602, "Invalid params"},
    internal_error: {-32603, "Internal error"},
    session_not_found: {-32001, "Session terminated"}
  }
  @error_types Map.keys(@error_type_map)
```

Both the code (`-32001`) and the message (`"Session terminated"`) match the TypeScript SDK exactly: see `packages/server/src/server/streamableHttp.ts` in `modelcontextprotocol/typescript-sdk`, where the SDK throws `new McpError(-32001, "Session terminated")`. The SDK does not emit a `data` field on this error — neither does wymcp after this plan (handled by the new `error_response/2` overload added in Step 3). Identical wire shape maximises the chance the client-side MUST in spec clause 4 actually fires.

- [ ] **Step 2: Extend the union type**

In `lib/wymcp/json_rpc.ex`, replace lines 22-27:

```elixir
  @type error_type ::
          :parse_error
          | :invalid_request
          | :method_not_found
          | :invalid_params
          | :internal_error
```

with:

```elixir
  @type error_type ::
          :parse_error
          | :invalid_request
          | :method_not_found
          | :invalid_params
          | :internal_error
          | :session_not_found
```

- [ ] **Step 3: Add an `error_response/2` overload that omits the `data` field**

In `lib/wymcp/json_rpc.ex`, add a new clause to `error_response` immediately above the existing 3-arity definition. The TypeScript SDK's `Session terminated` error has no `data` field; the 3-arity helper unconditionally inserts `"data"`, so it cannot express "no data" without a sentinel. A separate 2-arity clause keeps the difference visible at the call site.

Insert before the existing `error_response/3` definition:

```elixir
  @spec error_response(error_type(), term()) :: %{required(String.t()) => term()}
  def error_response(error_type, request_id) when error_type in @error_types do
    {code, message} = Map.get(@error_type_map, error_type)

    %{
      "jsonrpc" => "2.0",
      "id" => request_id,
      "error" => %{
        "code" => code,
        "message" => message
      }
    }
  end
```

Existing call sites continue to use `error_response/3` and continue to emit `data`. Only `session_terminated/2` (Task 2) calls the new 2-arity form.

- [ ] **Step 4: Verify the module still compiles cleanly**

Run: `mix compile --warnings-as-errors`

Expected: no warnings, no errors. Dialyzer's `:underspecs` flag is enabled at `mix.exs:20`; broadening the type union narrows nothing, and the new 2-arity head has its own `@spec`, so no dialyzer churn is expected.

- [ ] **Step 5: Verify formatting**

Run: `mix format --check-formatted`

Expected: exit status 0, no output.

---

## Task 2: Replace `session_fallthrough/1` with spec-compliant 404 (TDD)

**Files:**
- Modify: `test/wymcp/plugs/session_test.exs:93-110` — replace the existing "falls through sessionless when session ID is unknown" test with three new-behaviour tests (request, notification, response).
- Modify: `lib/wymcp/plugs/session.ex:118-131` — replace `session_fallthrough/1` with `session_terminated/2`.
- Modify: `lib/wymcp/plugs/session.ex:59,84` — rename the call sites and pass `session_id` through.

- [ ] **Step 1: Write the failing tests for the three new wire shapes**

In `test/wymcp/plugs/session_test.exs`, replace the existing `test "falls through sessionless when session ID is unknown"` block (currently lines 100-110, with the `@tag doc:` block immediately above at 93-99) with the following three tests. The three branches of `session_terminated/2` are independent and each deserves its own pinning test.

```elixir
  @tag doc: """
       Per MCP 2025-11-25 (Streamable HTTP / Session Management, clauses
       3 and 4), a request bearing an unrecognised Mcp-Session-Id MUST
       be answered with HTTP 404. The body uses JSON-RPC code -32001 and
       message "Session terminated" — matching the TypeScript SDK
       exactly (packages/server/src/server/streamableHttp.ts, where the
       SDK throws `new McpError(-32001, "Session terminated")` with no
       data field). Failure here means we have regressed to the old
       silent fallthrough or drifted off the SDK wire shape.
       """
  test "responds 404 with -32001 'Session terminated' for stale-session request" do
    conn =
      conn(:post, "/")
      |> put_req_header("mcp-session-id", "bogus")
      |> Map.put(:body_params, %{"method" => "tools/list", "id" => 1})
      |> SessionPlug.call(SessionPlug.init([]))

    assert conn.status == 404
    assert conn.halted

    body = JSON.decode!(conn.resp_body)
    assert body["jsonrpc"] == "2.0"
    assert body["id"] == 1
    assert body["error"]["code"] == -32001
    assert body["error"]["message"] == "Session terminated"
    refute Map.has_key?(body["error"], "data")
    refute Map.has_key?(conn.assigns, :wymcp_session_pid)
    refute Map.has_key?(conn.assigns, :wymcp_session_warning)
  end

  @tag doc: """
       JSON-RPC 2.0 forbids responding to notifications. The MCP spec
       still requires HTTP 404 for the stale-session signal, so the
       reconciliation is: 404 status + empty body + no JSON-RPC
       envelope. Returning an envelope with id:null would itself be a
       JSON-RPC violation.
       """
  test "responds 404 with empty body for stale-session notification" do
    conn =
      conn(:post, "/")
      |> put_req_header("mcp-session-id", "bogus")
      |> Map.put(:body_params, %{"method" => "notifications/initialized"})
      |> SessionPlug.call(SessionPlug.init([]))

    assert conn.status == 404
    assert conn.halted
    assert conn.resp_body == ""
    refute Map.has_key?(conn.assigns, :wymcp_session_pid)
  end

  @tag doc: """
       Response messages (client-to-server answers to server-initiated
       requests) carry an `id` referring to a request the server already
       sent. Replying to a response with another JSON-RPC error would
       itself be a JSON-RPC violation — you do not respond to responses.
       HTTP 404 alone is the right signal, with empty body.
       """
  test "responds 404 with empty body for stale-session response message" do
    conn =
      conn(:post, "/")
      |> put_req_header("mcp-session-id", "bogus")
      |> Map.put(:body_params, %{
        "jsonrpc" => "2.0",
        "id" => 42,
        "result" => %{"role" => "assistant"}
      })
      |> assign(:wymcp_message_type, :response)
      |> SessionPlug.call(SessionPlug.init([]))

    assert conn.status == 404
    assert conn.halted
    assert conn.resp_body == ""
    refute Map.has_key?(conn.assigns, :wymcp_session_pid)
  end
```

The `refute Map.has_key?(conn.assigns, :wymcp_session_pid)` lines pin that the new path does not leak the old sessionless assigns — Tasks 5 and 6 rely on those assigns being unreachable. The first test's `refute Map.has_key?(body["error"], "data")` pins the SDK-exact wire shape promised in the verification summary.

- [ ] **Step 2: Run the failing tests to confirm they fail**

Run: `mix test test/wymcp/plugs/session_test.exs` (or restrict to the three new test lines).

Expected: FAIL on all three new tests — the current `session_fallthrough/1` does not halt the conn or send a 404, so `assert conn.status == 404` and `assert conn.halted` both fail.

- [ ] **Step 3: Replace `session_fallthrough/1` with `session_terminated/2`**

In `lib/wymcp/plugs/session.ex`, replace the function definition at lines 118-131:

```elixir
  @spec session_fallthrough(Plug.Conn.t()) :: Plug.Conn.t()
  defp session_fallthrough(conn) do
    session_id = List.first(get_req_header(conn, "mcp-session-id"))

    require Logger

    Logger.warning("Session not found or expired (id: #{session_id}). Operating sessionless.")

    assign(
      conn,
      :wymcp_session_warning,
      "Session not found or expired. Per-session state has been reset."
    )
  end
```

with:

```elixir
  @spec session_terminated(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  defp session_terminated(conn, session_id) do
    request_id = conn.body_params["id"]
    method = conn.body_params["method"]

    Wymcp.Telemetry.emit(:session, :not_found, %{}, %{
      session_id: session_id,
      request_id: request_id,
      method: method
    })

    require Logger

    Logger.info(
      "Session terminated (id: #{session_id}). Returning 404 to prompt client re-initialise."
    )

    if conn.assigns[:wymcp_message_type] == :response or is_nil(request_id) do
      conn
      |> send_resp(404, "")
      |> halt()
    else
      response = JsonRpc.error_response(:session_not_found, request_id)

      conn
      |> put_status(404)
      |> send_json(response)
    end
  end
```

The function is renamed because the new contract is the inverse of the old name: it terminates the request, not falls through. It now takes `session_id` as an explicit parameter — both call sites have already pattern-matched it from the header, so re-extracting via `List.first(get_req_header(...))` would be redundant defensive code (and would force a `String.t() | nil` typing of the metadata even though `nil` cannot occur on this path).

`Logger.info` (not `warning`) because returning 404 to a client that subsequently re-initialises is normal, expected behaviour — not an operator-actionable signal. Operators that want to count session-not-found responses attach to the `[:wymcp, :session, :not_found]` telemetry event — consistent with the `:auth :reject` and `:auth :error` events added in 0.3.0.

**Wire shape per message kind.** The function branches on two conditions, both of which select the empty-body 404:

  * `conn.assigns[:wymcp_message_type] == :response` — set by `Plugs.Classify` on JSON-RPC response messages (client-to-server answers to server-initiated requests). Returning a JSON-RPC error envelope here would itself be a JSON-RPC protocol violation.
  * `is_nil(request_id)` — the body has no `"id"`, so it is a notification. JSON-RPC 2.0 forbids responding to notifications. The 404 status alone carries the spec-required signal.

Otherwise the body is the SDK-exact `{"jsonrpc":"2.0","id":<id>,"error":{"code":-32001,"message":"Session terminated"}}` (no `data` field, courtesy of `error_response/2`).

- [ ] **Step 4: Update both call sites to pass `session_id`**

In `lib/wymcp/plugs/session.ex`, change line 59 from:

```elixir
            session_fallthrough(conn)
```

to:

```elixir
            session_terminated(conn, session_id)
```

and the same change at line 84. Both call sites are inside an outer `case get_req_header(conn, "mcp-session-id") do [session_id] -> ...` block, so `session_id` is already bound in scope.

- [ ] **Step 5: Run the new tests to confirm they pass**

Run: `mix test test/wymcp/plugs/session_test.exs`.

Expected: PASS — all three new tests green, no other test regressed.

- [ ] **Step 6: Compile, format, and dialyzer gate**

Run: `mix compile --warnings-as-errors`
Expected: clean compile.

Run: `mix format --check-formatted`
Expected: exit status 0.

Run: `mix dialyzer`
Expected: no new warnings. The new `session_terminated/1` has a fully-typed return path (`put_status/2 |> send_json/2` returns `Plug.Conn.t()`); running dialyzer here surfaces any `:underspecs` regression while the change is fresh, instead of letting it accumulate until Task 5.

---

## Task 3: Update router integration tests

**Files:**
- Modify: `test/wymcp/router_test.exs:736-826` — the four existing "stale session" tests inside `describe "session-aware routing"`. Two are replaced with new-behaviour equivalents; two are deleted because they assert behaviour that no longer exists (`_meta.warnings`).

After Task 2, all four currently-passing tests in this region break. They have to land green on the new behaviour before merging.

- [ ] **Step 1: Replace the first stale-session test**

In `test/wymcp/router_test.exs`, replace the existing `test "stale session ID falls through to sessionless mode"` (currently lines 741-756, including its `@tag doc:` block at 736-740):

```elixir
    @tag doc: """
         Stale session IDs fall through to sessionless mode instead of
         returning 404. This prevents Claude Desktop from breaking when
         sessions expire. The response succeeds using compile-time tools.
         """
    test "stale session ID falls through to sessionless mode" do
      body = %{"jsonrpc" => "2.0", "id" => 1, "method" => "tools/list"}

      router_opts = [tools: [TestTool]]
      init_opts = Wymcp.Router.init(router_opts)

      conn =
        conn(:post, "/", JSON.encode!(body))
        |> put_req_header("content-type", "application/json")
        |> put_req_header("mcp-session-id", "bogus")
        |> Wymcp.Router.call(init_opts)

      assert conn.status == 200
      resp = JSON.decode!(conn.resp_body)
      assert is_list(resp["result"]["tools"])
    end
```

with:

```elixir
    @tag doc: """
         End-to-end proof that an unknown Mcp-Session-Id on tools/list
         is rejected with the spec-mandated 404 + JSON-RPC -32001 in
         the SDK-exact wire shape (no data field).
         A failure here means either Plugs.Session.session_terminated/2
         no longer halts, or the JsonRpc atom registry was reverted, or
         the 2-arity `error_response/2` was lost.
         The id field is preserved so the client can correlate the
         response with its request.
         """
    test "tools/list with unknown session ID returns 404 + -32001" do
      body = %{"jsonrpc" => "2.0", "id" => 1, "method" => "tools/list"}

      router_opts = [tools: [TestTool]]
      init_opts = Wymcp.Router.init(router_opts)

      conn =
        conn(:post, "/", JSON.encode!(body))
        |> put_req_header("content-type", "application/json")
        |> put_req_header("mcp-session-id", "bogus")
        |> Wymcp.Router.call(init_opts)

      assert conn.status == 404
      resp = JSON.decode!(conn.resp_body)
      assert resp["id"] == 1
      assert resp["error"]["code"] == -32001
      assert resp["error"]["message"] == "Session terminated"
      refute Map.has_key?(resp["error"], "data")
    end
```

- [ ] **Step 2: Replace the third stale-session test (tools/call)**

In the same file, replace `test "stale session ID allows tools/call in sessionless mode"` (currently lines 777-800):

```elixir
    test "stale session ID allows tools/call in sessionless mode" do
      body = %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "tools/call",
        "params" => %{
          "name" => "test_tool",
          "arguments" => %{"action" => "ping"}
        }
      }

      router_opts = [tools: [TestTool]]
      init_opts = Wymcp.Router.init(router_opts)

      conn =
        conn(:post, "/", JSON.encode!(body))
        |> put_req_header("content-type", "application/json")
        |> put_req_header("mcp-session-id", "stale-id")
        |> Wymcp.Router.call(init_opts)

      assert conn.status == 200
      resp = JSON.decode!(conn.resp_body)
      assert resp["result"]["content"]
    end
```

with:

```elixir
    test "tools/call with unknown session ID returns 404 + -32001" do
      body = %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "tools/call",
        "params" => %{
          "name" => "test_tool",
          "arguments" => %{"action" => "ping"}
        }
      }

      router_opts = [tools: [TestTool]]
      init_opts = Wymcp.Router.init(router_opts)

      conn =
        conn(:post, "/", JSON.encode!(body))
        |> put_req_header("content-type", "application/json")
        |> put_req_header("mcp-session-id", "stale-id")
        |> Wymcp.Router.call(init_opts)

      assert conn.status == 404
      resp = JSON.decode!(conn.resp_body)
      assert resp["id"] == 1
      assert resp["error"]["code"] == -32001
      assert resp["error"]["message"] == "Session terminated"
      refute Map.has_key?(resp["error"], "data")
    end
```

- [ ] **Step 3: Delete the two `_meta.warnings` tests**

These tests assert behaviour that no longer exists after Task 5 (the warning decoration is gone). Delete them entirely.

In `test/wymcp/router_test.exs`, delete the test starting at line 758 (`test "stale session includes warning in tools/list response" do`) through its closing `end`, and the test starting at line 802 (`test "stale session includes warning in tools/call response" do`) through its closing `end`. Use exact-match deletion — the surrounding tests in the `describe "session-aware routing"` block stay untouched.

After this step, the `describe "session-aware routing"` block has two of its previous four stale-session tests, in their replaced form.

- [ ] **Step 4: Run the modified router tests**

Run: `mix test test/wymcp/router_test.exs`

Expected: all tests in the file pass. The `describe "session-aware routing"` block runs with two replaced stale-session tests, both green.

- [ ] **Step 5: Compile and format gate**

Run: `mix compile --warnings-as-errors`
Expected: clean compile.

Run: `mix format --check-formatted`
Expected: exit status 0.

---

## Task 4: Update session plug test `@moduledoc` narrative

**Files:**
- Modify: `test/wymcp/plugs/session_test.exs:4-24` — the `@moduledoc` narrative (block runs to the closing `"""` on line 24).

After Task 2, the existing test `@moduledoc` claims "stale or unknown session IDs fall through to sessionless mode with a warning assign" — false. The narrative is the place future readers go first when a test fails, so it has to track the truth.

- [ ] **Step 1: Replace the `@moduledoc`**

In `test/wymcp/plugs/session_test.exs`, replace the current `@moduledoc` (lines 4-24) with:

```elixir
  @moduledoc """
  Tests for the session lookup plug.

  The session plug extracts the Mcp-Session-Id header, looks up the
  session GenServer, resets the idle timer, and stores the pid in
  conn.assigns. Initialize and ping requests are exempt — they don't
  require a session header.

  Non-exempt requests without a valid session header are rejected with
  HTTP 400 (JSON-RPC -32600 invalid_request). This follows the MCP spec:
  "Servers that require a session ID SHOULD respond to requests without
  an MCP-Session-Id header with HTTP 400 Bad Request."

  Non-exempt messages *with* a session header that the registry does
  not recognise are rejected with HTTP 404. This follows the MCP
  2025-11-25 spec, Streamable HTTP / Session Management clauses 3 and
  4: a server MAY terminate a session at any time and MUST then
  respond to requests carrying that ID with 404; the client MUST start
  a new session by issuing a fresh InitializeRequest. A
  server-restart-wiped registry is, from the spec's perspective, an
  instance of clause 3 — there is no "I never saw this ID" branch
  distinct from "I terminated this ID".

  The 404 body branches on JSON-RPC message kind, since JSON-RPC 2.0
  forbids responding to notifications and to responses:

    * Request (`id` present, message-kind not `:response`) — body is
      `{"jsonrpc":"2.0","id":<id>,"error":{"code":-32001,"message":
      "Session terminated"}}`, matching the TypeScript SDK exactly
      (no `data` field).
    * Notification (no `id`) — HTTP 404 with empty body.
    * Response message (`wymcp_message_type == :response`) — HTTP 404
      with empty body.

  After session lookup, the plug validates the MCP-Protocol-Version
  header against the version negotiated during initialize. Missing or
  mismatched headers are rejected with 400. This applies to both
  request messages (via resolve_session) and response messages (via
  resolve_session_for_response).
  """
```

- [ ] **Step 2: Run the file to confirm nothing else broke**

Run: `mix test test/wymcp/plugs/session_test.exs`

Expected: all tests pass.

---

## Task 5: Remove all now-dead session-pid-defensive code

**Files:**
- Modify: `lib/wymcp/methods/tools_list.ex:18-32, 34-40` — drop `maybe_add_warning/2`; simplify `resolve_tools/2`.
- Modify: `lib/wymcp/methods/tools_call.ex` — drop `maybe_add_warning/2` (lines 111-131); simplify `resolve_tools/2` (lines 39-45); drop the `if session_pid && Process.alive?(session_pid)` guard in `build_context/1` (lines 174-181); drop the same guard in `persist_assigns/2` (lines 207-211).
- Modify: `lib/wymcp/methods/initialized.ex:9-19` — drop the `if session_pid do … else send_json(conn, %{}) end` branch.
- Modify: `lib/wymcp/methods/cancelled.ex:9-23` — drop the `session_pid &&` half of the guard.
- Modify: `lib/wymcp/methods/deliver_response.ex:7-26` — drop the `if session_pid do … end` guard around `Session.deliver_response/3`.

After Task 2, none of these methods can be reached without `:wymcp_session_pid` set on `conn.assigns` — every non-exempt method goes through `Plugs.Session`, which now rejects (with 400 or 404) any request that lacks a valid session. The previous code carried four compensating-branch patterns, all now unreachable:

1. `resolve_tools/2` falling back to compile-time tools when no session pid was assigned (`tools_list.ex`, `tools_call.ex`).
2. `maybe_add_warning/2` decorating results with `_meta.warnings` when `:wymcp_session_warning` was assigned (`tools_list.ex`, `tools_call.ex`).
3. `if session_pid && Process.alive?(session_pid)` guards (`tools_call.build_context/1`, `tools_call.persist_assigns/2`). The `Process.alive?` half is racy regardless — even after the check, the pid can die before the next call. With the invariant established upstream, dropping the guard makes the contract explicit and surfaces real dead-session bugs as crashes rather than silently no-oping.
4. `if session_pid` guards around session-state mutation (`initialized.ex`, `cancelled.ex`, `deliver_response.ex`). Same reasoning — the guard hides the fact that the method now requires a session, and a dead-session edge case is better as a crash than a silent miss.

Removing all four patterns in one task prevents the next person from re-introducing the workaround pattern by accident.

**Test coverage note:** there is no `test/wymcp/methods/tools_list_test.exs` today, so the only coverage for `Methods.ToolsList.run/2` is at the router level (`router_test.exs`) and via `runtime_tools_test.exs`. `tools_call`, `initialized`, `cancelled`, `deliver_response`, and `logging_set_level` all have unit tests in `test/wymcp/methods/` that already pre-seed `:wymcp_session_pid` in conn.assigns — no test rewrites should be needed. If a test fails because it called the method without a session pid in assigns, the test was actually exercising the now-removed workaround — set up a session first, the same way the rest of the suite does.

- [ ] **Step 1: Simplify `tools_list.ex`**

In `lib/wymcp/methods/tools_list.ex`, replace the entire current file content with:

```elixir
defmodule Wymcp.Methods.ToolsList do
  @moduledoc false

  import Wymcp.Response
  alias Wymcp.{JsonRpc, ProtocolVersion, Session}

  @spec run(Plug.Conn.t(), [module()]) :: Plug.Conn.t()
  def run(%Plug.Conn{} = conn, _compile_tools) do
    request = conn.body_params
    tools = Session.get_tools(conn.assigns[:wymcp_session_pid])
    version = Session.negotiated_version(conn)

    tool_definitions =
      tools
      |> Enum.map(& &1.definition())
      |> Enum.map(&ProtocolVersion.strip_tool_definition(&1, version))

    response = JsonRpc.success_response(request["id"], %{tools: tool_definitions})
    send_json(conn, response)
  end
end
```

The `compile_tools` parameter remains in the signature (renamed to `_compile_tools`) because `Plugs.Dispatch` passes it positionally. Removing the parameter is a separate, larger refactor (Dispatch and the router contract) and out of scope for this plan.

- [ ] **Step 2: Simplify `tools_call.ex`**

In `lib/wymcp/methods/tools_call.ex`, two small edits:

**Edit A — replace `resolve_tools/2`** (currently lines 39-45):

```elixir
  @spec resolve_tools(Plug.Conn.t(), [module()]) :: [module()]
  defp resolve_tools(conn, compile_tools) do
    case conn.assigns[:wymcp_session_pid] do
      nil -> compile_tools
      pid -> Session.get_tools(pid)
    end
  end
```

with:

```elixir
  @spec resolve_tools(Plug.Conn.t(), [module()]) :: [module()]
  defp resolve_tools(conn, _compile_tools) do
    Session.get_tools(conn.assigns[:wymcp_session_pid])
  end
```

**Edit B — drop `maybe_add_warning/2` and its call site.**

Replace `send_tool_result/5` (currently lines 111-123):

```elixir
  @spec send_tool_result(Plug.Conn.t(), map(), module(), list(), boolean()) :: Plug.Conn.t()
  defp send_tool_result(conn, request, tool, content, is_error) do
    version = Session.negotiated_version(conn)

    result =
      %{"content" => content, "isError" => is_error}
      |> maybe_add_structured_content(tool, content, is_error)
      |> ProtocolVersion.strip_tool_call_result(version)
      |> maybe_add_warning(conn)

    response = JsonRpc.success_response(request["id"], result)
    send_json(conn, response)
  end
```

with:

```elixir
  @spec send_tool_result(Plug.Conn.t(), map(), module(), list(), boolean()) :: Plug.Conn.t()
  defp send_tool_result(conn, request, tool, content, is_error) do
    version = Session.negotiated_version(conn)

    result =
      %{"content" => content, "isError" => is_error}
      |> maybe_add_structured_content(tool, content, is_error)
      |> ProtocolVersion.strip_tool_call_result(version)

    response = JsonRpc.success_response(request["id"], result)
    send_json(conn, response)
  end
```

Then delete the entire `maybe_add_warning/2` function (currently lines 125-131):

```elixir
  @spec maybe_add_warning(map(), Plug.Conn.t()) :: map()
  defp maybe_add_warning(result, conn) do
    case conn.assigns[:wymcp_session_warning] do
      nil -> result
      warning -> put_in(result, ["_meta"], %{"warnings" => [warning]})
    end
  end
```

**Edit C — drop the `if session_pid && Process.alive?(session_pid)` guard in `build_context/1`** (currently lines 174-181).

Replace:

```elixir
    session_pid = conn.assigns[:wymcp_session_pid]

    session_assigns =
      if session_pid && Process.alive?(session_pid) do
        Session.get_state(session_pid).assigns
      else
        %{}
      end
```

with:

```elixir
    session_pid = conn.assigns[:wymcp_session_pid]
    session_assigns = Session.get_state(session_pid).assigns
```

**Edit D — drop the same guard in `persist_assigns/2`** (currently lines 207-211).

Replace:

```elixir
  @spec persist_assigns(Plug.Conn.t(), map()) :: :ok
  defp persist_assigns(conn, assigns_updates) do
    session_pid = conn.assigns[:wymcp_session_pid]

    if session_pid && Process.alive?(session_pid) do
      Session.put_assigns(session_pid, assigns_updates)
    end

    :ok
  end
```

with:

```elixir
  @spec persist_assigns(Plug.Conn.t(), map()) :: :ok
  defp persist_assigns(conn, assigns_updates) do
    session_pid = conn.assigns[:wymcp_session_pid]
    Session.put_assigns(session_pid, assigns_updates)
    :ok
  end
```

- [ ] **Step 3: Simplify `Methods.Initialized.run/1`**

In `lib/wymcp/methods/initialized.ex`, replace the body of `run/1` (currently lines 9-19):

```elixir
  @spec run(Plug.Conn.t()) :: Plug.Conn.t()
  def run(conn) do
    session_pid = conn.assigns[:wymcp_session_pid]

    if session_pid do
      Session.mark_ready(session_pid)
      invoke_server_init(conn, session_pid)
    else
      send_json(conn, %{})
    end
  end
```

with:

```elixir
  @spec run(Plug.Conn.t()) :: Plug.Conn.t()
  def run(conn) do
    session_pid = conn.assigns[:wymcp_session_pid]
    Session.mark_ready(session_pid)
    invoke_server_init(conn, session_pid)
  end
```

`notifications/initialized` is in `@lifecycle_exempt_methods` but not in `@session_exempt_methods`, so the plug already enforces a present session pid.

- [ ] **Step 4: Simplify `Methods.Cancelled.run/1`**

In `lib/wymcp/methods/cancelled.ex`, replace the body of `run/1` (currently lines 9-23):

```elixir
  @spec run(Plug.Conn.t()) :: Plug.Conn.t()
  def run(conn) do
    params = conn.body_params["params"] || %{}
    request_id = params["requestId"]
    reason = params["reason"] || "cancelled"
    session_pid = conn.assigns[:wymcp_session_pid]

    if session_pid && request_id do
      Session.complete_request(session_pid, request_id)
      Logger.info("Request #{request_id} cancelled: #{reason}")
    end

    send_json(conn, %{})
  end
```

with:

```elixir
  @spec run(Plug.Conn.t()) :: Plug.Conn.t()
  def run(conn) do
    params = conn.body_params["params"] || %{}
    request_id = params["requestId"]
    reason = params["reason"] || "cancelled"
    session_pid = conn.assigns[:wymcp_session_pid]

    if request_id do
      Session.complete_request(session_pid, request_id)
      Logger.info("Request #{request_id} cancelled: #{reason}")
    end

    send_json(conn, %{})
  end
```

The `request_id` half of the guard is genuine input validation (the params field is optional in the wire schema) and stays. Only the `session_pid &&` defensive half is dropped.

- [ ] **Step 5: Simplify `Methods.DeliverResponse.run/1`**

In `lib/wymcp/methods/deliver_response.ex`, replace the body of `run/1` (currently lines 7-26):

```elixir
  @spec run(Plug.Conn.t()) :: Plug.Conn.t()
  def run(conn) do
    body = conn.body_params
    request_id = body["id"]
    session_pid = conn.assigns[:wymcp_session_pid]

    result_or_error =
      cond do
        Map.has_key?(body, "result") -> {:ok, body["result"]}
        Map.has_key?(body, "error") -> {:error, body["error"]}
      end

    if session_pid do
      Session.deliver_response(session_pid, request_id, result_or_error)
    end

    conn
    |> send_resp(202, "")
    |> halt()
  end
```

with:

```elixir
  @spec run(Plug.Conn.t()) :: Plug.Conn.t()
  def run(conn) do
    body = conn.body_params
    request_id = body["id"]
    session_pid = conn.assigns[:wymcp_session_pid]

    result_or_error =
      cond do
        Map.has_key?(body, "result") -> {:ok, body["result"]}
        Map.has_key?(body, "error") -> {:error, body["error"]}
      end

    Session.deliver_response(session_pid, request_id, result_or_error)

    conn
    |> send_resp(202, "")
    |> halt()
  end
```

The plug's `resolve_session_for_response/1` path enforces session presence on response messages: missing header → 400, stale → 404. So `:wymcp_session_pid` is set on every code path that reaches this method.

- [ ] **Step 6: Run the full suite**

Run: `mix test`

Expected: all tests pass. The router and session-plug tests modified in Tasks 3 and 4 must stay green; nothing in `tools_list`, `tools_call`, `initialized`, `cancelled`, or `deliver_response` tests should have asserted on the deleted `_meta.warnings` shape or relied on the removed defensive branches (the `_meta.warnings` assertions only existed in `router_test.exs` and were already deleted in Task 3; the defensive branches were unreachable when test setup was correct).

If a test fails because it called a method without a session pid in assigns, the test was actually exercising the now-removed workaround — set up a session first, the same way the rest of the suite does. Quick way to find such tests: `grep -rn "ToolsList.run\|ToolsCall.run\|Initialized.run\|Cancelled.run\|DeliverResponse.run" test/`.

- [ ] **Step 7: Run dialyzer to surface any unmatched returns**

Run: `mix dialyzer`

Expected: no new warnings. The first run after touching this many modules may take longer if dialyzer rebuilds derived PLT entries; subsequent runs are fast. `:unmatched_returns` is enabled, so the dropped `if session_pid` blocks (which previously squashed `Session.deliver_response/3`'s return) need their replacements to either bind the result with `_ =` or have a `:ok`-returning spec on the called function. `Session.complete_request/2`, `Session.deliver_response/3`, and `Session.put_assigns/2` already return `:ok`; verify their specs match.

- [ ] **Step 8: Compile and format gate**

Run: `mix compile --warnings-as-errors`
Expected: clean compile.

Run: `mix format --check-formatted`
Expected: exit status 0.

---

## Task 6: Promote `Wymcp.Plugs.Session` `@moduledoc` and update related docstrings

**Files:**
- Modify: `lib/wymcp/plugs/session.ex:1-2` — replace `@moduledoc false` with a real moduledoc.
- Modify: `lib/wymcp/session.ex:196-215` — update the `negotiated_version/1` docstring; its path-2 rationale ("Claude Code drops the Mcp-Session-Id header on tools/call but still sends the protocol-version one") describes a scenario that now hits 400 from `Plugs.Session.missing_session_header/1`, not this fallback.
- Modify: `lib/wymcp/telemetry.ex` — document the new `[:wymcp, :session, :not_found]` event in `@moduledoc`.

The plug now implements a non-trivial spec contract that future readers and code-reviewing LLMs need context for. `@moduledoc false` was justifiable when the behaviour was "look up a session, fall through if not found" (mostly self-evident from the function names); with the spec-mandated 404 path now in place, the design decisions deserve to be written down.

This task lands after the behavioural change so the documented contract describes reality, not intent.

- [ ] **Step 1: Replace the `@moduledoc false` with a documented `@moduledoc`**

In `lib/wymcp/plugs/session.ex`, replace lines 1-2:

```elixir
defmodule Wymcp.Plugs.Session do
  @moduledoc false
```

with:

```elixir
defmodule Wymcp.Plugs.Session do
  @moduledoc """
  Resolves the MCP session for an incoming request and enforces the
  spec-mandated lifecycle.

  Three outcomes per request:

    * **Session header present and registered** — assigns
      `:wymcp_session_pid` and `:wymcp_session_id`, calls `Session.touch/1`,
      and validates the `MCP-Protocol-Version` header against the
      version pinned at `initialize` time. Downstream methods read
      tools from the session pid, not from compile-time options.

    * **Session header missing on a non-exempt method** — rejects
      with HTTP 400 + JSON-RPC -32600 (`invalid_request`). Per the
      MCP 2025-11-25 spec: "Servers that require a session ID SHOULD
      respond to requests without an `MCP-Session-Id` header with
      HTTP 400 Bad Request."

    * **Session header present but not registered** — rejects with
      HTTP 404. Per the MCP 2025-11-25 spec, Streamable HTTP / Session
      Management clauses 3 and 4: a server MAY terminate a session at
      any time and MUST then respond to requests carrying that ID
      with 404; the client MUST issue a fresh `InitializeRequest`. A
      server-restart-wiped in-memory registry is an instance of
      clause 3 — the spec does not distinguish "I never saw this ID"
      from "I terminated this ID".

  ### Flow

  ```mermaid
  flowchart TD
      A[Incoming POST] --> B{Mcp-Session-Id<br/>required?}
      B -->|"no — initialize / ping"| Pass([pass through<br/>to next plug])
      B -->|yes| C{Header present?}
      C -->|no| R400([HTTP 400<br/>JSON-RPC -32600<br/>invalid_request])
      C -->|yes| D{Session.lookup}
      D -->|"{:ok, pid}"| E[assign pid<br/>+ touch<br/>+ check version<br/>+ lifecycle gate] --> Pass
      D -->|":not_found"| F{Message kind?}
      F -->|"request<br/>(has id)"| R404Body([HTTP 404<br/>JSON-RPC -32001<br/>'Session terminated'<br/>no data field])
      F -->|notification or<br/>response message| R404Empty([HTTP 404<br/>empty body])
  ```

  ### Exemptions

    * `initialize` and `ping` skip session lookup entirely
      (`@session_exempt_methods`).
    * `tools/list`, `tools/call`, `notifications/initialized`, and the
      two exempt methods above also skip the lifecycle gate
      (`@lifecycle_exempt_methods`) — they are allowed to run while a
      session is still in `:initializing`. This is necessary because
      clients (notably `mcp-remote`) send `tools/list` and
      `tools/call` concurrently with `notifications/initialized`.

  ### Wire shape for session-not-found

  The 404 body branches on JSON-RPC message kind, since JSON-RPC 2.0
  forbids responding to notifications and to responses:

    * **Request** (`id` present, `wymcp_message_type` not `:response`)
      — body is `{"jsonrpc":"2.0","id":<request-id>,"error":{"code":
      -32001,"message":"Session terminated"}}`, matching the
      TypeScript SDK exactly: see
      `modelcontextprotocol/typescript-sdk`,
      `packages/server/src/server/streamableHttp.ts`, where the SDK
      throws `new McpError(-32001, "Session terminated")` with no
      `data` field. Matching that wire shape exactly maximises the
      chance compliant clients (which MUST re-initialise on this
      response) recognise it.

    * **Notification** (no `id`) — HTTP 404 with empty body. JSON-RPC
      2.0 forbids responding to notifications, so we do not emit an
      envelope. The 404 status alone carries the spec-required
      signal.

    * **Response message** (`wymcp_message_type == :response`) — HTTP
      404 with empty body. A JSON-RPC response carries an `id` of a
      server-initiated request the server already sent; replying to
      it with a JSON-RPC error would itself be a protocol violation.

  ## Related Modules

  See: `Wymcp.Session`, `Wymcp.JsonRpc`, `Wymcp.ProtocolVersion`,
  `Wymcp.Plugs.Pipeline`.

  ## Tests

  See: `test/wymcp/plugs/session_test.exs`.
  """
```

- [ ] **Step 2: Update `negotiated_version/1` docstring**

In `lib/wymcp/session.ex`, replace the resolution-order paragraph in the `@doc` block (currently lines 200-210) — the existing path-2 description references a scenario that now produces HTTP 400, not a sessionless fallback. Replace:

```elixir
  Resolution order:

  1. The session pid stored in `conn.assigns[:wymcp_session_pid]` (the
     authoritative case — this is the version negotiated during the
     `initialize` handshake and pinned on the session).
  2. The `MCP-Protocol-Version` request header, when no session pid is
     present (sessionless fallback — Claude Code drops the
     `Mcp-Session-Id` header on `tools/call` but still sends the
     protocol-version one). Only honoured when the header value is in
     `Wymcp.ProtocolVersion.supported/0`.
  3. `Wymcp.ProtocolVersion.latest/0` as a last resort.
```

with:

```elixir
  Resolution order:

  1. The session pid stored in `conn.assigns[:wymcp_session_pid]` (the
     authoritative case — pinned at `initialize` time on the session).
  2. The `MCP-Protocol-Version` request header. After
     `Wymcp.Plugs.Session` enforces session presence on non-exempt
     methods, this branch is reached only by `Methods.Initialize`
     itself, where no session pid exists yet. Honoured only when the
     header value is in `Wymcp.ProtocolVersion.supported/0`.
  3. `Wymcp.ProtocolVersion.latest/0` as a last resort.
```

- [ ] **Step 3: Document the new telemetry event**

In `lib/wymcp/telemetry.ex`, after the existing `[:wymcp, :session, :expired]` block (around line 16), insert a new `## Events` entry:

```elixir
  * `[:wymcp, :session, :not_found]` — request bearing an unrecognised
    `Mcp-Session-Id` rejected with HTTP 404
    - Measurements: `%{system_time: integer()}`
    - Metadata: `%{session_id: String.t(), request_id: term() | nil,
      method: String.t() | nil}`
```

The `session_id` is whatever the client sent in the header (always a string on this code path — `session_terminated/2`'s call sites have already pattern-matched the header to a single binary). `request_id` may be nil for notifications. `method` may be nil for response messages.

- [ ] **Step 4: Compile and format gate**

Run: `mix compile --warnings-as-errors`
Expected: clean compile, no doc-related warnings.

Run: `mix format --check-formatted`
Expected: exit status 0.

- [ ] **Step 5: Verify the full suite still passes**

Run: `mix test`

Expected: all tests pass. Documentation changes shouldn't affect tests, but running once after any moduledoc change is cheap insurance against accidentally edited code in the same file.

---

## Task 7: Versioning, CHANGELOG

**Files:**
- Modify: `mix.exs:9` — version bump.
- Modify: `CHANGELOG.md:8` — new `[0.4.0]` section.

- [ ] **Step 1: Bump the version**

In `mix.exs` at line 9, replace:

```elixir
      version: "0.3.0",
```

with:

```elixir
      version: "0.4.0",
```

- [ ] **Step 2: Add the `[0.4.0]` CHANGELOG section**

In `CHANGELOG.md`, immediately after the existing line 7 (the blank line after the Semantic-Versioning paragraph) and before line 8 (the `## [0.3.0]` heading), insert:

```markdown
## [0.4.0]

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
```

The blank line in the existing CHANGELOG between the project's "adheres to Semantic Versioning" paragraph and the `## [0.3.0]` heading is the insertion anchor.

- [ ] **Step 3: Compile and final-format gate**

Run: `mix compile --warnings-as-errors`
Expected: clean compile.

Run: `mix format --check-formatted`
Expected: exit status 0.

Run: `mix test`
Expected: full suite green.

Run: `mix dialyzer`
Expected: no new warnings.

---

## Task 8: Live verification against claude.ai via cai

This task validates the assumption underpinning the whole plan: that claude.ai (the most important real-world client) actually honours the spec MUST in clause 4 and re-initialises on 404. If it does, the change is a clear win. If it doesn't, the change is still the right call (spec-compliance over client-coddling) but the impact for users may be more disruptive than expected.

**Why this is a task and not a pre-merge prerequisite:** the implementer may not have access to the Crosskey network when writing the plan; this is a separate verification step the user can run when they reach a workstation that does. The implementation itself is fully testable via the unit + integration tests in Tasks 2-5.

**Files:** none — this is a runtime-verification task, no code changes.

**Prerequisites:**

- A local cai instance configured to serve MCP at `/mcp` (already true: see `lib/cai_web/router.ex:18-28`).
- `cai/mix.exs` pinning wymcp via `path: "../wymcp"` (already true: line 115).
- claude.ai connected to your cai endpoint (whatever URL/tunnel is in use).
- Crosskey network access (Jira/Confluence/ReqTest tools require it).

- [ ] **Step 1: Recompile cai against the new wymcp**

```sh
cd /Users/kgronber/Projects/cai
mix deps.compile wymcp --force
```

Expected: clean recompile, no warnings.

- [ ] **Step 2: Start cai**

```sh
mix phx.server
```

Expected: phoenix endpoint up, MCP route mounted at `/mcp`.

- [ ] **Step 3: Establish the baseline**

From claude.ai (whatever endpoint cai is exposed on), make a normal tool call that exercises one of the integrations — e.g. ask claude to look up a Jira issue. Confirm the call succeeds. Note in the cai logs the assigned `Mcp-Session-Id`.

Expected: tool call succeeds; logs show a new session created with a generated session ID.

- [ ] **Step 4: Trigger the dead-session condition**

In the cai terminal, `Ctrl-C` twice to stop the server. The in-memory session registry dies with the BEAM.

```sh
mix phx.server
```

cai is back up. The session ID claude.ai cached is now unknown to the server.

- [ ] **Step 5: Provoke the 404 + observe**

From claude.ai, in the same conversation (no manual disconnect/reconnect), ask claude to make another tool call. This forces claude.ai to send a request bearing the dead `Mcp-Session-Id`.

Watch the cai logs **and** the claude.ai chat UI. Record exactly which of these four outcomes occurred:

| Outcome | What you observe in cai logs | What you observe in claude.ai UI |
|---|---|---|
| **A** Silent recovery | One 404 line, then a fresh `initialize` from claude.ai with no session ID, then the tool call succeeds with a new session ID. | The tool call resolves transparently. No user-visible error. |
| **B** Visible-then-recover | One or more 404 lines, then `initialize`, then success. | An error/retry banner appears briefly; next user turn works. |
| **C** Stuck until manual reconnect | One or more 404 lines, no `initialize` follows. Tool call never completes. | An error appears in the chat. Manual disconnect/reconnect on the claude.ai side recovers. |
| **D** Retry storm with no recovery | Repeated 404 lines with the same dead session ID, claude.ai never re-initialises. | The chat is broken until something forces a full reset. |

- [ ] **Step 6: Decide**

Outcomes **A** or **B** — the change is validated end-to-end. The plan is done.

Outcome **C** — the change is still spec-correct and proceeds, but document the rough edge in the CHANGELOG `[0.4.0]` "Changed (BREAKING)" section: *"Note: claude.ai's web client may surface a transient error on the first request after a wymcp restart before re-initialising on the next user turn. This is a client-side gap against MCP 2025-11-25 clause 4 and should resolve as the client matures."*

Outcome **D** — stop. This is the only outcome that should give pause. Open an issue documenting the observed behaviour, link to [LibreChat issue #11868](https://github.com/danny-avila/LibreChat/issues/11868) (which describes the same client-side bug class), and reconvene to decide whether to:

1. Proceed anyway (spec-compliance is non-negotiable; treat the client gap as a reportable bug).
2. Re-introduce a narrowly-scoped lenient mode under an opt-out flag while waiting for the client to catch up.

Decision (1) keeps the plan as written; decision (2) requires a follow-up plan that adds the flag — do **not** attempt to fold it back into this plan.

- [ ] **Step 7: Record the outcome**

Append a one-paragraph "Verification" section to the bottom of this plan file (or its successor in `docs/implemented/` once the plan moves) noting:

- The outcome letter (A / B / C / D).
- The number of 404 lines emitted between Step 4 and resolution.
- Whether claude.ai issued a fresh `initialize` automatically.
- Any user-visible error text.

This record is the artifact that informs the next person hitting the same question.

---

## Task 8b: Live verification against Claude Code via ymer-local

This task is the Claude-Code-specific counterpart to Task 8. The auto-memory `claude_code_mcp_sessions.md` (2026-03-27) recorded that Claude Code drops the `Mcp-Session-Id` header on `tools/call`. Probing local ymer on 2026-05-03 confirmed wymcp's current behaviour returns HTTP 400 for missing headers and HTTP 200 (with `_meta.warnings`) for stale headers. So the Claude-Code-specific blast radius for this plan is precisely:

- **If Claude Code still drops the header on `tools/call`:** zero impact from this plan. It already gets 400.
- **If Claude Code now sends the header (a possible change since 2026-03-27):** the post-restart stale-header case shifts from 200-with-warning to 404; recovery depends on whether Claude Code re-initialises on 404.

This task answers both questions.

**Why this is a task and not a pre-merge prerequisite:** same as Task 8 — the implementer may not have a workstation set up to run Claude Code against local ymer at planning time. The implementation is fully covered by the unit + integration tests in Tasks 2-5; this task validates the real-world client recovery path.

**Files:** none — runtime verification only.

**Prerequisites:**

- Local ymer running at `http://localhost:4000/mcp` (already true: `lib/ymer_web/router.ex:47` mounts `Wymcp.Router` at `/mcp`).
- `ymer/mix.exs` pinning wymcp via `path: "../wymcp"` so the new wymcp build is picked up.
- The `ymer-local` MCP server entry must be visible to Claude Code in the project where you run the test. The user-scope config `/Users/kgronber/.claude.json → projects."/Users/kgronber/Projects/ymer".mcpServers."ymer-local"` already maps it for the ymer project. To run from the wymcp project, either run Claude Code from `/Users/kgronber/Projects/ymer` (recommended — no config drift), or add the same entry to wymcp's project config: `claude mcp add --transport http ymer-local http://localhost:4000/mcp` from `/Users/kgronber/Projects/wymcp`.

- [ ] **Step 1: Recompile ymer against the new wymcp**

```sh
cd /Users/kgronber/Projects/ymer
mix deps.compile wymcp --force
```

Expected: clean recompile, no warnings.

- [ ] **Step 2: Start ymer**

```sh
mix phx.server
```

Expected: phoenix endpoint up at `localhost:4000`, MCP route mounted at `/mcp`.

- [ ] **Step 3: Restart Claude Code so it picks up the ymer-local connection**

If running Claude Code from a session that started before this task, exit and re-launch — MCP connections are bound at startup. After re-launch, confirm:

```sh
claude mcp list
```

Expected output includes `ymer-local: http://localhost:4000/mcp - ✓ Connected`.

- [ ] **Step 4: Establish the baseline + capture session-header behaviour**

In a Claude Code session attached to ymer-local, ask Claude to make a tool call against ymer (e.g. `mcp__ymer-local__docs` with `action: "list"`). In the ymer iex/log output, observe:

1. Does the request carry `Mcp-Session-Id` on `tools/call`? (Tail Phoenix logs or attach a temporary `Plug` logger.)
2. Was a session created on `initialize`? Note the assigned ID.

This single call answers question 1 (header behaviour) regardless of Step 5's outcome:

- **Header present** → continue to Step 5.
- **Header absent** → Claude Code matches the 2026-03-27 memory; the plan does not affect it. Skip Step 5; record the outcome in Step 7. Update `claude_code_mcp_sessions.md` to reflect that wymcp 0.4.0 returns 400 (not silent fallthrough) for missing headers.

- [ ] **Step 5: Trigger the dead-session condition**

In the ymer terminal, `Ctrl-C` twice to stop the server. The in-memory session registry dies.

```sh
mix phx.server
```

ymer is back up. The session ID Claude Code cached (Step 4) is now unknown.

- [ ] **Step 6: Provoke the 404 + observe**

From the same Claude Code session (no manual reconnect), ask Claude to make another tool call against `ymer-local`. Watch ymer logs and the Claude Code chat. Map the outcome to the same A/B/C/D table from Task 8 Step 5.

- [ ] **Step 7: Decide**

Same decision matrix as Task 8 Step 6:

- **A** or **B** — Claude Code recovers; the plan ships as-is.
- **C** — proceeds; add a one-line note to the CHANGELOG `[0.4.0]` "Changed (BREAKING)" section: *"Claude Code (CLI) may surface a transient error on the first tool call after a wymcp restart. The next user turn recovers."*
- **D** — stop. File the issue against Claude Code referencing MCP 2025-11-25 clauses 3-4. Reconvene with the same two options as Task 8 (proceed and treat as upstream bug, or write a follow-up plan adding an opt-out flag).

- [ ] **Step 8: Record the outcome**

Append findings to the same "Verification" section the plan uses for Task 8. Note both clients (claude.ai and Claude Code) and their respective outcomes. Update `claude_code_mcp_sessions.md` to reflect the new wymcp behaviour.

---

## Verification summary

After Task 7 (and assuming Tasks 8 and 8b land outcomes A, B, or C for both clients), the following all hold:

- A **request** with an unrecognised `Mcp-Session-Id` to any non-exempt MCP method returns HTTP 404, `Content-Type: application/json`, with body `{"jsonrpc":"2.0","id":<request-id>,"error":{"code":-32001,"message":"Session terminated"}}`. The `data` field is absent — wire shape matches the TypeScript SDK exactly.
- A **notification** (no `id`) with an unrecognised `Mcp-Session-Id` returns HTTP 404 with empty body and no JSON-RPC envelope.
- A **response message** (`wymcp_message_type == :response`) with an unrecognised `Mcp-Session-Id` returns HTTP 404 with empty body and no JSON-RPC envelope.
- A request without an `Mcp-Session-Id` to a non-exempt method continues to return HTTP 400 with code `-32600` (unchanged).
- `[:wymcp, :session, :not_found]` telemetry fires once per rejected stale-session message, with `session_id` (always a binary), `request_id` (term or nil for notifications), and `method` (string or nil for response messages) metadata.
- `tools/list` and `tools/call` no longer expose a compile-time-tools fallback at runtime; the only path through them sets `:wymcp_session_pid` upstream.
- No response carries `_meta.warnings`; the assign feeding it is never set.
- `Methods.Initialized.run/1`, `Methods.Cancelled.run/1`, `Methods.DeliverResponse.run/1`, `Methods.ToolsCall.build_context/1`, and `Methods.ToolsCall.persist_assigns/2` no longer carry `if session_pid` / `Process.alive?(session_pid)` defensive branches; `:wymcp_session_pid` is now an enforced invariant for all non-exempt methods.
- `Wymcp.JsonRpc` exposes both `error_response/2` (no `data`) and `error_response/3` (with `data`); only `session_terminated/2` calls the 2-arity form.
- `Wymcp.Plugs.Session` has a `@moduledoc` documenting the three-outcome contract with a mermaid flow diagram; the test module's `@moduledoc` mirrors it.
- `Wymcp.Session.negotiated_version/1`'s docstring no longer claims a sessionless-fallthrough path that the plug now rejects.
- `Wymcp.Telemetry`'s `@moduledoc` documents the new `:session :not_found` event.
- `mix compile --warnings-as-errors`, `mix format --check-formatted`, `mix test`, and `mix dialyzer` all pass.
- The auto-memory `claude_code_mcp_sessions.md` is reviewed (and updated, if Task 8b finds Claude Code's behaviour differs from the 2026-03-27 observation).

---

## Verification

### Wire-shape probe against ymer-local (Tasks 2-7 acceptance, 2026-05-05)

Direct curl against `localhost:4000/mcp` (ymer running fresh build of
wymcp 0.4.0) confirmed all four wire shapes:

| Scenario | Expected | Observed |
|---|---|---|
| Stale session + `tools/list` (request) | 404, code -32001, msg "Session terminated", no `data` | ✅ exact match |
| Stale session + `notifications/initialized` (notification) | 404 + empty body | ✅ |
| Stale session + JSON-RPC response message | 404 + empty body | ✅ |
| No session header + `tools/list` | 400 + -32600 (unchanged) | ✅ |

The request-branch response body was exactly
`{"error":{"code":-32001,"message":"Session terminated"},"id":1,"jsonrpc":"2.0"}`
— matching the TypeScript SDK wire shape exactly.

### Task 8b — Claude Code (CLI) recovery, via cai/wymcp 0.4.0 (2026-05-05)

**Outcome: A — silent recovery.**

Procedure:

1. Recompiled cai against the new wymcp; restarted cai (`mix
   phx.server` at `localhost:4002/mcp`).
2. From this Claude Code session, called `mcp__cai__reqtest` with
   `action: "help"` — succeeded; cai created a fresh session and
   the client cached the assigned `Mcp-Session-Id`.
3. User restarted cai (`Ctrl-C × 2`, then `mix phx.server`). The
   wymcp session registry inside cai died with the BEAM, so the
   client's cached session ID became stale.
4. Called `mcp__cai__reqtest help` again. The call returned a
   normal successful result with no error surfaced to the model,
   no banner in the user-facing chat, and no manual reconnect
   needed.

Mapped behaviour: the Claude Code MCP client received the 404 +
-32001 from cai, transparently issued a fresh `InitializeRequest`,
retried the original tool call against the new session, and handed
back the result. This is exactly the spec-compliant client
behaviour required by MCP 2025-11-25 clause 4. The stale-header
path the auto-memory had recorded (Claude Code dropping the
session header on `tools/call` as of 2026-03-27) is no longer
true — Claude Code now both sends the header and auto-recovers on
404. `claude_code_mcp_sessions.md` updated accordingly.

### Task 8 — claude.ai recovery, via cai (NOT YET RUN)

Pending — requires either Crosskey-network access or claude.ai
exposed to the same cai endpoint. Plan ships on the strength of
the Task 8b outcome plus the wire-shape probe; if claude.ai later
surfaces a worse outcome (C or D), follow the Task 8 Step 6
guidance (note in CHANGELOG, or open a follow-up plan for an
opt-out flag).
