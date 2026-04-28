defmodule Wymcp.ProtocolVersionTest do
  use ExUnit.Case, async: true

  @moduledoc """
  Tests for the per-version feature gate and the strip helpers.

  The `supported/0` list is the floor of what wymcp accepts. Adding or
  removing a version here is an intentional API change — every test in
  this file should fail loudly if the list changes by accident.

  Per-feature predicates encode when each MCP wire feature was added.
  These dates come from the official MCP changelogs:

  - [2025-03-26](https://modelcontextprotocol.io/specification/2025-03-26/changelog) —
    introduced Streamable HTTP, `Mcp-Session-Id`, tool `annotations`,
    and the `instructions` field on `InitializeResult`. This is wymcp's
    floor.
  - [2025-06-18](https://modelcontextprotocol.io/specification/2025-06-18/changelog) —
    introduced `outputSchema`, `structuredContent`, tool `title`, the
    `MCP-Protocol-Version` HTTP header, the `serverInfo` extensions
    (`title`, `description`, `websiteUrl`, `icons`), and elicitation.
  - [2025-11-25](https://modelcontextprotocol.io/specification/2025-11-25/changelog) —
    introduced URL-mode elicitation, sampling `tools`, and tasks
    (none of which wymcp implements yet).
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
