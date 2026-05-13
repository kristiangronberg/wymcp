defmodule Wymcp.Tool.Schema do
  @moduledoc """
  Builds JSON Schema `inputSchema` variants for Wymcp tools.

  Two schema modes are supported:

  - `build/1` — full `oneOf` schema. Every action has a discriminated variant
    with complete property definitions. MCP clients see the full input contract
    in `tools/list`.

  - `build_slim/1` — compact schema. The `action` field lists all action names
    (plus `help` and `describe`) as an enum with one-liner descriptions. The
    `data` field is a bare object. Reduces the `tools/list` payload by ~7x at
    the cost of `help`/`describe` round-trips when the LLM needs action details.

  `help` and `describe` are framework-provided actions. In slim mode they appear
  in the action enum. In full mode they are NOT injected into the `oneOf` — instead,
  Wymcp.Methods.ToolsCall (internal) bypasses schema validation for these action names.

  ## Related Modules

  See: `Wymcp.Tool` — uses this module in `input_schema/0`

  ## Tests

  See: `test/wymcp/tool/schema_test.exs`
  """

  @type json_schema :: %{required(String.t()) => term()}

  @spec build(map(), :full | :slim) :: json_schema()
  def build(actions, :slim), do: build_slim(actions)
  def build(actions, :full), do: build(actions)

  @spec build(map()) :: json_schema()
  def build(actions) when is_map(actions) do
    action_names =
      actions
      |> Map.keys()
      |> Enum.map(&Atom.to_string/1)
      |> Enum.sort()

    variants =
      actions
      |> Enum.map(fn {action_name, schema} -> build_variant(action_name, schema) end)
      |> Enum.sort_by(fn v -> v["properties"]["action"]["const"] end)

    %{
      "type" => "object",
      "required" => ["action"],
      "properties" => %{
        "action" => %{
          "type" => "string",
          "description" => "The operation to perform",
          "enum" => action_names
        },
        "data" => %{
          "type" => "object",
          "description" => "Action-specific parameters"
        }
      },
      "oneOf" => variants
    }
  end

  @spec build_slim(map()) :: json_schema()
  def build_slim(actions) when is_map(actions) do
    action_names =
      actions
      |> Map.keys()
      |> Enum.map(&Atom.to_string/1)
      |> Enum.sort()

    all_names = ["describe", "help" | action_names]

    action_summaries =
      actions
      |> Enum.sort_by(fn {k, _} -> Atom.to_string(k) end)
      |> Enum.map(fn {action, schema} -> "#{action}: #{schema.description}" end)

    description =
      [
        "help: Get action summaries or parameter details for a specific action",
        "describe: Get full schema with examples and constraints for an action"
        | action_summaries
      ]
      |> Enum.join(". ")

    %{
      "type" => "object",
      "required" => ["action"],
      "properties" => %{
        "action" => %{
          "type" => "string",
          "enum" => all_names,
          "description" => description
        },
        "data" => %{"type" => "object"}
      }
    }
  end

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
end
