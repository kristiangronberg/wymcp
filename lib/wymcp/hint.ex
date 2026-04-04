defmodule Wymcp.Hint do
  @moduledoc """
  Struct for follow-up action suggestions in MCP tool responses.

  Every hint represents a concrete next action the LLM can take. The struct
  enforces required fields at construction time and validates that `tool` and
  `action` are strings (matching the JSON wire format).

  ## Fields

  - `tool` (required) — tool name, e.g. `"tasks"`
  - `action` (required) — action name, e.g. `"get"`
  - `description` (required) — human-readable explanation of why this action is relevant
  - `example` (optional) — example `data` payload, e.g. `%{data: %{id: "..."}}`

  ## Usage

      Hint.new(tool: "tasks", action: "get", description: "View the task", example: %{data: %{id: id}})

  ## Related Modules

  See: `Wymcp.Tool` — consumes hints via the `hints/2` callback

  ## Tests

  See: `test/wymcp/hint_test.exs`
  """

  @enforce_keys [:tool, :action, :description]
  defstruct [:tool, :action, :description, :example]

  @type t :: %__MODULE__{
          tool: String.t(),
          action: String.t(),
          description: String.t(),
          example: map() | nil
        }

  @spec new(keyword() | map()) :: t()
  def new(attrs) when is_list(attrs) do
    new(Map.new(attrs))
  end

  def new(%{} = attrs) do
    hint = struct!(__MODULE__, attrs)
    validate!(hint)
    hint
  end

  @spec validate!(t()) :: :ok
  defp validate!(%__MODULE__{tool: tool, action: action}) do
    unless is_binary(tool) do
      raise ArgumentError, "Wymcp.Hint :tool must be a string, got: #{inspect(tool)}"
    end

    unless is_binary(action) do
      raise ArgumentError, "Wymcp.Hint :action must be a string, got: #{inspect(action)}"
    end

    :ok
  end

  defimpl JSON.Encoder do
    def encode(%Wymcp.Hint{} = hint, encoder) do
      map = %{tool: hint.tool, action: hint.action, description: hint.description}
      map = if hint.example, do: Map.put(map, :example, hint.example), else: map
      JSON.Encoder.Map.encode(map, encoder)
    end
  end
end
