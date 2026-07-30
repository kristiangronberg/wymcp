defmodule Wymcp.Tool.Schema do
  @moduledoc """
  Builds the JSON Schema `inputSchema` for Wymcp tools.

  One shape: the `action` field lists the declared action names as an enum
  with one-line descriptions (via `action_summaries/1`), and `data` is a
  bare object. `Wymcp.Tool`'s generated `input_schema/0` is the only caller.
  Per-action constraints are deliberately not encoded here: `:required` and
  `:required_one_of` are enforced at dispatch by `Wymcp.Tool`, and the full
  per-action schemas are surfaced on demand by `Wymcp.Help`. Property
  *values* (types, formats) are not validated by the framework at all — a
  tool that needs value guarantees checks them in `run_action/3`. This keeps
  the `tools/list` payload compact; agents act from the one-liners and pay
  for a tool's full schemas only when they ask.
  """

  @type json_schema :: %{required(String.t()) => term()}

  @spec build(map()) :: json_schema()
  def build(actions) when is_map(actions) do
    action_names =
      actions
      |> Map.keys()
      |> Enum.map(&Atom.to_string/1)
      |> Enum.sort()

    %{
      "type" => "object",
      "required" => ["action"],
      "properties" => %{
        "action" => %{
          "type" => "string",
          "enum" => action_names,
          "description" => Enum.join(action_summaries(actions), ". ")
        },
        "data" => %{"type" => "object"}
      }
    }
  end

  @doc """
  An action summary is one action's name joined to its description as
  `"<action>: <description>"`. Returns one summary per action, sorted by
  action name.

  Single content source for both the `tools/list` action description and the
  help tool's server index — the two render from the same list and cannot
  drift.
  """
  @spec action_summaries(map()) :: [String.t()]
  def action_summaries(actions) when is_map(actions) do
    actions
    |> Enum.sort_by(fn {action, _schema} -> Atom.to_string(action) end)
    |> Enum.map(fn {action, schema} -> "#{action}: #{schema.description}" end)
  end
end
