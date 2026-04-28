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

  | Feature                                                                 | Since                |
  |-------------------------------------------------------------------------|----------------------|
  | Streamable HTTP, `Mcp-Session-Id`, tool `annotations`                   | `2025-03-26` (floor) |
  | `instructions` field in `InitializeResult`                              | `2025-03-26` (floor) |
  | Tool `title`                                                            | `2025-06-18`         |
  | `outputSchema` + `structuredContent`                                    | `2025-06-18`         |
  | `MCP-Protocol-Version` HTTP header (MUST)                               | `2025-06-18`         |
  | `serverInfo` extensions (`title`, `description`, `websiteUrl`, `icons`) | `2025-06-18`         |
  | `elicitation/create`                                                    | `2025-06-18`         |
  | URL-mode elicitation, sampling tools, Tasks                             | `2025-11-25`         |

  ## Counter-proposal

  When the client requests an unsupported version, the spec requires
  the server to respond with a version it does support (echoing back
  the same `InitializeResult` shape — not a JSON-RPC error). This
  module does not implement that policy; `Methods.Initialize` does.
  `latest/0` exists so that call site has a single canonical fallback.

  ## Future shape: declarative gate table

  The current module uses one bespoke `supports_*?/1` predicate and one
  `strip_*/2` helper per gated wire concept. That shape is type-safe at
  call sites — `strip_tool_definition(defn, version)` cannot be mistyped
  into a silent no-op — and the function names document intent. At the
  current handful of gates it reads cleanly.

  Once prompts and resources land (each with their own definition map
  and result map needing version-gated fields), the per-callsite
  function count grows roughly linearly with primitives. At that point
  consider collapsing to a single declarative table plus one generic
  `strip/3` keyed by scope:

      @gates [
        {"outputSchema",      "2025-06-18", :tool_definition},
        {"title",             "2025-06-18", :tool_definition},
        {"structuredContent", "2025-06-18", :tool_call_result},
        {"title",             "2025-06-18", :server_info},
        {"description",       "2025-06-18", :server_info},
        # ...
      ]

      @scopes ~w(tool_definition tool_call_result server_info)a

      def strip(map, version, scope) when scope in @scopes do
        for {field, since, ^scope} <- @gates,
            not supports_since?(version, since),
            reduce: map do
          acc -> Map.delete(acc, field)
        end
      end

  Adding a new gated field becomes one row; adding a new primitive
  becomes one new scope atom. The tradeoff is losing the typo-safe
  per-callsite name (mitigated by `scope in @scopes` validation), and
  call sites read as `ProtocolVersion.strip(defn, v, :tool_definition)`
  instead of `ProtocolVersion.strip_tool_definition(defn, v)`.

  Migration trigger: when adding the third primitive (resources),
  revisit this section. With four+ primitives the table form starts to
  pay back the loss in call-site clarity.

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
