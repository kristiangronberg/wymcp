# 2026-04-27 MCP Protocol Version Support

**Goal:** Make wymcp accept the three current MCP protocol revisions (`2025-03-26`, `2025-06-18`, `2025-11-25`) by negotiating per session and gating wire-format fields on the negotiated version, so any spec-compliant client (Zed, mcp-remote, Claude Code, future clients) can complete `initialize` and use tools.

**Architecture:** Introduce two collaborating modules:

1. `Wymcp.ProtocolVersion` — the value layer. Knows which versions are supported, which features were introduced when, and exposes per-feature predicates plus a small `strip_*` family that prunes wire-format fields the negotiated version cannot understand.
2. `Wymcp.Session.negotiated_version/1` — the conn-aware resolver. Returns the version that should drive serialization for the current request. Resolution order: (a) the session's pinned version when a session pid is present in `conn.assigns`; (b) the `MCP-Protocol-Version` request header (Claude Code drops the `Mcp-Session-Id` header but still sends the protocol-version one); (c) `ProtocolVersion.latest/0` as a last-resort fallback.

`Methods.Initialize` accepts any supported version, **echoes it back**, and pins the session to that value. When the client requests an *unsupported* version, the server **counter-proposes** with `ProtocolVersion.latest/0` (per spec — `MUST respond with another protocol version it supports`), instead of the previous `-32602` rejection. `Plugs.Session`, `Methods.ToolsList`, `Methods.ToolsCall`, and `Wymcp.Context.elicit/4` consult the negotiated version through the single `Session.negotiated_version/1` helper and apply `ProtocolVersion.strip_*` to drop fields older clients don't know (`outputSchema`, `structuredContent`, tool `title`, `serverInfo` extended fields). The `MCP-Protocol-Version` HTTP header check is skipped for `2025-03-26` sessions because the header didn't exist before `2025-06-18`. 2024-11-05 is intentionally **out of scope** — it requires the legacy split-endpoint HTTP+SSE transport that wymcp does not implement.

**Tech Stack:** Elixir, Plug, JSV (JSON Schema validation), ExUnit.

**Downstream impact:** No code changes required. `Wymcp.Context.elicit/4` and `Wymcp.Context.sample/3` already short-circuit with `{:error, :not_supported}` when the client has not declared the capability. After this plan ships, consumers only need to bump the `:wymcp` dependency in their `mix.exs` to a release that contains these changes. Tool authors using `output_schema/0` keep working without modification — wymcp strips the field on older sessions and the existing JSON-stringified text content (mandated by the spec for backward compat) carries the same information. One semantic change: an `initialize` request with an unknown version no longer returns `-32602`; it returns success with a counter-proposed version. Consumers that programmatically test for the rejection error must update.

**Diagram impact:** none. (Checklist run: no new domain context, no new schema, no new lifecycle field, no new module-graph edges that the existing per-module flowcharts capture — `ProtocolVersion` is internal plumbing peer to `Wymcp.JsonRpc`, and `Session.negotiated_version/1` is a thin conn-aware helper. Existing diagrams in `Router`, `Session`, `Tool` moduledocs remain accurate.)

---

## File Structure

| Path                                   | Action | Responsibility                                                                                          |
|----------------------------------------|--------|---------------------------------------------------------------------------------------------------------|
| `lib/wymcp/protocol_version.ex`        | Create | Single source of truth: supported list, latest, per-feature predicates, `strip_*` helpers               |
| `test/wymcp/protocol_version_test.exs` | Create | Unit tests for predicates and `strip_*` helpers                                                         |
| `lib/wymcp/session.ex`                 | Modify | Add `negotiated_version/1` (conn-aware: session pid → request header → `latest/0`)                      |
| `lib/wymcp/methods/initialize.ex`      | Modify | Accept any supported version; echo on success; counter-propose on unknown; gate `serverInfo` extensions |
| `lib/wymcp/plugs/session.ex`           | Modify | Skip `MCP-Protocol-Version` header check when negotiated < `2025-06-18`                                 |
| `lib/wymcp/methods/tools_list.ex`      | Modify | Use `Session.negotiated_version/1`; apply `ProtocolVersion.strip_tool_definition/2` per tool            |
| `lib/wymcp/methods/tools_call.ex`      | Modify | Use `Session.negotiated_version/1`; apply `ProtocolVersion.strip_tool_call_result/2`                    |
| `lib/wymcp/context.ex`                 | Modify | `elicit/4` gates on `ProtocolVersion.supports_elicitation?/1` in addition to capability                 |
| `test/wymcp/plugs/session_test.exs`    | Create | First test file for `Plugs.Session`; covers `MCP-Protocol-Version` skip on 03-26 sessions               |
| `test/wymcp/version_matrix_test.exs`   | Create | Per-version integration matrix: initialize → tools/list → tools/call                                    |
| `test/wymcp/router_test.exs`           | Modify | Rewrite "unsupported version" test to assert counter-propose behaviour                                  |
| `docs/mcp-spec-2025-11-25-overview.md` | Modify | Revert §1.2 to spec-compliant rows; add per-feature "since" annotations in §2.1                         |
| `README.md`                            | Modify | Add "Supported MCP protocol versions" section                                                           |

---

## Diagram impact checklist

```
Diagram impact:
[ ] Does this add or remove a domain context?           — no
[ ] Does this add a schema to an existing context?      — no
[ ] Does this add or change a status/lifecycle field?   — no
[ ] Does this add dependencies on new modules?          — yes, but only internal plumbing (ProtocolVersion + Session.negotiated_version/1); existing per-module mermaids do not need updates
[ ] Does this change how a coordinating function flows? — no, flow stays POST → Pipeline → Dispatch → Method
```

`Diagram impact: none.`

---

## Task 1: Create `Wymcp.ProtocolVersion`

**Files:**
- Create: `lib/wymcp/protocol_version.ex`

- [ ] **Step 1: Create the module skeleton**

Create `lib/wymcp/protocol_version.ex` with:

