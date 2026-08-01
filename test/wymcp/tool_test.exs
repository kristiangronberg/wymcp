defmodule Wymcp.ToolTest do
  use ExUnit.Case, async: true

  alias Wymcp.Context

  defmodule WidgetTool do
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
          defaults: %{"color" => "blue"}
        },
        list: %{
          description: "List widgets",
          properties: %{"limit" => %{"type" => "integer"}},
          required: [],
          defaults: %{"limit" => 10}
        },
        failing: %{
          description: "Always fails",
          properties: %{},
          required: [],
          defaults: %{}
        },
        failing_with_hints: %{
          description: "Fails with hints",
          properties: %{},
          required: [],
          defaults: %{}
        },
        bare: %{
          description: "Action with no required and no defaults",
          properties: %{"x" => %{"type" => "string"}}
        },
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
      }
    end

    @impl Wymcp.Tool
    def run_action(:create, %{"name" => name} = data, _ctx) do
      {:ok, %{message: "Created #{name}", color: data["color"]}, %{id: 42}}
    end

    @impl Wymcp.Tool
    def run_action(:list, data, _ctx), do: {:ok, %{widgets: [], limit: data["limit"]}}

    @impl Wymcp.Tool
    def run_action(:failing, _data, _ctx), do: {:error, {:not_found, 99}}

    @impl Wymcp.Tool
    def run_action(:failing_with_hints, _data, _ctx), do: {:error, {:not_found, 99}, %{id: 99}}

    @impl Wymcp.Tool
    def run_action(:bare, data, _ctx), do: {:ok, %{got: data}}

    @impl Wymcp.Tool
    def run_action(:identify, data, _ctx), do: {:ok, %{found: data}}

    @impl Wymcp.Tool
    def run_action(:locate, data, _ctx), do: {:ok, %{located: data}}

    @impl Wymcp.Tool
    def run_action(:identify_with_default, data, _ctx), do: {:ok, %{found: data}}

    @impl Wymcp.Tool
    def hints(:create, %{id: id}) do
      [Wymcp.Hint.new(tool: "widgets", action: "get", description: "View it", example: %{id: id})]
    end

    def hints(:failing_with_hints, %{id: _id}) do
      [
        Wymcp.Hint.new(
          tool: "widgets",
          action: "list",
          description: "List remaining",
          example: %{data: %{}}
        )
      ]
    end

    @impl Wymcp.Tool
    def handle_error({:not_found, id}), do: "Widget #{id} not found"
  end

  defmodule TitledTool do
    use Wymcp.Tool

    @impl true
    def name, do: "titled"

    @impl true
    def title, do: "My Titled Tool"

    @impl true
    def description, do: "A tool with a title"

    @impl true
    def actions do
      %{
        ping: %{
          description: "Ping",
          properties: %{},
          required: [],
          defaults: %{}
        }
      }
    end

    @impl Wymcp.Tool
    def run_action(:ping, _data, _ctx), do: {:ok, %{ok: true}}
  end

  defmodule AnnotatedTool do
    use Wymcp.Tool

    @impl true
    def name, do: "annotated"

    @impl true
    def description, do: "A tool with annotations"

    @impl true
    def annotations do
      %{
        "readOnlyHint" => true,
        "openWorldHint" => false
      }
    end

    @impl true
    def actions do
      %{
        read: %{
          description: "Read",
          properties: %{},
          required: [],
          defaults: %{}
        }
      }
    end

    @impl Wymcp.Tool
    def run_action(:read, _data, _ctx), do: {:ok, %{ok: true}}
  end

  defmodule ContextWidgetTool do
    @moduledoc false
    use Wymcp.Tool

    @impl true
    def name, do: "context_widgets"

    @impl true
    def description, do: "Manage widgets with action context"

    @impl true
    def actions do
      %{
        create: %{
          description: "Create a widget",
          properties: %{"name" => %{"type" => "string"}},
          required: ["name"],
          defaults: %{}
        },
        list: %{
          description: "List widgets",
          properties: %{},
          required: [],
          defaults: %{}
        },
        failing_with_context: %{
          description: "Fails with context",
          properties: %{},
          required: [],
          defaults: %{}
        }
      }
    end

    @impl Wymcp.Tool
    def run_action(:create, %{"name" => name}, _ctx), do: {:ok, %{message: "Created #{name}"}}
    def run_action(:list, _data, _ctx), do: {:ok, %{widgets: []}}
    def run_action(:failing_with_context, _data, _ctx), do: {:error, :broken, %{}}

    @impl Wymcp.Tool
    def action_context(:list, _ctx), do: %{tip: "2 widgets need attention"}
    def action_context(_action, _ctx), do: nil
  end

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

  defmodule ShadowedNamesTool do
    @moduledoc false
    use Wymcp.Tool

    @impl true
    def name, do: "shadowed"

    @impl true
    def description, do: "Has ordinary actions that happen to be named help and describe"

    @impl true
    def actions do
      %{
        help: %{description: "An ordinary action named help", properties: %{}},
        describe: %{description: "An ordinary action named describe", properties: %{}}
      }
    end

    @impl Wymcp.Tool
    def run_action(:help, _data, _ctx), do: {:ok, %{answered: "help"}}
    def run_action(:describe, _data, _ctx), do: {:ok, %{answered: "describe"}}
  end

  defmodule BareBehaviourTool do
    @moduledoc false
    @behaviour Wymcp.Tool

    @impl true
    def name, do: "bare_behaviour"

    @impl true
    def description, do: "Implements the behaviour without the use macro"

    @impl true
    def actions do
      %{ping: %{description: "Returns pong", properties: %{}}}
    end

    @impl Wymcp.Tool
    def run_action(:ping, _data, _ctx), do: {:ok, %{answer: "pong"}}

    # Hand-written run/2 — the path a @behaviour-only tool takes into
    # Wymcp.Tool.dispatch/4.
    def run(ctx, %{"action" => action} = params) do
      Wymcp.Tool.dispatch(__MODULE__, ctx, action, params["data"])
    end
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

  defp build_ctx, do: %Context{session_pid: nil, session_id: "test", request_id: 1, assigns: %{}}

  defp decode_json_content({:ok, [%{"type" => "text", "text" => text}]}), do: JSON.decode!(text)

  defp decode_json_content({:ok, [%{"type" => "text", "text" => text}], _}),
    do: JSON.decode!(text)

  defp error?({:error, _}), do: true
  defp error?({:ok, [%{"type" => "text", "text" => _}]}), do: false

  defp decode_error({:error, message, :dispatch}), do: JSON.decode!(message)

  describe "definition/0" do
    test "returns MCP tool definition with name, description, and input schema" do
      defn = WidgetTool.definition()

      assert defn["name"] == "widgets"
      assert defn["description"] == "Manage widgets"
      refute Map.has_key?(defn["inputSchema"], "oneOf")

      assert defn["inputSchema"]["properties"]["action"]["enum"] ==
               WidgetTool.actions() |> Map.keys() |> Enum.map(&Atom.to_string/1) |> Enum.sort()
    end
  end

  describe "run/2 — successful dispatch" do
    test "dispatches action and returns {:ok, content} tuple" do
      result = WidgetTool.run(build_ctx(), %{"action" => "create", "data" => %{"name" => "Bolt"}})
      content = decode_json_content(result)
      assert content["message"] == "Created Bolt"
      refute error?(result)
    end

    test "applies schema defaults when data keys are absent" do
      result = WidgetTool.run(build_ctx(), %{"action" => "list"})
      content = decode_json_content(result)
      assert content["limit"] == 10
    end

    test "data values override defaults" do
      result =
        WidgetTool.run(build_ctx(), %{
          "action" => "create",
          "data" => %{"name" => "X", "color" => "red"}
        })

      content = decode_json_content(result)
      assert content["color"] == "red"
    end

    test "nil data is normalized to empty map" do
      result = WidgetTool.run(build_ctx(), %{"action" => "list"})
      content = decode_json_content(result)
      assert content["limit"] == 10
    end
  end

  describe "run/2 — hint injection" do
    test "injects hints when run_action returns three-element tuple" do
      result = WidgetTool.run(build_ctx(), %{"action" => "create", "data" => %{"name" => "Bolt"}})
      content = decode_json_content(result)
      assert [%{"tool" => "widgets", "action" => "get"}] = content["hints"]
    end

    test "omits hints key when run_action returns two-element tuple" do
      result = WidgetTool.run(build_ctx(), %{"action" => "list"})
      content = decode_json_content(result)
      refute Map.has_key?(content, "hints")
    end
  end

  describe "run/2 — error handling" do
    test "returns {:error, message} for {:error, reason}" do
      result = WidgetTool.run(build_ctx(), %{"action" => "failing"})
      assert {:error, _} = result
    end

    test "returns structured error for missing required fields" do
      result = WidgetTool.run(build_ctx(), %{"action" => "create", "data" => %{}})
      content = decode_error(result)
      assert content["error"] == "missing_required_fields"
      assert content["help"] == ~s|help {tool: "widgets", action: "create"}|
    end

    test "unknown action returns a structured error naming the valid actions" do
      {:error, message, :dispatch} = WidgetTool.run(build_ctx(), %{"action" => "nope"})
      content = JSON.decode!(message)

      assert content["error"] == "unknown_action"
      assert content["message"] =~ "Unknown action 'nope' for tool 'widgets'"

      assert content["valid_actions"] ==
               WidgetTool.actions() |> Map.keys() |> Enum.map(&Atom.to_string/1) |> Enum.sort()

      assert content["help"] == ~s|help {tool: "widgets"}|
    end

    test "returns {:error, _, :dispatch} when action is missing entirely" do
      result = WidgetTool.run(build_ctx(), %{})
      assert {:error, _, :dispatch} = result
    end

    test "schema without :required and :defaults dispatches with empty defaults" do
      result = WidgetTool.run(build_ctx(), %{"action" => "bare", "data" => %{}})
      content = decode_json_content(result)
      assert content["got"] == %{}
    end

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

      content = decode_error(result)
      assert content["error"] == "missing_required_group"
      assert content["required_one_of"] == [["id"], ["name", "color"]]
      assert content["message"] =~ "(id) OR (name + color)"
      assert content["help"] == ~s|help {tool: "widgets", action: "identify"}|
    end

    test "required_one_of: error response input_schema surfaces required_one_of" do
      result =
        WidgetTool.run(build_ctx(), %{
          "action" => "identify",
          "data" => %{"name" => "alpha"}
        })

      content = decode_error(result)
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

      content = decode_error(result)
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

      content = decode_error(result)
      assert content["error"] == "missing_required_group"
      assert content["required_one_of"] == [["id"], ["name", "color"]]
    end

    test "required + required_one_of: required loses race when both unsatisfied" do
      result =
        WidgetTool.run(build_ctx(), %{
          "action" => "locate",
          "data" => %{}
        })

      content = decode_error(result)
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

      content = decode_error(result)
      assert content["error"] == "missing_required_group"
      assert content["required_one_of"] == [["id"], ["name", "color"]]
    end
  end

  describe "run/2 — error with hints" do
    @tag doc:
           "errors can carry hint_context just like successes — the response uses structured JSON with error + hints"
    test "includes hints in error response when hint_context provided" do
      result = WidgetTool.run(build_ctx(), %{"action" => "failing_with_hints"})
      assert {:error, error_json} = result
      content = JSON.decode!(error_json)
      assert content["error"] == "Widget 99 not found"
      assert is_list(content["hints"])
      assert length(content["hints"]) == 1
    end

    test "error without hints falls back to plain text" do
      result = WidgetTool.run(build_ctx(), %{"action" => "failing"})
      assert {:error, message} = result
      assert message == "Widget 99 not found"
    end

    test "context is injected into error responses with hints" do
      result = ContextWidgetTool.run(build_ctx(), %{"action" => "failing_with_context"})
      assert {:error, _} = result
    end
  end

  describe "run/2 — consumer actions named help or describe" do
    @tag doc: """
         Pins D11 (2026-07-28-introspection-simplification): only the TOOL
         name help is reserved. A consumer ACTION named help or describe is
         an ordinary action — before 0.8.0 the built-in dispatch clauses
         shadowed it silently.
         """
    test "an action named help dispatches to the consumer's run_action" do
      result = ShadowedNamesTool.run(build_ctx(), %{"action" => "help"})
      assert decode_json_content(result)["answered"] == "help"
    end

    test "an action named describe dispatches to the consumer's run_action" do
      result = ShadowedNamesTool.run(build_ctx(), %{"action" => "describe"})
      assert decode_json_content(result)["answered"] == "describe"
    end
  end

  describe "run/2 — action_context injection" do
    test "context is injected into normal action responses when non-nil" do
      result = ContextWidgetTool.run(build_ctx(), %{"action" => "list"})
      content = decode_json_content(result)
      assert content["context"]["tip"] == "2 widgets need attention"
    end

    test "context is omitted from normal action responses when nil" do
      result =
        ContextWidgetTool.run(build_ctx(), %{"action" => "create", "data" => %{"name" => "X"}})

      content = decode_json_content(result)
      refute Map.has_key?(content, "context")
    end

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

    test "a behaviour-only tool without action_context/2 dispatches without crashing" do
      result = BareBehaviourTool.run(build_ctx(), %{"action" => "ping"})
      content = decode_json_content(result)

      assert content["answer"] == "pong"
      refute Map.has_key?(content, "context")
    end

    test "a defined action_context returning neither nil nor a map raises" do
      assert_raise CaseClauseError, fn ->
        BadContextTool.run(build_ctx(), %{"action" => "ping"})
      end
    end
  end

  describe "title/0" do
    test "includes title in definition when implemented" do
      assert TitledTool.definition()["title"] == "My Titled Tool"
    end

    test "omits title from definition when not implemented" do
      refute Map.has_key?(WidgetTool.definition(), "title")
    end
  end

  describe "annotations/0" do
    test "includes annotations in definition when implemented" do
      defn = AnnotatedTool.definition()
      assert defn["annotations"]["readOnlyHint"] == true
      assert defn["annotations"]["openWorldHint"] == false
    end

    test "omits annotations from definition when not implemented" do
      refute Map.has_key?(WidgetTool.definition(), "annotations")
    end
  end

  describe "run/2 — unknown params" do
    test "rejects a data key not declared in the action's properties" do
      result =
        WidgetTool.run(build_ctx(), %{
          "action" => "bare",
          "data" => %{"x" => "ok", "bogus" => 1}
        })

      content = decode_error(result)
      assert content["error"] == "unknown_params"
      assert content["unknown"] == ["bogus"]
      assert content["action"] == "bare"
      assert content["help"] == ~s|help {tool: "widgets", action: "bare"}|
    end

    test "accepts data with only declared keys" do
      result =
        WidgetTool.run(build_ctx(), %{"action" => "bare", "data" => %{"x" => "ok"}})

      content = decode_json_content(result)
      assert content["got"] == %{"x" => "ok"}
      refute error?(result)
    end
  end
end
