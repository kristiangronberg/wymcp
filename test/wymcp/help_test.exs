defmodule Wymcp.HelpTest do
  use ExUnit.Case, async: true

  alias Wymcp.{Context, Help, Session, Testing}

  defmodule WidgetTool do
    @moduledoc false
    use Wymcp.Tool

    @impl true
    def name, do: "widgets"

    @impl true
    def description, do: "Manage widgets"

    @impl true
    def actions do
      %{
        create: %{
          description: "Create a widget",
          properties: %{
            "name" => %{"type" => "string"},
            "color" => %{"type" => "string"}
          },
          required: ["name"],
          defaults: %{"color" => "blue"},
          notes: "Widgets are cheap; create freely.",
          related: ["list"],
          examples: [%{"name" => "bolt"}]
        },
        identify: %{
          description: "Identify by id or by (name + color)",
          properties: %{
            "id" => %{"type" => "integer"},
            "name" => %{"type" => "string"},
            "color" => %{"type" => "string"}
          },
          required_one_of: [["id"], ["name", "color"]]
        },
        list: %{
          description: "List widgets",
          properties: %{}
        }
      }
    end

    @impl Wymcp.Tool
    def run_action(_action, _data, _ctx), do: {:ok, %{}}

    @impl Wymcp.Tool
    def action_context(:list, _ctx), do: %{tip: "2 widgets need attention"}
    def action_context(_action, _ctx), do: nil
  end

  defmodule BadContextTool do
    @moduledoc false
    use Wymcp.Tool

    @impl true
    def name, do: "bad_context"

    @impl true
    def description, do: "action_context returns a non-map"

    @impl true
    def actions do
      %{ping: %{description: "Returns ok", properties: %{}}}
    end

    @impl Wymcp.Tool
    def run_action(:ping, _data, _ctx), do: {:ok, %{}}

    @impl Wymcp.Tool
    def action_context(_action, _ctx), do: "not a map"
  end

  defp build_ctx(tools) do
    {:ok, pid, session_id} = Session.start_session(Testing.build_session_opts(tools: tools))

    %Context{session_pid: pid, session_id: session_id, request_id: 1, assigns: %{}}
  end

  defp decode({:ok, [%{"type" => "text", "text" => text}]}), do: JSON.decode!(text)

  describe "definition/0" do
    test "returns the wire definition under the reserved name" do
      definition = Help.definition()

      assert definition["name"] == "help"
      assert is_binary(definition["description"])
      assert definition["inputSchema"]["additionalProperties"] == false
      assert Map.keys(definition["inputSchema"]["properties"]) == ["action", "tool"]
    end
  end

  describe "uses_reserved_name?/1" do
    test "true for a module whose name/0 is \"help\"" do
      assert Help.uses_reserved_name?(Help)
    end

    test "false for any other tool" do
      refute Help.uses_reserved_name?(WidgetTool)
    end
  end

  describe "run/2 — index" do
    test "bare call returns every session tool with action summaries" do
      ctx = build_ctx([WidgetTool, Help])

      %{"tools" => tools} = decode(Help.run(ctx, %{}))

      assert [
               %{"tool" => "widgets", "description" => "Manage widgets", "actions" => summaries},
               %{"tool" => "help", "actions" => []}
             ] = tools

      assert summaries == [
               "create: Create a widget",
               "identify: Identify by id or by (name + color)",
               "list: List widgets"
             ]
    end

    test "a server with no consumer tools serves an index containing only help" do
      ctx = build_ctx([Help])

      assert %{"tools" => [%{"tool" => "help"}]} = decode(Help.run(ctx, %{}))
    end

    test "runtime tools registered mid-session appear in the index immediately" do
      ctx = build_ctx([Help])
      :ok = Session.register_tool(ctx.session_pid, WidgetTool)

      %{"tools" => tools} = decode(Help.run(ctx, %{}))

      assert Enum.map(tools, & &1["tool"]) == ["widgets", "help"]
    end
  end

  describe "run/2 — tool level" do
    test "returns the tool complete, actions keyed by name" do
      ctx = build_ctx([WidgetTool, Help])

      response = decode(Help.run(ctx, %{"tool" => "widgets"}))

      assert response["tool"] == "widgets"
      assert response["description"] == "Manage widgets"

      create = response["actions"]["create"]
      assert create["description"] == "Create a widget"
      assert create["required"] == ["name"]
      assert create["defaults"] == %{"color" => "blue"}
      assert create["notes"] == "Widgets are cheap; create freely."
      assert create["related"] == ["list"]
      assert create["examples"] == [%{"name" => "bolt"}]
      assert create["properties"]["name"] == %{"type" => "string"}

      assert response["actions"]["identify"]["required_one_of"] == [["id"], ["name", "color"]]
      refute Map.has_key?(response["actions"]["list"], "notes")
    end

    test "help {tool: \"help\"} renders like any tool, with no actions" do
      ctx = build_ctx([Help])

      response = decode(Help.run(ctx, %{"tool" => "help"}))

      assert response["tool"] == "help"
      assert response["actions"] == %{}
    end
  end

  describe "run/2 — action level" do
    test "returns one action complete" do
      ctx = build_ctx([WidgetTool, Help])

      response = decode(Help.run(ctx, %{"tool" => "widgets", "action" => "create"}))

      assert response["tool"] == "widgets"
      assert response["action"] == "create"
      assert response["description"] == "Create a widget"
      assert response["required"] == ["name"]
      assert response["notes"] == "Widgets are cheap; create freely."
      refute Map.has_key?(response, "context")
    end

    test "includes the target tool's action_context under \"context\"" do
      ctx = build_ctx([WidgetTool, Help])

      response = decode(Help.run(ctx, %{"tool" => "widgets", "action" => "list"}))

      assert response["context"] == %{"tip" => "2 widgets need attention"}
    end

    test "omits required_one_of and doc fields when the action lacks them" do
      ctx = build_ctx([WidgetTool, Help])

      response = decode(Help.run(ctx, %{"tool" => "widgets", "action" => "list"}))

      assert response["required"] == []
      refute Map.has_key?(response, "required_one_of")
      refute Map.has_key?(response, "defaults")
      refute Map.has_key?(response, "notes")
    end

    test "a bad action_context return raises instead of being dropped" do
      ctx = build_ctx([BadContextTool, Help])

      assert_raise CaseClauseError, fn ->
        Help.run(ctx, %{"tool" => "bad_context", "action" => "ping"})
      end
    end
  end

  describe "run/2 — telemetry" do
    test "emits [:wymcp, :help, :called] with target and level" do
      ref = make_ref()
      handler_id = "help-called-#{inspect(ref)}"

      :telemetry.attach(
        handler_id,
        [:wymcp, :help, :called],
        fn _event, _measurements, metadata, _config ->
          send(self(), {:telemetry, ref, metadata})
        end,
        nil
      )

      try do
        ctx = build_ctx([WidgetTool, Help])

        {:ok, _content} = Help.run(ctx, %{"tool" => "widgets", "action" => "create"})

        assert_received {:telemetry, ^ref, metadata}
        assert metadata.tool == "widgets"
        assert metadata.action == "create"
        assert metadata.level == :action
        assert metadata.session_id == ctx.session_id

        {:ok, _content} = Help.run(ctx, %{})
        assert_received {:telemetry, ^ref, %{level: :index, tool: nil, action: nil}}
      after
        :telemetry.detach(handler_id)
      end
    end
  end

  describe "run/2 — errors" do
    test "unknown tool errors naming the valid tools" do
      ctx = build_ctx([WidgetTool, Help])

      {:error, message} = Help.run(ctx, %{"tool" => "nope"})
      payload = JSON.decode!(message)

      assert payload["error"] == "unknown_tool"
      assert payload["valid_tools"] == ["help", "widgets"]
      assert payload["message"] =~ "Unknown tool 'nope'"
      assert payload["help"] == "help {}"
    end

    test "action without tool errors naming the valid tools" do
      ctx = build_ctx([WidgetTool, Help])

      {:error, message} = Help.run(ctx, %{"action" => "create"})
      payload = JSON.decode!(message)

      assert payload["error"] == "missing_tool"
      assert payload["valid_tools"] == ["help", "widgets"]
      assert payload["help"] == "help {}"
    end

    test "unknown action errors naming that tool's valid actions" do
      ctx = build_ctx([WidgetTool, Help])

      {:error, message} = Help.run(ctx, %{"tool" => "widgets", "action" => "nope"})
      payload = JSON.decode!(message)

      assert payload["error"] == "unknown_action"
      assert payload["valid_actions"] == ["create", "identify", "list"]
      assert payload["help"] == ~s|help {tool: "widgets"}|
    end

    test "resolution order: unknown tool wins over any action" do
      ctx = build_ctx([WidgetTool, Help])

      {:error, message} = Help.run(ctx, %{"tool" => "nope", "action" => "create"})

      assert JSON.decode!(message)["error"] == "unknown_tool"
    end
  end
end