```elixir
defmodule Wymcp.ProtocolVersion do
  @moduledoc """
  Single source of truth for MCP protocol version support.

  wymcp accepts three protocol revisions: `2025-03-26`, `2025-06-18`,
  and `2025-11-25`. The legacy `2024-11-05` revision is intentionally
  unsupported because it predates the Streamable HTTP transport — it
  required a split-endpoint HTTP+SSE transport that this library does
  not implement.

  The module exposes two layers:

  - **Predicates** (`supports_output_schema?/1`, etc.) — boolean gates
    encoding when each MCP wire feature was introduced.
  - **Strip helpers** (`strip_tool_definition/2`, etc.) — pure map
    transforms that remove fields the negotiated version cannot
    understand. Older clients still receive a spec-compliant response;
    the spec mandates additive evolution, so omitting a newer field is
    always safe for an older client.

  Callers resolve the negotiated version via `Wymcp.Session.negotiated_version/1`
  and pass it into a strip helper. This keeps gating logic in one place
  and prevents drift across the four call sites (`Methods.Initialize`,
  `Methods.ToolsList`, `Methods.ToolsCall`, `Wymcp.Context.elicit/4`).

  ## Version → feature matrix

  | Feature                                                   | Since                |
  |-----------------------------------------------------------|----------------------|
  | Streamable HTTP, `Mcp-Session-Id`, tool `annotations`     | `2025-03-26` (floor) |
  | `instructions` field in `InitializeResult`                | `2025-03-26` (floor) |
  | Tool `title`                                              | `2025-06-18`         |
  | `outputSchema` + `structuredContent`                      | `2025-06-18`         |
  | `MCP-Protocol-Version` HTTP header (MUST)                 | `2025-06-18`         |
  | `serverInfo` extensions (`title`, `description`, `websiteUrl`, `icons`) | `2025-06-18` |
  | `elicitation/create`                                      | `2025-06-18`         |
  | URL-mode elicitation, sampling tools, Tasks               | `2025-11-25`         |

  ## Counter-proposal

  When the client requests an unsupported version, the spec requires
  the server to respond with a version it does support (echoing back
  the same `InitializeResult` shape — not a JSON-RPC error). This
  module does not implement that policy; `Methods.Initialize` does.
  `latest/0` exists so that call site has a single canonical fallback.

  ## Related Modules

  See: `Wymcp.Session` (provides the conn-aware resolver
  `negotiated_version/1`), `Wymcp.Methods.Initialize`,
  `Wymcp.Plugs.Session`, `Wymcp.Methods.ToolsList`,
  `Wymcp.Methods.ToolsCall`, `Wymcp.Context`.

  ## Tests

  See: `Wymcp.ProtocolVersionTest`
  """

  @supported ~w(2025-11-25 2025-06-18 2025-03-26)
  @since_2025_06_18 ~w(2025-11-25 2025-06-18)

  @spec supported() :: [String.t(), ...]
  def supported, do: @supported

  @spec latest() :: String.t()
  def latest, do: hd(@supported)

  @spec supported?(String.t() | nil | term()) :: boolean()
  def supported?(version) when is_binary(version), do: version in @supported
  def supported?(_), do: false

  @spec supports_output_schema?(String.t()) :: boolean()
  def supports_output_schema?(version), do: version in @since_2025_06_18

  @spec supports_tool_title?(String.t()) :: boolean()
  def supports_tool_title?(version), do: version in @since_2025_06_18

  @spec supports_protocol_version_header?(String.t()) :: boolean()
  def supports_protocol_version_header?(version), do: version in @since_2025_06_18

  @spec supports_elicitation?(String.t()) :: boolean()
  def supports_elicitation?(version), do: version in @since_2025_06_18

  @spec supports_server_info_extensions?(String.t()) :: boolean()
  def supports_server_info_extensions?(version), do: version in @since_2025_06_18

  @doc """
  Removes tool-definition fields the negotiated version does not
  understand. Used by `Methods.ToolsList` to filter each tool's
  `definition()` map.

  Strips `"outputSchema"` and `"title"` for `2025-03-26`; returns the
  definition unchanged for `2025-06-18` and `2025-11-25`.
  """
  @spec strip_tool_definition(map(), String.t()) :: map()
  def strip_tool_definition(definition, version) do
    definition
    |> maybe_drop("outputSchema", supports_output_schema?(version))
    |> maybe_drop("title", supports_tool_title?(version))
  end

  @doc """
  Removes `tools/call` result fields the negotiated version does not
  understand. Used by `Methods.ToolsCall` after the result map has been
  fully built.

  Strips `"structuredContent"` for `2025-03-26`. The text-content block
  produced by `Wymcp.Context.json/1` carries the same payload, so older
  clients still get the data — just as a JSON-stringified text block.
  """
  @spec strip_tool_call_result(map(), String.t()) :: map()
  def strip_tool_call_result(result, version) do
    maybe_drop(result, "structuredContent", supports_output_schema?(version))
  end

  @doc """
  Removes `serverInfo` fields the negotiated version does not
  understand. Used by `Methods.Initialize` after `serverInfo` has been
  built from `:server_info` router options.

  Strips `"title"`, `"description"`, `"websiteUrl"`, and `"icons"` for
  `2025-03-26` (these were introduced in `2025-06-18`). `"name"` and
  `"version"` remain untouched.

  Note: `instructions` on `InitializeResult` has been part of the spec
  since the `2025-03-26` floor and therefore needs no gating. If the
  supported floor ever drops to `2024-11-05`, revisit this comment.
  """
  @spec strip_server_info(map(), String.t()) :: map()
  def strip_server_info(server_info, version) do
    if supports_server_info_extensions?(version) do
      server_info
    else
      Map.drop(server_info, ["title", "description", "websiteUrl", "icons"])
    end
  end

  @spec maybe_drop(map(), String.t(), boolean()) :: map()
  defp maybe_drop(map, _key, true), do: map
  defp maybe_drop(map, key, false), do: Map.delete(map, key)
end
```

- [ ] **Step 2: Compile to check for warnings**

Run: `mix compile --warnings-as-errors`
Expected: compiles cleanly, no warnings.

---

## Task 2: Unit-test `Wymcp.ProtocolVersion`

**Files:**
- Create: `test/wymcp/protocol_version_test.exs`

- [ ] **Step 1: Write the tests**

Create `test/wymcp/protocol_version_test.exs`:

```elixir
defmodule Wymcp.ProtocolVersionTest do
  use ExUnit.Case, async: true

  @moduledoc """
  Tests for the per-version feature gate and the strip helpers.

  The `supported/0` list is the floor of what wymcp accepts. Adding or
  removing a version here is an intentional API change — every test in
  this file should fail loudly if the list changes by accident.

  Per-feature predicates encode when each MCP wire feature was added.
  These dates come from the official MCP changelogs, not from internal
  conventions:

  - `2025-03-26` introduced Streamable HTTP, `Mcp-Session-Id`, tool
    `annotations`, and the `instructions` field on `InitializeResult`.
    This is wymcp's floor.
  - `2025-06-18` introduced `outputSchema`, `structuredContent`, tool
    `title`, the `MCP-Protocol-Version` HTTP header, the `serverInfo`
    extensions (`title`, `description`, `websiteUrl`, `icons`), and
    elicitation.
  - `2025-11-25` introduced URL-mode elicitation, sampling `tools`,
    and tasks (none of which wymcp implements yet).
  """

  alias Wymcp.ProtocolVersion

  describe "supported/0" do
    test "returns the three current revisions, newest first" do
      assert ProtocolVersion.supported() == ~w(2025-11-25 2025-06-18 2025-03-26)
    end

    test "latest/0 returns the newest entry" do
      assert ProtocolVersion.latest() == "2025-11-25"
    end
  end

  describe "supported?/1" do
    test "returns true for each supported version" do
      for version <- ProtocolVersion.supported() do
        assert ProtocolVersion.supported?(version), "expected #{version} to be supported"
      end
    end

    @tag doc: """
         2024-11-05 is deliberately rejected. It uses a different HTTP
         transport (split-endpoint HTTP+SSE) that wymcp does not
         implement. Accepting the version string would let initialize
         succeed but every subsequent request would behave wrong.
         """
    test "returns false for 2024-11-05" do
      refute ProtocolVersion.supported?("2024-11-05")
    end

    test "returns false for unknown strings and non-binaries" do
      refute ProtocolVersion.supported?("1999-01-01")
      refute ProtocolVersion.supported?("")
      refute ProtocolVersion.supported?(nil)
      refute ProtocolVersion.supported?(:not_a_string)
    end
  end

  for {predicate, label} <- [
        {:supports_output_schema?, "outputSchema/structuredContent"},
        {:supports_tool_title?, "tool title"},
        {:supports_protocol_version_header?, "MCP-Protocol-Version header"},
        {:supports_elicitation?, "elicitation"},
        {:supports_server_info_extensions?, "serverInfo extensions"}
      ] do
    describe "#{predicate}/1 (#{label})" do
      test "true for 2025-06-18 and 2025-11-25" do
        assert apply(ProtocolVersion, unquote(predicate), ["2025-11-25"])
        assert apply(ProtocolVersion, unquote(predicate), ["2025-06-18"])
      end

      test "false for 2025-03-26" do
        refute apply(ProtocolVersion, unquote(predicate), ["2025-03-26"])
      end
    end
  end

  describe "strip_tool_definition/2" do
    @definition %{
      "name" => "demo",
      "description" => "demo",
      "inputSchema" => %{"type" => "object"},
      "outputSchema" => %{"type" => "object"},
      "title" => "Demo Tool",
      "annotations" => %{}
    }

    test "preserves outputSchema and title for 2025-06-18 and 2025-11-25" do
      for version <- ~w(2025-06-18 2025-11-25) do
        assert ProtocolVersion.strip_tool_definition(@definition, version) == @definition
      end
    end

    @tag doc: """
         outputSchema and title were introduced in 2025-06-18. Strict
         older clients may reject definitions that include unknown
         fields, so we must drop them. annotations stays — it is part
         of the 2025-03-26 floor.
         """
    test "drops outputSchema and title for 2025-03-26" do
      stripped = ProtocolVersion.strip_tool_definition(@definition, "2025-03-26")

      refute Map.has_key?(stripped, "outputSchema")
      refute Map.has_key?(stripped, "title")
      assert Map.has_key?(stripped, "annotations")
      assert stripped["name"] == "demo"
      assert stripped["inputSchema"] == %{"type" => "object"}
    end
  end

  describe "strip_tool_call_result/2" do
    @result %{
      "content" => [%{"type" => "text", "text" => "{}"}],
      "isError" => false,
      "structuredContent" => %{"foo" => "bar"}
    }

    test "preserves structuredContent for 2025-06-18 and 2025-11-25" do
      for version <- ~w(2025-06-18 2025-11-25) do
        assert ProtocolVersion.strip_tool_call_result(@result, version) == @result
      end
    end

    test "drops structuredContent for 2025-03-26 but keeps content/isError" do
      stripped = ProtocolVersion.strip_tool_call_result(@result, "2025-03-26")

      refute Map.has_key?(stripped, "structuredContent")
      assert stripped["content"] == @result["content"]
      assert stripped["isError"] == false
    end
  end

  describe "strip_server_info/2" do
    @server_info %{
      "name" => "wymcp-test",
      "version" => "0.0.1",
      "title" => "Wymcp Test",
      "description" => "for tests",
      "websiteUrl" => "https://example.test",
      "icons" => [%{"url" => "https://example.test/icon.png"}]
    }

    test "preserves all fields for 2025-06-18 and 2025-11-25" do
      for version <- ~w(2025-06-18 2025-11-25) do
        assert ProtocolVersion.strip_server_info(@server_info, version) == @server_info
      end
    end

    test "drops title/description/websiteUrl/icons for 2025-03-26" do
      stripped = ProtocolVersion.strip_server_info(@server_info, "2025-03-26")

      assert stripped == %{"name" => "wymcp-test", "version" => "0.0.1"}
    end
  end
end
```

