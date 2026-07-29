defmodule Wymcp.Help do
  @moduledoc """
  The framework-owned introspection tool — the server's entire introspection
  surface, injected by `Wymcp.Router` into every server under the reserved
  tool name `help`.

  Help answers at three levels: a bare call returns the server index (every
  tool with its action one-liners); `tool` returns that tool complete (all
  action schemas with notes, related actions, and examples); `tool` plus
  `action` returns one action complete, with the target tool's
  `c:Wymcp.Tool.action_context/2` output under `"context"`. Resolution order
  is `tool` first, then `action` — `action` without `tool` is an error, and
  unknown targets error naming the valid ones (`isError: true` content the
  calling LLM can self-correct from), never a silent fallback to a broader
  answer.

  The index shares its content source with the `tools/list` description
  builder (`Wymcp.Tool.Schema.action_summaries/1`), so the two cannot drift.
  Server-level prose does not live here — it belongs in the initialize
  `instructions` router option.

  This module implements the tool wire contract by hand (`definition/0`,
  `input_schema/0`, `run/2`) rather than through `use Wymcp.Tool`: help has
  no action dispatch, its two parameters live at the top level of
  `arguments`, and its input schema sets `additionalProperties: false` so a
  misspelled parameter is rejected by argument validation instead of
  silently answering the index.

  Every call emits `[:wymcp, :help, :called]` — see `Wymcp.Telemetry`.

  ```mermaid
  flowchart TD
      H[Wymcp.Help] --> R["run/2"]
      subgraph External
          R -->|"get_tools/1"| S[Session]
          R -->|"action_summaries/1"| SC[Tool.Schema]
          R -->|"action_context/2"| T(Target tool)
          R --> TE[Telemetry]
      end
  ```
  """

  @behaviour Wymcp.Tool

  alias Wymcp.{Context, Session, Telemetry}
  alias Wymcp.Tool.Schema

  @name "help"
  @description "Get details about this server's tools. " <>
                 "No arguments: an index of every tool and its actions. " <>
                 "{tool}: that tool's actions in full (schemas, notes, examples). " <>
                 "{tool, action}: one action in full."

  @impl Wymcp.Tool
  def name, do: @name

  @impl Wymcp.Tool
  def description, do: @description

  @impl Wymcp.Tool
  def actions, do: %{}

  @impl Wymcp.Tool
  def run_action(_action, _data, _ctx), do: {:error, "help does not dispatch actions"}

  @impl Wymcp.Tool
  def output_schema, do: nil

  @doc false
  @spec input_schema() :: Schema.json_schema()
  def input_schema do
    %{
      "type" => "object",
      "properties" => %{
        "tool" => %{
          "type" => "string",
          "description" => "Tool name to get details about"
        },
        "action" => %{
          "type" => "string",
          "description" => "Action name within that tool (requires tool)"
        }
      },
      "additionalProperties" => false
    }
  end

  @doc false
  @spec definition() :: %{required(String.t()) => term()}
  def definition do
    %{"name" => @name, "description" => @description, "inputSchema" => input_schema()}
  end

  @doc false
  @spec run(Context.t(), map()) :: {:ok, Context.content()} | {:error, String.t()}
  def run(%Context{} = ctx, params) when is_map(params) do
    tool_name = params["tool"]
    action_name = params["action"]

    Telemetry.emit(:help, :called, %{}, %{
      tool: tool_name,
      action: action_name,
      level: level(tool_name, action_name),
      session_id: ctx.session_id
    })

    answer(Session.get_tools(ctx.session_pid), tool_name, action_name, ctx)
  end

  @spec level(term(), term()) :: :index | :tool | :action
  defp level(nil, nil), do: :index
  defp level(_tool, nil), do: :tool
  defp level(_tool, _action), do: :action

  @spec answer([module()], term(), term(), Context.t()) ::
          {:ok, Context.content()} | {:error, String.t()}
  defp answer(tools, nil, nil, _ctx) do
    {:ok, Context.json(index(tools))}
  end

  defp answer(tools, nil, action_name, _ctx) do
    unknown_target(:missing_tool, action_name, tools)
  end

  defp answer(tools, tool_name, action_name, ctx) do
    case Enum.find(tools, &(&1.name() == tool_name)) do
      nil -> unknown_target(:unknown_tool, tool_name, tools)
      module when is_nil(action_name) -> {:ok, Context.json(tool_level(module))}
      module -> action_level(module, action_name, ctx)
    end
  end

  @spec index([module()]) :: %{tools: [map()]}
  defp index(tools) do
    %{tools: Enum.map(tools, &index_entry/1)}
  end

  @spec index_entry(module()) :: map()
  defp index_entry(module) do
    %{
      tool: module.name(),
      description: module.description(),
      actions: Schema.action_summaries(module.actions())
    }
  end

  @spec tool_level(module()) :: map()
  defp tool_level(module) do
    actions =
      Map.new(module.actions(), fn {action, schema} ->
        {Atom.to_string(action), render_action(schema)}
      end)

    %{tool: module.name(), description: module.description(), actions: actions}
  end

  @spec action_level(module(), String.t(), Context.t()) ::
          {:ok, Context.content()} | {:error, String.t()}
  defp action_level(module, action_name, ctx) do
    actions = module.actions()

    case Enum.find(actions, fn {action, _schema} -> Atom.to_string(action) == action_name end) do
      nil ->
        Wymcp.Tool.unknown_action_error(module, action_name, actions)

      {action, schema} ->
        response =
          %{tool: module.name(), action: action_name}
          |> Map.merge(render_action(schema))
          |> add_context(module, action, ctx)

        {:ok, Context.json(response)}
    end
  end

  @spec render_action(map()) :: %{required(atom()) => term()}
  defp render_action(schema) do
    %{
      description: schema.description,
      properties: schema.properties,
      required: Map.get(schema, :required, [])
    }
    |> Map.merge(Map.take(schema, [:required_one_of, :defaults, :notes, :related, :examples]))
  end

  @spec add_context(map(), module(), atom(), Context.t()) :: map()
  defp add_context(response, module, action, ctx) do
    # Hand-written tools need not export action_context/2; function_exported?
    # is reliable here only after a load (BEAM loads modules lazily) — every
    # session tool has been loaded by boot or registration validation, and
    # ensure_loaded? keeps this true even if that ordering ever changes.
    with true <- Code.ensure_loaded?(module),
         true <- function_exported?(module, :action_context, 2),
         context when is_map(context) <- module.action_context(action, ctx) do
      Map.put(response, :context, context)
    else
      _ -> response
    end
  end

  @spec unknown_target(:missing_tool | :unknown_tool, String.t(), [module()]) ::
          {:error, String.t()}
  defp unknown_target(:missing_tool, action_name, tools) do
    {:error,
     JSON.encode!(%{
       error: "missing_tool",
       message:
         "help with action '#{action_name}' requires a tool. " <>
           "Valid tools: #{Enum.join(tool_names(tools), ", ")}.",
       valid_tools: tool_names(tools)
     })}
  end

  defp unknown_target(:unknown_tool, tool_name, tools) do
    {:error,
     JSON.encode!(%{
       error: "unknown_tool",
       message:
         "Unknown tool '#{tool_name}'. Valid tools: #{Enum.join(tool_names(tools), ", ")}.",
       valid_tools: tool_names(tools)
     })}
  end

  @spec tool_names([module()]) :: [String.t()]
  defp tool_names(tools), do: tools |> Enum.map(& &1.name()) |> Enum.sort()
end
