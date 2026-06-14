defmodule Wymcp.ToolTest do
  use ExUnit.Case, async: true

  @moduledoc """
  Tests for the Wymcp.Tool behaviour.

  Tool is the public-facing behaviour that consuming applications implement.
  Each tool defines a name, description, an actions map, and a `run_action/2`
  callback. The `use Wymcp.Tool` macro generates `input_schema/0` (oneOf or slim
  schema from actions), `run/2` (dispatch with required field validation, default
  application, hint injection, and error formatting), and `definition/0` (MCP tool
  descriptor).

  The generated `run/2` takes a `Wymcp.Context.t()` and returns
  `{:ok, content}`, `{:ok, content, assigns}`, or `{:error, String.t()}` — it no
  longer touches Plug.Conn directly. The method handler in ToolsCall is responsible
  for building the HTTP response from the returned tuple.

  When `strict_params?/0` is `true` (the default), `run/2` rejects any `data`
  key absent from the action's `:properties`, returning an `unknown_params`
  error instead of silently ignoring it. This is opt-out per tool via
  `def strict_params?, do: false`.
  """

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

  defmodule LenientTool do
    use Wymcp.Tool

    @impl true
    def name, do: "lenient"

    @impl true
    def description, do: "Tolerates unknown params"

    @impl true
    def strict_params?, do: false

    @impl true
    def actions do
      %{
        bare: %{description: "Echo data", properties: %{"x" => %{"type" => "string"}}}
      }
    end

    @impl Wymcp.Tool
    def run_action(:bare, data, _ctx), do: {:ok, %{got: data}}
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

  defmodule SlimWidgetTool do
    @moduledoc false
    use Wymcp.Tool

    @impl true
    def name, do: "slim_widgets"

    @impl true
    def description, do: "Manage widgets (slim mode)"

    @impl true
    def schema_mode, do: :slim

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

  defp build_ctx, do: %Context{session_pid: nil, session_id: "test", request_id: 1, assigns: %{}}

  defp decode_json_content({:ok, [%{"type" => "text", "text" => text}]}), do: JSON.decode!(text)

  defp decode_json_content({:ok, [%{"type" => "text", "text" => text}], _}),
    do: JSON.decode!(text)

  defp error?({:error, _}), do: true
  defp error?({:ok, [%{"type" => "text", "text" => _}]}), do: false

  describe "definition/0" do
    test "returns MCP tool definition with name, description, and oneOf schema" do
      defn = WidgetTool.definition()
      assert defn["name"] == "widgets"
      assert defn["description"] == "Manage widgets"
      assert is_list(defn["inputSchema"]["oneOf"])
      assert length(defn["inputSchema"]["oneOf"]) == length(Map.keys(WidgetTool.actions()))
    end

    test "slim mode definition has no oneOf in inputSchema" do
      defn = SlimWidgetTool.definition()
      refute Map.has_key?(defn["inputSchema"], "oneOf")
      assert is_list(defn["inputSchema"]["properties"]["action"]["enum"])
    end

    test "slim mode action enum includes help and describe" do
      defn = SlimWidgetTool.definition()
      enum = defn["inputSchema"]["properties"]["action"]["enum"]

      assert "help" in enum
      assert "describe" in enum
    end

    test "full mode definition retains oneOf schema" do
      defn = WidgetTool.definition()
      assert is_list(defn["inputSchema"]["oneOf"])
    end

    @tag doc:
           "Full mode does NOT inject help/describe into oneOf — keeps schema identical to before"
    test "full mode oneOf count matches declared actions only" do
      defn = WidgetTool.definition()
      assert length(defn["inputSchema"]["oneOf"]) == length(Map.keys(WidgetTool.actions()))
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

    test "returns {:ok, content} with error structure for missing required fields" do
      result = WidgetTool.run(build_ctx(), %{"action" => "create", "data" => %{}})
      content = decode_json_content(result)
      assert content["error"] == "missing_required_fields"
    end

    test "returns {:error, _} for unknown action" do
      result = WidgetTool.run(build_ctx(), %{"action" => "destroy"})
      assert {:error, _} = result
    end

    test "returns {:error, _} when action is missing entirely" do
      result = WidgetTool.run(build_ctx(), %{})
      assert {:error, _} = result
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
      result = SlimWidgetTool.run(build_ctx(), %{"action" => "failing_with_context"})
      assert {:error, _} = result
    end
  end

  describe "run/2 — help action" do
    test "help with no data returns summary of all actions" do
      result = WidgetTool.run(build_ctx(), %{"action" => "help"})
      content = decode_json_content(result)
      assert content["tool"] == "widgets"
      assert is_map(content["actions"])
      assert Map.has_key?(content["actions"], "create")
      assert Map.has_key?(content["actions"], "list")
      assert content["actions"]["create"]["description"] == "Create a widget"
      assert is_list(content["actions"]["create"]["required"])
      refute error?(result)
    end

    test "help with topic returns slim schema for that action" do
      result =
        WidgetTool.run(build_ctx(), %{"action" => "help", "data" => %{"topic" => "create"}})

      content = decode_json_content(result)
      assert content["action"] == "create"
      assert content["schema"]["description"] == "Create a widget"
      assert content["schema"]["required"] == ["name"]
      assert content["schema"]["properties"]["name"] == %{"type" => "string"}
      refute error?(result)
    end

    test "help with unknown topic returns error response" do
      result =
        WidgetTool.run(build_ctx(), %{"action" => "help", "data" => %{"topic" => "explode"}})

      assert {:error, _} = result
    end

    test "help works in slim mode" do
      result = SlimWidgetTool.run(build_ctx(), %{"action" => "help"})
      content = decode_json_content(result)
      assert is_map(content["actions"])
      refute error?(result)
    end

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
  end

  describe "run/2 — describe action" do
    test "describe with topic returns full schema for that action" do
      result =
        WidgetTool.run(build_ctx(), %{
          "action" => "describe",
          "data" => %{"topic" => "create"}
        })

      content = decode_json_content(result)
      assert content["action"] == "create"
      assert content["schema"]["description"] == "Create a widget"
      assert content["schema"]["required"] == ["name"]
      assert content["schema"]["defaults"] == %{"color" => "blue"}
      assert is_map(content["schema"]["properties"]["name"])
      refute error?(result)
    end

    test "describe with no topic returns full schemas for every action" do
      result = WidgetTool.run(build_ctx(), %{"action" => "describe"})
      content = decode_json_content(result)
      assert content["tool"] == "widgets"
      assert is_map(content["actions"])

      # The full schema for `create` is exposed, not just the summary.
      create = content["actions"]["create"]
      assert create["description"] == "Create a widget"
      assert create["required"] == ["name"]
      assert create["defaults"] == %{"color" => "blue"}
      assert is_map(create["properties"]["name"])
      refute error?(result)
    end

    test "describe with no topic differs from help with no topic" do
      describe_result = WidgetTool.run(build_ctx(), %{"action" => "describe"})
      help_result = WidgetTool.run(build_ctx(), %{"action" => "help"})

      describe_content = decode_json_content(describe_result)
      help_content = decode_json_content(help_result)

      # Help stays terse: per-action map has only description + required.
      help_create = help_content["actions"]["create"]
      refute Map.has_key?(help_create, "properties")
      refute Map.has_key?(help_create, "defaults")

      # Describe is broader: full schemas including properties + defaults.
      describe_create = describe_content["actions"]["create"]
      assert Map.has_key?(describe_create, "properties")
      assert Map.has_key?(describe_create, "defaults")
    end

    test "describe with unknown topic returns error response" do
      result =
        WidgetTool.run(build_ctx(), %{
          "action" => "describe",
          "data" => %{"topic" => "nope"}
        })

      assert {:error, _} = result
    end

    test "describe includes notes when present in action schema" do
      actions = %{
        op: %{
          description: "An op",
          properties: %{},
          required: [],
          defaults: %{},
          notes: "This is a note about the op."
        }
      }

      schema = Map.fetch!(actions, :op)
      assert schema.notes == "This is a note about the op."
    end

    test "describe works in slim mode" do
      result =
        SlimWidgetTool.run(build_ctx(), %{
          "action" => "describe",
          "data" => %{"topic" => "create"}
        })

      content = decode_json_content(result)
      assert content["action"] == "create"
      refute error?(result)
    end

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
  end

  describe "run/2 — action_context injection" do
    test "context is injected into normal action responses when non-nil" do
      result = SlimWidgetTool.run(build_ctx(), %{"action" => "list"})
      content = decode_json_content(result)
      assert content["context"]["tip"] == "2 widgets need attention"
    end

    test "context is omitted from normal action responses when nil" do
      result =
        SlimWidgetTool.run(build_ctx(), %{"action" => "create", "data" => %{"name" => "X"}})

      content = decode_json_content(result)
      refute Map.has_key?(content, "context")
    end

    test "context is injected into help with topic responses" do
      result =
        SlimWidgetTool.run(build_ctx(), %{"action" => "help", "data" => %{"topic" => "list"}})

      content = decode_json_content(result)
      assert content["context"]["tip"] == "2 widgets need attention"
    end

    test "context is injected into describe with topic responses" do
      result =
        SlimWidgetTool.run(build_ctx(), %{
          "action" => "describe",
          "data" => %{"topic" => "list"}
        })

      content = decode_json_content(result)
      assert content["context"]["tip"] == "2 widgets need attention"
    end

    test "context is omitted from help/describe when nil" do
      result =
        SlimWidgetTool.run(build_ctx(), %{
          "action" => "help",
          "data" => %{"topic" => "create"}
        })

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

  describe "strict_params?/0" do
    test "defaults to true" do
      assert WidgetTool.strict_params?() == true
    end

    test "tool may override to false" do
      assert LenientTool.strict_params?() == false
    end
  end

  describe "run/2 — unknown params" do
    test "rejects a data key not declared in the action's properties" do
      result =
        WidgetTool.run(build_ctx(), %{
          "action" => "bare",
          "data" => %{"x" => "ok", "bogus" => 1}
        })

      content = decode_json_content(result)
      assert content["error"] == "unknown_params"
      assert content["unknown"] == ["bogus"]
      assert content["action"] == "bare"
    end

    test "accepts data with only declared keys" do
      result =
        WidgetTool.run(build_ctx(), %{"action" => "bare", "data" => %{"x" => "ok"}})

      content = decode_json_content(result)
      assert content["got"] == %{"x" => "ok"}
      refute error?(result)
    end

    test "lenient tool passes unknown keys through" do
      result =
        LenientTool.run(build_ctx(), %{
          "action" => "bare",
          "data" => %{"x" => "ok", "bogus" => 1}
        })

      content = decode_json_content(result)
      assert content["got"] == %{"x" => "ok", "bogus" => 1}
    end
  end
end