- [ ] **Step 2: Run the tests**

Run: `mix test test/wymcp/protocol_version_test.exs`
Expected: every test PASSES (the module from Task 1 already provides each function exercised here).

---

## Task 3: Add `Session.negotiated_version/1`

**Files:**
- Modify: `lib/wymcp/session.ex`

The serialization layer has four call sites (`Methods.Initialize` builds the response, `Methods.ToolsList` filters definitions, `Methods.ToolsCall` filters results, `Wymcp.Context.elicit/4` gates the request). Each needs the negotiated version. Resolution must handle three cases:

1. A session pid is on `conn.assigns[:wymcp_session_pid]` → ask the session.
2. No session pid (sessionless fallback — Claude Code drops `Mcp-Session-Id` on `tools/call` per `memory/claude_code_mcp_sessions.md`) but the request carries an `MCP-Protocol-Version` header → use the header.
3. Neither → fall back to `ProtocolVersion.latest/0`.

Putting this in one helper avoids the same conditional being implemented (slightly differently) in three method modules.

- [ ] **Step 1: Add the function**

In `lib/wymcp/session.ex`, add the alias for `ProtocolVersion` near the top of the module (alongside the existing `use GenServer`/attribute block — `Session` does not currently use `alias`, so add a fresh `alias Wymcp.ProtocolVersion` line after `use GenServer`):

```elixir
  alias Wymcp.ProtocolVersion
```

Then add `negotiated_version/1` to the public API. Place it directly after `protocol_version/1` (currently around lines 189–192) so the two related accessors sit together:

```elixir
  @doc """
  Returns the protocol version that should drive serialization for the
  current request.

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

  This is the single resolver consulted by `Methods.Initialize`,
  `Methods.ToolsList`, `Methods.ToolsCall`, and `Wymcp.Context.elicit/4`.
  Adding a fourth call site? Use this function — do not re-derive.
  """
  @spec negotiated_version(Plug.Conn.t()) :: String.t()
  def negotiated_version(%Plug.Conn{} = conn) do
    case conn.assigns[:wymcp_session_pid] do
      pid when is_pid(pid) ->
        protocol_version(pid)

      _ ->
        case Plug.Conn.get_req_header(conn, "mcp-protocol-version") do
          [version] ->
            if ProtocolVersion.supported?(version),
              do: version,
              else: ProtocolVersion.latest()

          _ ->
            ProtocolVersion.latest()
        end
    end
  end
```

- [ ] **Step 2: Add a unit test**

Append to `test/wymcp/session_test.exs` (the file already exists for `Wymcp.Session`):

```elixir
  describe "negotiated_version/1" do
    import Plug.Test
    import Plug.Conn

    test "returns the session's pinned version when a session pid is assigned" do
      {:ok, _pid, session_id} =
        Wymcp.Session.start_session(%{
          client_capabilities: %{},
          client_info: %{},
          protocol_version: "2025-03-26",
          tools: [],
          auth: nil,
          server: nil
        })

      {:ok, pid} = Wymcp.Session.lookup(session_id)

      conn =
        :post
        |> conn("/", "")
        |> assign(:wymcp_session_pid, pid)

      assert Wymcp.Session.negotiated_version(conn) == "2025-03-26"
    end

    @tag doc: """
         Sessionless fallback honours the MCP-Protocol-Version request
         header when present and supported. Claude Code drops the
         Mcp-Session-Id header on tools/call but still sends this one.
         """
    test "falls back to the request header when no session pid is present" do
      conn =
        :post
        |> conn("/", "")
        |> put_req_header("mcp-protocol-version", "2025-06-18")

      assert Wymcp.Session.negotiated_version(conn) == "2025-06-18"
    end

    test "falls back to latest/0 when no session pid and no header" do
      conn = conn(:post, "/", "")

      assert Wymcp.Session.negotiated_version(conn) ==
               Wymcp.ProtocolVersion.latest()
    end

    test "ignores an unsupported header value and falls back to latest/0" do
      conn =
        :post
        |> conn("/", "")
        |> put_req_header("mcp-protocol-version", "1999-01-01")

      assert Wymcp.Session.negotiated_version(conn) ==
               Wymcp.ProtocolVersion.latest()
    end
  end
```

If `test/wymcp/session_test.exs` does not yet import `Plug.Test` / `Plug.Conn` at module level, the local imports inside this `describe` block are scoped correctly and won't conflict.

- [ ] **Step 3: Run the new tests**

Run: `mix test test/wymcp/session_test.exs`
Expected: all new tests PASS, all pre-existing tests still PASS.

---

## Task 4: Widen `Methods.Initialize` — accept, echo, counter-propose, gate `serverInfo`

**Files:**
- Modify: `lib/wymcp/methods/initialize.ex`

Three behavioural changes in this task:

1. **Accept and echo** any version in `ProtocolVersion.supported/0` (instead of only `2025-11-25`).
2. **Counter-propose** with `ProtocolVersion.latest/0` for unknown versions, instead of returning `-32602`. The spec says: *"If the server supports the requested protocol version, it MUST respond with the same version. Otherwise, the server MUST respond with another protocol version it supports."* The previous `-32602` rejection was non-compliant — clients are supposed to receive a regular `InitializeResult` and decide whether to disconnect.
3. **Gate `serverInfo` extensions** (`title`, `description`, `websiteUrl`, `icons`) via `ProtocolVersion.strip_server_info/2` so 2025-03-26 sessions don't receive fields they don't recognise. `instructions` does not need gating — see the comment in `Wymcp.ProtocolVersion.strip_server_info/2`.

- [ ] **Step 1: Add a failing integration test for echo behaviour**

Append to `test/wymcp/router_test.exs` inside the existing `describe "initialize"` block (right before the existing `"returns error for unsupported protocol version"` test, which Task 10 will rewrite):

```elixir
    @tag doc: """
         When the client requests a supported version, the server MUST
         echo it back in InitializeResult.protocolVersion. Returning a
         different (e.g. always-latest) value causes spec-strict clients
         like Zed to bail out with "Unsupported protocol version".
         """
    test "echoes the client's requested version when supported" do
      for requested <- ~w(2025-11-25 2025-06-18 2025-03-26) do
        body = %{
          "jsonrpc" => "2.0",
          "id" => 1,
          "method" => "initialize",
          "params" => %{
            "protocolVersion" => requested,
            "capabilities" => %{},
            "clientInfo" => %{"name" => "test", "version" => "1.0"}
          }
        }

        conn = call_router(body)
        resp = JSON.decode!(conn.resp_body)

        assert resp["result"]["protocolVersion"] == requested,
               "expected echo of #{requested}, got #{inspect(resp["result"]["protocolVersion"])}"
      end
    end

    @tag doc: """
         Per spec, when the client requests an unsupported version the
         server MUST respond with one it supports — not a JSON-RPC
         error. The client then decides whether to disconnect.
         """
    test "counter-proposes latest/0 when the requested version is unsupported" do
      body = %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "initialize",
        "params" => %{
          "protocolVersion" => "1999-01-01",
          "capabilities" => %{},
          "clientInfo" => %{"name" => "test", "version" => "1.0"}
        }
      }

      conn = call_router(body)
      resp = JSON.decode!(conn.resp_body)

      assert resp["result"]["protocolVersion"] == Wymcp.ProtocolVersion.latest()
      refute Map.has_key?(resp, "error")
      assert [_session_id] = get_resp_header(conn, "mcp-session-id")
    end
```

- [ ] **Step 2: Run to confirm both new tests fail**

Run: `mix test test/wymcp/router_test.exs --only describe:"initialize"`
Expected:
- `"echoes the client's requested version when supported"` FAILS — current code rejects `2025-06-18` and `2025-03-26` with `-32602`.
- `"counter-proposes latest/0 when the requested version is unsupported"` FAILS — current code returns `-32602` for `1999-01-01`.
- The pre-existing `"returns error for unsupported protocol version"` test still passes (it still asserts the old `-32602` shape — Task 10 rewrites it).

- [ ] **Step 3: Replace the module-attribute version list with a `ProtocolVersion` alias**

In `lib/wymcp/methods/initialize.ex`:

a) Add `ProtocolVersion` to the existing alias. Change:

```elixir
  alias Wymcp.{JsonRpc, Session}
```

to:

```elixir
  alias Wymcp.{JsonRpc, ProtocolVersion, Session}
```

b) Delete the two module-attribute lines (currently lines 8–9):

```elixir
  @supported_versions ["2025-11-25"]
  @latest_version hd(@supported_versions)
```

`Wymcp.ProtocolVersion` is now the single source of truth.

- [ ] **Step 4: Replace `run/1` with the echo + counter-propose flow**

Replace the existing `run/1` body with:

```elixir
  @spec run(Plug.Conn.t()) :: Plug.Conn.t()
  def run(conn) do
    request = conn.body_params
    params = request["params"] || %{}
    wymcp_opts = conn.assigns[:wymcp] || []
    requested_version = params["protocolVersion"]

    negotiated_version =
      if ProtocolVersion.supported?(requested_version) do
        requested_version
      else
        ProtocolVersion.latest()
      end

    do_initialize(conn, request, params, wymcp_opts, negotiated_version)
  end
```

The previous `else` branch (with the `-32602` error response) is gone entirely. Counter-proposal happens by passing `latest/0` as the negotiated version into the same `do_initialize/5` flow that the success path uses — so the client receives a normal `InitializeResult` and can decide whether to disconnect.

- [ ] **Step 5: Pin the session and echo the negotiated version**

In `do_initialize/5`, change the parameter name from `_requested_version` to `negotiated_version` and use it both when starting the session and when building the result:

```elixir
  defp do_initialize(conn, request, params, wymcp_opts, negotiated_version) do
    name = Application.get_env(:wymcp, :name, "MCP Server")
    version = Application.get_env(:wymcp, :version, "1.0.0")

    client_info = params["clientInfo"] || %{}

    {:ok, _pid, session_id} =
      Session.start_session(%{
        client_capabilities: params["capabilities"] || %{},
        client_info: client_info,
        protocol_version: negotiated_version,
        tools: wymcp_opts[:tools] || [],
        auth: wymcp_opts[:auth],
        server: wymcp_opts[:server]
      })
```

Further down, change the `result` map's `"protocolVersion"`:

```elixir
    result = %{
      "capabilities" => capabilities,
      "protocolVersion" => negotiated_version,
      "serverInfo" => server_info
    }
```

- [ ] **Step 6: Gate `serverInfo` extensions on the negotiated version**

Thread the negotiated version into `build_server_info/3` so it can apply `ProtocolVersion.strip_server_info/2`. Change the call site in `do_initialize/5`:

```elixir
    server_info =
      build_server_info(name, version, wymcp_opts[:server_info], negotiated_version)
```

Update the two `build_server_info` clauses. The 4-arity nil-opts clause:

```elixir
  @spec build_server_info(String.t(), String.t(), map() | nil, String.t()) :: map()
  defp build_server_info(name, version, nil, negotiated_version) do
    %{"name" => name, "version" => version}
    |> ProtocolVersion.strip_server_info(negotiated_version)
  end
```

(For nil opts the strip is a no-op since only `name`/`version` are present, but applying it uniformly keeps the contract that *every* `serverInfo` value flows through `strip_server_info/2`.)

The 4-arity map-opts clause:

```elixir
  defp build_server_info(name, version, opts, negotiated_version) when is_map(opts) do
    %{"name" => name, "version" => version}
    |> maybe_put("title", opts[:title])
    |> maybe_put("description", opts[:description])
    |> maybe_put("websiteUrl", opts[:website_url])
    |> maybe_put_icons(opts[:icons])
    |> ProtocolVersion.strip_server_info(negotiated_version)
  end
```

- [ ] **Step 7: Run the new tests, confirm they pass**

Run: `mix test test/wymcp/router_test.exs --only describe:"initialize"`
Expected: the new echo and counter-propose tests PASS. The pre-existing `"returns error for unsupported protocol version"` test still FAILS (it's asserting the old `-32602` shape — Task 10 rewrites it).

- [ ] **Step 8: Run the full suite to surface regressions**

Run: `mix test`
Expected: only the pre-existing `"returns error for unsupported protocol version"` test fails. Any other failure indicates a real regression that must be fixed before continuing.

---

## Task 5: Skip `MCP-Protocol-Version` header check for pre-`2025-06-18` sessions

**Files:**
- Modify: `lib/wymcp/plugs/session.ex` (lines 144–160)
- Create: `test/wymcp/plugs/session_test.exs`

The `MCP-Protocol-Version` HTTP header was introduced in `2025-06-18`. Clients pinned to `2025-03-26` will never send it; enforcing it would 400 their follow-up requests. The current implementation already tolerates an *absent* header, but it rejects any *present-but-mismatched* header — even on a 2025-03-26 session where the header is not part of the contract.

- [ ] **Step 1: Create the test file**

The plugs test directory has no test file for `Plugs.Session` yet. Create `test/wymcp/plugs/session_test.exs`:

```elixir
defmodule Wymcp.Plugs.SessionTest do
  use ExUnit.Case, async: true

  @moduledoc """
  Tests for `Wymcp.Plugs.Session`.

  Most pipeline behaviour is exercised end-to-end in `Wymcp.RouterTest`;
  this file targets the plug-specific behaviours that benefit from
  isolated assertions — currently version-aware enforcement of the
  `MCP-Protocol-Version` header.
  """

  import Plug.Test
  import Plug.Conn

  @router_opts Wymcp.Router.init(tools: [])

  describe "MCP-Protocol-Version header (pre-2025-06-18 sessions)" do
    @tag doc: """
         Sessions negotiated to 2025-03-26 must not be 400'd for
         omitting the MCP-Protocol-Version header. The header is a
         2025-06-18 feature; older clients have no way to send it.
         """
    test "ping after init succeeds without the header for 2025-03-26 sessions" do
      session_id = initialize_with_version("2025-03-26")

      ping_body = %{"jsonrpc" => "2.0", "id" => 99, "method" => "ping"}

      conn =
        :post
        |> conn("/", JSON.encode!(ping_body))
        |> put_req_header("content-type", "application/json")
        |> put_req_header("mcp-session-id", session_id)
        |> Wymcp.Router.call(@router_opts)

      assert conn.status == 200
      resp = JSON.decode!(conn.resp_body)
      assert resp["result"] == %{}
    end

    @tag doc: """
         For 2025-03-26 sessions, even an explicit (incorrect) header
         must NOT trigger a mismatch error — the header is not part of
         that revision's contract.
         """
    test "follow-up succeeds even with stale header for 2025-03-26 sessions" do
      session_id = initialize_with_version("2025-03-26")

      list_body = %{"jsonrpc" => "2.0", "id" => 99, "method" => "tools/list"}

      conn =
        :post
        |> conn("/", JSON.encode!(list_body))
        |> put_req_header("content-type", "application/json")
        |> put_req_header("mcp-session-id", session_id)
        |> put_req_header("mcp-protocol-version", "2025-11-25")
        |> Wymcp.Router.call(@router_opts)

      assert conn.status == 200
    end

    test "mismatched header still rejected on 2025-06-18 sessions" do
      session_id = initialize_with_version("2025-06-18")

      list_body = %{"jsonrpc" => "2.0", "id" => 99, "method" => "tools/list"}

      conn =
        :post
        |> conn("/", JSON.encode!(list_body))
        |> put_req_header("content-type", "application/json")
        |> put_req_header("mcp-session-id", session_id)
        |> put_req_header("mcp-protocol-version", "2025-03-26")
        |> Wymcp.Router.call(@router_opts)

      assert conn.status == 400
    end
  end

  defp initialize_with_version(version) do
    body = %{
      "jsonrpc" => "2.0",
      "id" => 0,
      "method" => "initialize",
      "params" => %{
        "protocolVersion" => version,
        "capabilities" => %{},
        "clientInfo" => %{"name" => "test", "version" => "1.0"}
      }
    }

    conn =
      :post
      |> conn("/", JSON.encode!(body))
      |> put_req_header("content-type", "application/json")
      |> Wymcp.Router.call(@router_opts)

    [session_id] = get_resp_header(conn, "mcp-session-id")
    session_id
  end
end
```

- [ ] **Step 2: Run to confirm the failure mode**

Run: `mix test test/wymcp/plugs/session_test.exs`
Expected:
- `"ping after init succeeds without the header for 2025-03-26 sessions"` PASSES (current code already tolerates a missing header).
- `"follow-up succeeds even with stale header for 2025-03-26 sessions"` FAILS — current code rejects any header that doesn't match the session's pinned version, even on 2025-03-26 sessions.
- `"mismatched header still rejected on 2025-06-18 sessions"` PASSES (regression guard for the unchanged behaviour).

- [ ] **Step 3: Add the version-aware skip**

In `lib/wymcp/plugs/session.ex`, replace the `check_protocol_version/2` function (currently lines 144–160) with a version-aware split:

```elixir
  @spec check_protocol_version(Plug.Conn.t(), pid()) :: Plug.Conn.t()
  defp check_protocol_version(conn, pid) do
    expected = Session.protocol_version(pid)

    if Wymcp.ProtocolVersion.supports_protocol_version_header?(expected) do
      enforce_protocol_version_header(conn, expected)
    else
      conn
    end
  end

  @spec enforce_protocol_version_header(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  defp enforce_protocol_version_header(conn, expected) do
    case get_req_header(conn, "mcp-protocol-version") do
      [^expected] ->
        conn

      [] ->
        # Header absent — allow through. Major clients (Claude Desktop)
        # don't send MCP-Protocol-Version yet.
        conn

      [_wrong] ->
        protocol_version_mismatch(conn)
    end
  end
```

- [ ] **Step 4: Run to confirm all three tests pass**

Run: `mix test test/wymcp/plugs/session_test.exs`
Expected: all three new tests PASS.

- [ ] **Step 5: Run the full suite**

Run: `mix test`
Expected: same set of failures as after Task 4 (only the pre-existing `"returns error for unsupported protocol version"` test, which Task 10 rewrites). No new regressions.

---

## Task 6: Strip `outputSchema` and `title` from `tools/list` definitions

**Files:**
- Modify: `lib/wymcp/methods/tools_list.ex`

The current handler emits the raw `tool.definition()` map. For a `2025-03-26` session, `outputSchema` and `title` are unknown fields. This task uses `Session.negotiated_version/1` (Task 3) and `ProtocolVersion.strip_tool_definition/2` (Task 1) instead of inlining the gating logic.

- [ ] **Step 1: Hoist `@router_opts` to module scope and add the failing test**

Open `test/wymcp/methods/tools_call_output_schema_test.exs`. The existing `@router_opts` attribute is currently scoped inside `describe "structuredContent in tools/call response"` (around line 110). Module attributes in Elixir are module-global, but reading the file is easier when shared attributes live at the top — and the new tests in this task plus Task 7 both need it. **Move** the line:

```elixir
    @router_opts Wymcp.Router.init(tools: [StructuredTool, PlainTool])
```

out of the `describe` block to just below the existing `defmodule PlainTool` block (around line 89), so it sits at module scope where every subsequent `describe` can reference it.

Then **append** the following new `describe` block below the existing `describe "structuredContent in tools/call response"` (so it appears after the `@router_opts` move):

```elixir
  describe "tools/list field gating by negotiated version" do
    @tag doc: """
         outputSchema was introduced in 2025-06-18. A 2025-03-26 client
         does not know the field; sending it can cause strict clients
         to reject the tool definition. The text-content fallback in
         tools/call (the JSON-stringified payload) preserves all the
         information for the client to consume.
         """
    test "omits outputSchema from tools/list when negotiated version is 2025-03-26" do
      session_id = initialize_with_version("2025-03-26")

      list_body = %{"jsonrpc" => "2.0", "id" => 1, "method" => "tools/list"}
      conn = call_with_session(list_body, session_id)
      resp = JSON.decode!(conn.resp_body)

      [structured_def] = Enum.filter(resp["result"]["tools"], &(&1["name"] == "structured"))
      refute Map.has_key?(structured_def, "outputSchema"),
             "expected outputSchema to be stripped for 2025-03-26 session"
    end

    test "includes outputSchema for 2025-06-18 and 2025-11-25 sessions" do
      for version <- ~w(2025-06-18 2025-11-25) do
        session_id = initialize_with_version(version)

        list_body = %{"jsonrpc" => "2.0", "id" => 1, "method" => "tools/list"}
        conn = call_with_session(list_body, session_id)
        resp = JSON.decode!(conn.resp_body)

        [structured_def] = Enum.filter(resp["result"]["tools"], &(&1["name"] == "structured"))

        assert Map.has_key?(structured_def, "outputSchema"),
               "expected outputSchema for #{version} session"
      end
    end
  end

  defp initialize_with_version(version) do
    body = %{
      "jsonrpc" => "2.0",
      "id" => 0,
      "method" => "initialize",
      "params" => %{
        "protocolVersion" => version,
        "capabilities" => %{},
        "clientInfo" => %{"name" => "test", "version" => "1.0"}
      }
    }

    conn =
      :post
      |> conn("/", JSON.encode!(body))
      |> put_req_header("content-type", "application/json")
      |> Wymcp.Router.call(@router_opts)

    [session_id] = get_resp_header(conn, "mcp-session-id")
    session_id
  end

  defp call_with_session(body, session_id) do
    :post
    |> conn("/", JSON.encode!(body))
    |> put_req_header("content-type", "application/json")
    |> put_req_header("mcp-session-id", session_id)
    |> Wymcp.Router.call(@router_opts)
  end
```

- [ ] **Step 2: Run to confirm the new "omits" test fails**

Run: `mix test test/wymcp/methods/tools_call_output_schema_test.exs`
Expected: `"omits outputSchema from tools/list when negotiated version is 2025-03-26"` FAILS — `outputSchema` is currently included for all sessions. `"includes outputSchema for 2025-06-18 and 2025-11-25 sessions"` PASSES.

- [ ] **Step 3: Apply the strip helper**

Replace `lib/wymcp/methods/tools_list.ex` with:

```elixir
defmodule Wymcp.Methods.ToolsList do
  @moduledoc false

  import Wymcp.Response
  alias Wymcp.{JsonRpc, ProtocolVersion, Session}

  @spec run(Plug.Conn.t(), [module()]) :: Plug.Conn.t()
  def run(%Plug.Conn{} = conn, compile_tools) do
    request = conn.body_params
    tools = resolve_tools(conn, compile_tools)
    version = Session.negotiated_version(conn)

    tool_definitions =
      tools
      |> Enum.map(& &1.definition())
      |> Enum.map(&ProtocolVersion.strip_tool_definition(&1, version))

    result =
      %{tools: tool_definitions}
      |> maybe_add_warning(conn)

    response = JsonRpc.success_response(request["id"], result)
    send_json(conn, response)
  end

  @spec maybe_add_warning(map(), Plug.Conn.t()) :: map()
  defp maybe_add_warning(result, conn) do
    case conn.assigns[:wymcp_session_warning] do
      nil -> result
      warning -> put_in(result, [:_meta], %{warnings: [warning]})
    end
  end

  @spec resolve_tools(Plug.Conn.t(), [module()]) :: [module()]
  defp resolve_tools(conn, compile_tools) do
    case conn.assigns[:wymcp_session_pid] do
      nil -> compile_tools
      pid -> Session.get_tools(pid)
    end
  end
end
```

The version resolution and field gating now go through the shared helpers. The local `negotiated_version/1` from the previous draft of this plan is gone — use `Session.negotiated_version/1`.

- [ ] **Step 4: Run to confirm both tests pass**

Run: `mix test test/wymcp/methods/tools_call_output_schema_test.exs`
Expected: all tests in the file PASS.

- [ ] **Step 5: Run the full suite**

Run: `mix test`
Expected: only the pre-known `"returns error for unsupported protocol version"` failure (Task 10) remains.

---

## Task 7: Strip `structuredContent` from `tools/call` results

**Files:**
- Modify: `lib/wymcp/methods/tools_call.ex` (lines 100–109)

`structuredContent` was introduced alongside `outputSchema` in `2025-06-18`. The spec mandates that the JSON payload also be returned as a text-content block for backward compatibility — wymcp already does this via `Context.json/1`, so dropping `structuredContent` for older sessions is safe.

This task keeps `maybe_add_structured_content/4` unchanged (it still always tries to add the field when the tool declares an `output_schema/0`) and applies `ProtocolVersion.strip_tool_call_result/2` as a final pass on the result map. The slight inefficiency of "add then strip" is worth the simplicity: gating logic stays in `ProtocolVersion`, not interleaved with output-schema validation.

- [ ] **Step 1: Add the failing test**

Append to `test/wymcp/methods/tools_call_output_schema_test.exs` inside the existing `describe "structuredContent in tools/call response"` block (the helpers `initialize_with_version/1` and `call_with_session/2` from Task 6 are already in scope at module level):

```elixir
    @tag doc: """
         structuredContent is a 2025-06-18 field. For 2025-03-26
         sessions it must be omitted, but the text content block
         (which carries the same JSON as a stringified payload) must
         remain so the client still has the data.
         """
    test "omits structuredContent for 2025-03-26 sessions but keeps text content" do
      session_id = initialize_with_version("2025-03-26")

      call_body = %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "tools/call",
        "params" => %{"name" => "structured", "arguments" => %{"action" => "run"}}
      }

      conn = call_with_session(call_body, session_id)
      resp = JSON.decode!(conn.resp_body)

      refute Map.has_key?(resp["result"], "structuredContent")
      assert [%{"type" => "text"} | _] = resp["result"]["content"]
    end

    test "includes structuredContent for 2025-06-18 and 2025-11-25 sessions" do
      for version <- ~w(2025-06-18 2025-11-25) do
        session_id = initialize_with_version(version)

        call_body = %{
          "jsonrpc" => "2.0",
          "id" => 1,
          "method" => "tools/call",
          "params" => %{"name" => "structured", "arguments" => %{"action" => "run"}}
        }

        conn = call_with_session(call_body, session_id)
        resp = JSON.decode!(conn.resp_body)

        assert Map.has_key?(resp["result"], "structuredContent"),
               "expected structuredContent for #{version}"
      end
    end
```

- [ ] **Step 2: Run to confirm the new "omits" test fails**

Run: `mix test test/wymcp/methods/tools_call_output_schema_test.exs`
Expected: the new "omits structuredContent" test FAILS — `structuredContent` is currently always included. The "includes structuredContent" test PASSES.

- [ ] **Step 3: Apply the strip helper**

In `lib/wymcp/methods/tools_call.ex`:

a) Add `ProtocolVersion` to the alias line. Change:

```elixir
  alias Wymcp.{Context, JsonRpc, Session}
```

to:

```elixir
  alias Wymcp.{Context, JsonRpc, ProtocolVersion, Session}
```

b) Replace `send_tool_result/5` (currently lines 100–109) with:

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

`maybe_add_structured_content/4` is unchanged — it still adds the field whenever the tool declares an `output_schema/0` and validation succeeds. The strip helper drops the field afterward for `2025-03-26` sessions.

- [ ] **Step 4: Run to confirm all tests pass**

Run: `mix test test/wymcp/methods/tools_call_output_schema_test.exs`
Expected: all tests in the file PASS.

- [ ] **Step 5: Run dialyzer to catch spec drift**

Run: `mix dialyzer`
Expected: no new warnings. (The `send_tool_result/5` spec is unchanged — only its body changed.)

---

## Task 8: Gate `Wymcp.Context.elicit/4` on the negotiated version

**Files:**
- Modify: `lib/wymcp/context.ex`

`elicitation/create` was introduced in `2025-06-18`. Today, `Wymcp.Context.elicit/4` (lib/wymcp/context.ex:286–312) only checks the *declared capability* (`check_capability(pid, "elicitation")`). A spec-confused 2025-03-26 client that incorrectly declared `elicitation` would still drive the method — and so would a tool that calls `elicit` on a session pinned to 2025-03-26.

This task adds a version check in addition to the capability check. The same `:not_supported` error is returned, so existing callers (ymer's task actions already pattern-match `{:error, :not_supported}`) continue to work without changes.

- [ ] **Step 1: Write the failing test**

Append to `test/wymcp/context_test.exs` (the file already exists for `Wymcp.Context`):

```elixir
  describe "elicit/4 negotiated-version gate" do
    @tag doc: """
         elicitation/create was introduced in 2025-06-18. A session
         pinned to 2025-03-26 must reject elicit calls with
         :not_supported, even if the client wrongly declared the
         capability — the method itself does not exist in that revision.
         """
    test "returns :not_supported when session is pinned to 2025-03-26" do
      {:ok, _pid, session_id} =
        Wymcp.Session.start_session(%{
          client_capabilities: %{"elicitation" => %{}},
          client_info: %{},
          protocol_version: "2025-03-26",
          tools: [],
          auth: nil,
          server: nil
        })

      {:ok, pid} = Wymcp.Session.lookup(session_id)

      ctx = %Wymcp.Context{session_pid: pid, request_id: 1}

      assert {:error, :not_supported} =
               Wymcp.Context.elicit(ctx, "Pick one", %{"type" => "object"})
    end
  end
```

- [ ] **Step 2: Run to confirm it fails**

Run: `mix test test/wymcp/context_test.exs`
Expected: the new test FAILS — current code only checks declared capability, which is present in this fixture. It then attempts to push to a non-existent stream and returns `{:error, :no_stream}` instead of `:not_supported`.

- [ ] **Step 3: Add the version gate**

In `lib/wymcp/context.ex`, modify `check_capability/2` (currently lines 314–323) to also consult the negotiated version. Two options — keep them as separate functions for clarity:

```elixir
  @spec check_elicitation_supported(pid()) :: :ok | {:error, :not_supported}
  defp check_elicitation_supported(pid) do
    state = Wymcp.Session.get_state(pid)

    cond do
      not Wymcp.ProtocolVersion.supports_elicitation?(state.protocol_version) ->
        {:error, :not_supported}

      not Map.has_key?(state.client_capabilities, "elicitation") ->
        {:error, :not_supported}

      true ->
        :ok
    end
  end
```

Then in `elicit/4`, swap the existing `check_capability(pid, "elicitation")` call for `check_elicitation_supported(pid)`:

```elixir
  def elicit(%__MODULE__{session_pid: pid}, message, schema, opts) do
    with :ok <- check_elicitation_supported(pid) do
      # ... unchanged
    end
  end
```

Leave `check_capability/2` and the `sample/3` call site unchanged. (Sampling has been part of the spec since the floor — no version gate needed there. If `2024-11-05` ever returns to scope, revisit.)

- [ ] **Step 4: Run to confirm the test passes**

Run: `mix test test/wymcp/context_test.exs`
Expected: the new test PASSES. All pre-existing tests in the file still PASS.

- [ ] **Step 5: Run the full suite**

Run: `mix test`
Expected: only the pre-known `"returns error for unsupported protocol version"` failure (Task 10) remains.

---

## Task 9: Add the per-version integration matrix

**Files:**
- Create: `test/wymcp/version_matrix_test.exs`

This test exists for one purpose: when a developer runs the suite, a failure for a specific version is **immediately** identifiable from the test name. The matrix walks the full handshake-and-call flow for each supported version, exercising every gate this plan introduces.

- [ ] **Step 1: Create the test file**

Create `test/wymcp/version_matrix_test.exs`:

```elixir
defmodule Wymcp.VersionMatrixTest do
  use ExUnit.Case, async: true

  @moduledoc """
  Integration matrix: for every supported protocol version, walk
  initialize → tools/list → tools/call and assert the response shape
  matches what that version expects.

  Each test runs once per version. The version is interpolated into
  the `describe` heading so a failing run prints:

      Wymcp.VersionMatrixTest [protocol version 2025-03-26]
        * test initialize echoes the requested version (FAILED)

  This makes "which version regressed" obvious without inspecting the
  assertion.

  ## Per-version expectations

  - `2025-03-26` (floor): no `MCP-Protocol-Version` header required;
    `outputSchema`, tool `title`, and `structuredContent` MUST NOT
    appear; `serverInfo` extensions are stripped.
  - `2025-06-18`: header required on follow-ups; `outputSchema`,
    `title`, and `structuredContent` SHOULD appear when tools declare
    them; `serverInfo` extensions are kept.
  - `2025-11-25`: same as 06-18 from wymcp's perspective (tasks and
    URL elicitation are out of scope).
  """

  import Plug.Test
  import Plug.Conn

  defmodule MatrixTool do
    @moduledoc false
    use Wymcp.Tool

    @impl true
    def name, do: "matrix"

    @impl true
    def description, do: "A tool used by the version matrix"

    @impl Wymcp.Tool
    def title, do: "Matrix Tool"

    @impl true
    def output_schema do
      %{
        "type" => "object",
        "properties" => %{"value" => %{"type" => "string"}},
        "required" => ["value"]
      }
    end

    @impl true
    def actions do
      %{
        run: %{description: "Run", properties: %{}, required: [], defaults: %{}}
      }
    end

    @impl Wymcp.Tool
    def run_action(:run, _data, _ctx), do: {:ok, %{value: "ok"}}
  end

  @router_opts Wymcp.Router.init(
                 tools: [MatrixTool],
                 server_info: %{
                   title: "Matrix Server",
                   description: "for the version matrix",
                   website_url: "https://example.test"
                 }
               )

  for version <- ~w(2025-11-25 2025-06-18 2025-03-26) do
    describe "protocol version #{version}" do
      @describetag protocol_version: version

      test "initialize echoes the requested version" do
        version = unquote(version)
        conn = init_call(version)
        resp = JSON.decode!(conn.resp_body)

        assert resp["result"]["protocolVersion"] == version
        assert [_session_id] = get_resp_header(conn, "mcp-session-id")
      end

      test "initialize gates serverInfo extensions on the version" do
        version = unquote(version)
        conn = init_call(version)
        resp = JSON.decode!(conn.resp_body)
        server_info = resp["result"]["serverInfo"]

        if Wymcp.ProtocolVersion.supports_server_info_extensions?(version) do
          assert server_info["title"] == "Matrix Server"
          assert server_info["description"] == "for the version matrix"
          assert server_info["websiteUrl"] == "https://example.test"
        else
          refute Map.has_key?(server_info, "title")
          refute Map.has_key?(server_info, "description")
          refute Map.has_key?(server_info, "websiteUrl")
          refute Map.has_key?(server_info, "icons")
        end
      end

      test "tools/list returns the matrix tool" do
        version = unquote(version)
        session_id = init_session(version)

        conn = call_with_session(session_id, version, %{
          "jsonrpc" => "2.0", "id" => 1, "method" => "tools/list"
        })

        resp = JSON.decode!(conn.resp_body)
        assert [defn] = resp["result"]["tools"]
        assert defn["name"] == "matrix"
      end

      test "tools/list outputSchema and title gating matches the version" do
        version = unquote(version)
        session_id = init_session(version)

        conn = call_with_session(session_id, version, %{
          "jsonrpc" => "2.0", "id" => 1, "method" => "tools/list"
        })

        resp = JSON.decode!(conn.resp_body)
        [defn] = resp["result"]["tools"]

        if Wymcp.ProtocolVersion.supports_output_schema?(version) do
          assert Map.has_key?(defn, "outputSchema"),
                 "expected outputSchema for #{version}"
          assert Map.has_key?(defn, "title"),
                 "expected title for #{version}"
        else
          refute Map.has_key?(defn, "outputSchema"),
                 "expected outputSchema to be stripped for #{version}"
          refute Map.has_key?(defn, "title"),
                 "expected title to be stripped for #{version}"
        end
      end

      test "tools/call structuredContent gating matches the version" do
        version = unquote(version)
        session_id = init_session(version)

        conn = call_with_session(session_id, version, %{
          "jsonrpc" => "2.0", "id" => 2, "method" => "tools/call",
          "params" => %{"name" => "matrix", "arguments" => %{"action" => "run"}}
        })

        resp = JSON.decode!(conn.resp_body)
        assert [%{"type" => "text"} | _] = resp["result"]["content"]

        if Wymcp.ProtocolVersion.supports_output_schema?(version) do
          assert Map.has_key?(resp["result"], "structuredContent"),
                 "expected structuredContent for #{version}"
        else
          refute Map.has_key?(resp["result"], "structuredContent"),
                 "expected structuredContent to be stripped for #{version}"
        end
      end
    end
  end

  # -- Helpers --

  defp init_call(version) do
    body = %{
      "jsonrpc" => "2.0",
      "id" => 0,
      "method" => "initialize",
      "params" => %{
        "protocolVersion" => version,
        "capabilities" => %{},
        "clientInfo" => %{"name" => "matrix", "version" => "1.0"}
      }
    }

    :post
    |> conn("/", JSON.encode!(body))
    |> put_req_header("content-type", "application/json")
    |> Wymcp.Router.call(@router_opts)
  end

  defp init_session(version) do
    conn = init_call(version)
    [session_id] = get_resp_header(conn, "mcp-session-id")

    notify_body = %{"jsonrpc" => "2.0", "method" => "notifications/initialized"}

    _ =
      :post
      |> conn("/", JSON.encode!(notify_body))
      |> put_req_header("content-type", "application/json")
      |> put_req_header("mcp-session-id", session_id)
      |> maybe_put_protocol_header(version)
      |> Wymcp.Router.call(@router_opts)

    session_id
  end

  defp call_with_session(session_id, version, body) do
    :post
    |> conn("/", JSON.encode!(body))
    |> put_req_header("content-type", "application/json")
    |> put_req_header("mcp-session-id", session_id)
    |> maybe_put_protocol_header(version)
    |> Wymcp.Router.call(@router_opts)
  end

  defp maybe_put_protocol_header(conn, version) do
    if Wymcp.ProtocolVersion.supports_protocol_version_header?(version) do
      put_req_header(conn, "mcp-protocol-version", version)
    else
      conn
    end
  end
end
```

- [ ] **Step 2: Run the matrix**

Run: `mix test test/wymcp/version_matrix_test.exs`
Expected: 15 tests PASS (5 tests × 3 versions). Test names in the output include the version, so any failure is self-locating.

- [ ] **Step 3: Run the full suite**

Run: `mix test`
Expected: only the pre-existing `"returns error for unsupported protocol version"` test still failing (handled in Task 10).

---

## Task 10: Rewrite the existing "unsupported version" test for counter-propose

**Files:**
- Modify: `test/wymcp/router_test.exs` (lines 243–260)

The existing test asserts `-32602` and `supported_versions == ["2025-11-25"]`. With Task 4's counter-propose change, this is the wrong shape — the server now returns success with the negotiated (counter-proposed) version. The test should assert that, and use `Wymcp.ProtocolVersion.supported/0` rather than hardcoding the list (so adding a future version doesn't require touching this test).

- [ ] **Step 1: Replace the test body**

In `test/wymcp/router_test.exs`, replace the `"returns error for unsupported protocol version"` test with a renamed test that asserts the new contract:

```elixir
    @tag doc: """
         Per spec: when the server does not support the requested
         version, it MUST respond with one it does — not a JSON-RPC
         error. The session is created and pinned to the counter-proposed
         version; the client decides whether to disconnect.
         """
    test "counter-proposes latest/0 for unsupported protocol version" do
      body = %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "initialize",
        "params" => %{
          "protocolVersion" => "1999-01-01",
          "capabilities" => %{},
          "clientInfo" => %{"name" => "test", "version" => "1.0"}
        }
      }

      conn = call_router(body)
      resp = JSON.decode!(conn.resp_body)

      refute Map.has_key?(resp, "error")
      assert resp["result"]["protocolVersion"] == Wymcp.ProtocolVersion.latest()
      assert [_session_id] = get_resp_header(conn, "mcp-session-id")
    end
```

If a separate test elsewhere in the file relies on the old `-32602` response shape, search for `"supported_versions"` and `-32602` and update or delete those assertions — there should not be any after this change.

- [ ] **Step 2: Run to confirm the test passes**

Run: `mix test test/wymcp/router_test.exs`
Expected: PASS.

- [ ] **Step 3: Run the full suite**

Run: `mix test`
Expected: all tests PASS, no failures.

- [ ] **Step 4: Run dialyzer one more time**

Run: `mix dialyzer`
Expected: no new warnings.

- [ ] **Step 5: Run the formatter**

Run: `mix format`
Expected: no diff to review (or a small whitespace-only diff that you accept).

---

## Task 11: Update the spec overview document

**Files:**
- Modify: `docs/mcp-spec-2025-11-25-overview.md` (§1.2 Lifecycle and §2.1 Tools)

The current §1.2 holds a temporary "current state" disclaimer. With multi-version support landing — and counter-propose now spec-compliant — replace it with the spec-compliant rows and add per-feature "since" annotations on the tool fields that are version-gated.

- [ ] **Step 1: Replace §1.2 Lifecycle**

In `docs/mcp-spec-2025-11-25-overview.md`, replace the §1.2 block (the disclaimer + table) with:

```markdown
### 1.2 Lifecycle

| Feature                                                            | Spec requirement | wymcp status                                                                                                |
|--------------------------------------------------------------------|------------------|-------------------------------------------------------------------------------------------------------------|
| `initialize` — version + capability negotiation                    | MUST             | ✅ `Methods.Initialize` accepts `2025-03-26`, `2025-06-18`, `2025-11-25` (see `Wymcp.ProtocolVersion`)      |
| `notifications/initialized`                                        | MUST             | ✅ `Methods.Initialized`                                                                                    |
| Version negotiation (echo or counter-propose)                      | MUST             | ✅ Echoes the client's requested version when supported; counter-proposes `latest/0` for unknown versions   |
| Negotiated version returned in `InitializeResult.protocolVersion`  | MUST             | ✅ Echoed (or counter-proposed) and pinned on the session                                                   |
| `MCP-Protocol-Version` HTTP header on subsequent requests          | MUST (HTTP, ≥ 06-18) | ✅ `Plugs.Session` enforces equality on ≥ 06-18 sessions; skipped entirely on 03-26 sessions            |
| Store negotiated client capabilities for the session               | SHOULD           | ✅ Stored in `Session.State.client_capabilities`                                                            |
| Capability negotiation for sampling/elicitation                    | SHOULD           | ✅ Server advertises only what client declares; `Wymcp.Context.elicit/4` also gates on negotiated version   |
| `serverInfo` fields: `title`, `description`, `icons`, `websiteUrl` | MAY              | ✅ Via `:server_info` router option *(included on ≥ 2025-06-18 sessions; stripped for 2025-03-26)*          |
| `instructions` field in init response                              | MAY              | ✅ Via `:instructions` router option (in spec since 2025-03-26 floor — no gating)                           |

> **Out of scope:** `2024-11-05`. That revision predates Streamable HTTP
> and requires a split-endpoint HTTP+SSE transport that wymcp does not
> implement. See `Wymcp.ProtocolVersion` for the supported set.
```

- [ ] **Step 2: Annotate version-gated fields in §2.1 Tools**

In §2.1, append the per-feature "since" annotations. Change:

```markdown
| `outputSchema` + `structuredContent`                   | MAY                         | ✅ Tools define `output_schema/0`, validated on return     |
```

to:

```markdown
| `outputSchema` + `structuredContent`                   | MAY                         | ✅ Tools define `output_schema/0`, validated on return *(emitted on ≥ 2025-06-18 sessions; stripped for 2025-03-26)* |
```

and change:

```markdown
| Tool `title` field                                     | MAY                         | ✅ Optional callback, included in `definition()`           |
```

to:

```markdown
| Tool `title` field                                     | MAY                         | ✅ Optional callback *(included on ≥ 2025-06-18 sessions; stripped for 2025-03-26)* |
```

- [ ] **Step 3: Verify the doc renders cleanly**

Run: `mix docs` (if `ex_doc` is configured) or open the file in your editor and visually scan for broken table rows.
Expected: tables are syntactically valid Markdown.

---

## Task 12: Update README with supported versions

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Add a "Supported MCP protocol versions" section**

In `README.md`, after the opening paragraphs (before "## Getting started" — find the line `## Getting started` and insert above it), add:

```markdown
## Supported MCP protocol versions

Wymcp accepts the three current revisions of the MCP specification.
When a client requests an unknown version, wymcp counter-proposes
its latest supported version per spec (`InitializeResult.protocolVersion`
contains the counter-proposal; the client decides whether to disconnect).

| Version       | Status                  | Notes                                                                                  |
|---------------|-------------------------|----------------------------------------------------------------------------------------|
| `2025-11-25`  | Supported (default)     | Latest. All implemented features available.                                            |
| `2025-06-18`  | Supported               | All implemented features available.                                                    |
| `2025-03-26`  | Supported (floor)       | Tool `title`, `outputSchema` / `structuredContent`, `serverInfo` extensions, elicitation, and the `MCP-Protocol-Version` header are version-gated and omitted on 2025-03-26 sessions. |
| `2024-11-05`  | **Not supported**       | Predates Streamable HTTP and uses a split-endpoint HTTP+SSE transport that wymcp does not implement. Counter-proposed to `2025-11-25` during `initialize`. |

The single source of truth for which versions are accepted and which
features are gated by version is `Wymcp.ProtocolVersion`. The conn-aware
resolver `Wymcp.Session.negotiated_version/1` is what `Methods.Initialize`,
`Methods.ToolsList`, `Methods.ToolsCall`, and `Wymcp.Context.elicit/4`
all consult.
```

- [ ] **Step 2: Verify the section integrates cleanly**

Open `README.md` in an editor, scan the new section's rendering (table syntax, heading levels, surrounding context).
Expected: the table is well-formed and the section sits between the project intro and "## Getting started".

---

## Task 13: Final verification

- [ ] **Step 1: Run the full test suite**

Run: `mix test`
Expected: all tests PASS.

- [ ] **Step 2: Run with warnings as errors**

Run: `mix compile --warnings-as-errors`
Expected: compiles cleanly.

- [ ] **Step 3: Run dialyzer**

Run: `mix dialyzer`
Expected: no new warnings against the baseline ignore file.

- [ ] **Step 4: Run the formatter**

Run: `mix format --check-formatted`
Expected: no diff. (If the formatter reports changes, run `mix format` and accept them.)

- [ ] **Step 5: Manually exercise a 2025-03-26 handshake**

Start the host application that embeds wymcp (e.g. ymer locally). Send an `initialize` request with `"protocolVersion": "2025-03-26"`:

```sh
curl -sS -X POST http://localhost:4000/mcp \
  -H 'content-type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"manual-check","version":"0"}}}'
```

Expected: response contains `"protocolVersion":"2025-03-26"` and an `mcp-session-id` header. `serverInfo` contains only `name` and `version` (no `title`/`description`/`websiteUrl`/`icons`).

- [ ] **Step 6: Manually exercise an unsupported-version counter-proposal**

```sh
curl -sS -X POST http://localhost:4000/mcp \
  -H 'content-type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"1999-01-01","capabilities":{},"clientInfo":{"name":"manual-check","version":"0"}}}'
```

Expected: response is success (no `error` key); `result.protocolVersion` equals `2025-11-25`; an `mcp-session-id` header is set.

(Substitute the host's actual MCP path / port. If only wymcp is being developed in isolation, skip both manual steps — the matrix test already covers the same flows.)
