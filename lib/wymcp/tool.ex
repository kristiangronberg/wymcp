defmodule Wymcp.Tool do
  @moduledoc """
  Behaviour for MCP tools using the action-dispatched pattern.

  Each tool exposes multiple actions under a single tool name. The
  `use Wymcp.Tool` macro generates the `inputSchema` from `actions/0`
  (via `Wymcp.Tool.Schema`), handles dispatch via `run_action/3`,
  validates required fields, rejects unknown parameters, applies
  defaults, injects hints, and formats errors.

  ## Usage

      defmodule MyApp.Tools.Tasks do
        use Wymcp.Tool

        @impl true
        def name, do: "tasks"

        @impl true
        def description, do: "Task management"

        @impl true
        def actions do
          %{
            create: %{
              description: "Create a task",
              properties: %{"name" => %{"type" => "string"}},
              required: ["name"],
              defaults: %{}
            }
          }
        end

        @impl Wymcp.Tool
        def run_action(:create, %{"name" => name}, _ctx) do
          {:ok, %{message: "Created \#{name}"}, %{id: 1}}
        end
      end

  ## Action schema format

  Each action in the `actions/0` map must have:

  - `:description` — human-readable description (appears in the action enum's
    one-liners and in help output)
  - `:properties` — JSON Schema properties for the action's `data` parameter

  Optional fields:

  - `:required` — list of unconditionally required property names (defaults to `[]`).
    Every listed field must be present in `data` (AND-semantics).
  - `:required_one_of` — list of groups, where each group is a list of property
    names. At least one group must be fully present (OR-of-AND semantics).
    Combines with `:required` — both checks run, both must pass.
    Enforced at dispatch; surfaced by the `help` tool.
  - `:defaults` — map of default values merged into `data` before dispatch
    (defaults to `%{}`).
  - `:notes` — long-form notes surfaced by the `help` tool.
  - `:related` — list of related action name strings surfaced by the `help` tool.
  - `:examples` — list of example payload maps surfaced by the `help` tool.

  Defaults are applied after validation: values supplied via `:defaults`
  do not count toward satisfying `:required` or `:required_one_of`. Both
  checks run against the caller's `data` as received.

  Action schemas are validated at server boot via `Wymcp.Router.init/1` and
  at runtime registration via `Wymcp.Session.register_tool/2`. A malformed
  schema (e.g. a `:required_one_of` group referencing a field not declared
  in `:properties`) raises `ArgumentError` immediately, surfacing the
  misconfiguration before any request is served.

  ### Example: OR-of-AND required group

      get_pull_request: %{
        description: "Get pull request details",
        properties: %{
          "url" => %{"type" => "string"},
          "project_key" => %{"type" => "string"},
          "repo_slug" => %{"type" => "string"},
          "pr_id" => %{"type" => "integer"}
        },
        required_one_of: [["url"], ["project_key", "repo_slug", "pr_id"]]
      }

  ## Return values from `run_action/3`

  - `{:ok, response_data}` — success, response sent as JSON
  - `{:ok, response_data, hint_context}` — success with hints; the framework
    calls `hints/2` with the action and hint_context, injecting the result
  - `{:error, reason}` — error; the framework calls `handle_error/1` and
    sends the result as an isError response
  - `{:error, reason, hint_context}` — error with hints; the framework calls
    `handle_error/1`, `hints/2`, and `action_context/2`, then sends structured
    JSON with `error`, `hints`, and optional `context` keys

  ## Optional callbacks

  - `hints/2` — returns a list of follow-up action suggestions. Default: `[]`
  - `handle_error/1` — formats an error reason into a string.
    Default: `"Operation failed: \#{inspect(reason)}"`
  - `action_context/2` — returns a map of runtime context for the given
    action, or `nil`. Receives `(action_atom, ctx)`, where `ctx` is the
    same `Wymcp.Context.t()` passed to `run_action/3`. Called by the
    `help` tool at action level and during normal action dispatch.
    The map appears under a `"context"` key in the response.
    Read per-request data from `ctx.assigns` rather than the process
    dictionary — `action_context` may be invoked from a process that
    did not run the auth plug.
  - `output_schema/0` — returns a JSON Schema map describing the structure of
    the tool's response, or `nil`. When present, `tools/list` includes
    `"outputSchema"` in the definition and `tools/call` validates the response
    against it, returning `"structuredContent"` alongside `"content"`.
    Default: `nil`

  > ### @behaviour Wymcp.Tool {: .tip}
  >
  > If you implement `@behaviour Wymcp.Tool` directly instead of
  > `use Wymcp.Tool`, you must define `def output_schema, do: nil` yourself.
  > The `use` macro provides this default automatically, but manual behaviour
  > implementors will get a runtime crash on `tools/call` without it.

  ```mermaid
  flowchart TD
      subgraph Tool Behaviour
          T[Wymcp.Tool] --> D["dispatch/4"]
          D --> A["action dispatch"]
          A --> R["handle_result/3"]
      end
      subgraph External
          T --> S[Tool.Schema]
          D --> C[Context]
          R --> HN[Hint]
          A -->|"module.run_action/3"| CB(Consumer Tool)
          R -->|"module.hints/2"| CB
          R -->|"module.action_context/2"| CB
      end
  ```
  """

  alias Wymcp.Context

  @type action_schema :: %{
          :description => String.t(),
          :properties => map(),
          optional(:required) => [String.t()],
          optional(:required_one_of) => [[String.t()]],
          optional(:defaults) => map(),
          optional(:notes) => String.t(),
          optional(:related) => [String.t()],
          optional(:examples) => [map()]
        }

  @type hint :: Wymcp.Hint.t()

  # -- Callbacks --

  @callback name() :: String.t()
  @callback description() :: String.t()
  @callback actions() :: %{atom() => action_schema()}
  @callback run_action(action :: atom(), data :: map(), ctx :: Wymcp.Context.t()) ::
              {:ok, term()} | {:ok, term(), map()} | {:error, term()} | {:error, term(), map()}
  @callback hints(action :: atom(), hint_context :: map()) :: [hint()]
  @callback handle_error(error :: term()) :: String.t()
  @callback action_context(action :: atom(), ctx :: Wymcp.Context.t()) :: map() | nil
  @callback title() :: String.t() | nil
  @callback annotations() :: map() | nil
  @callback output_schema() :: map() | nil

  @optional_callbacks hints: 2,
                      handle_error: 1,
                      action_context: 2,
                      output_schema: 0,
                      title: 0,
                      annotations: 0

  # -- Macro --

  defmacro __using__(_opts) do
    quote do
      @behaviour Wymcp.Tool

      @spec hints(atom(), map()) :: [Wymcp.Tool.hint()]
      def hints(_action, _hint_context), do: []

      @spec handle_error(term()) :: String.t()
      def handle_error(reason), do: "Operation failed: #{inspect(reason)}"

      @spec action_context(atom(), Wymcp.Context.t()) :: map() | nil
      def action_context(_action, _ctx), do: nil

      @spec title() :: String.t() | nil
      def title, do: nil

      @spec annotations() :: map() | nil
      def annotations, do: nil

      @spec output_schema() :: map() | nil
      def output_schema, do: nil

      defoverridable hints: 2,
                     handle_error: 1,
                     action_context: 2,
                     output_schema: 0,
                     title: 0,
                     annotations: 0

      @before_compile Wymcp.Tool
    end
  end

  defmacro __before_compile__(_env) do
    quote do
      @doc false
      @spec input_schema() :: map()
      def input_schema do
        # Fully qualified by design: this is injected into the consumer's tool
        # module, so an alias here would leak into their namespace (macro hygiene).
        # credo:disable-for-next-line Credo.Check.Design.AliasUsage
        Wymcp.Tool.Schema.build(actions())
      end

      @doc false
      @spec run(Wymcp.Context.t(), map()) ::
              {:ok, Wymcp.Context.content()}
              | {:ok, Wymcp.Context.content(), map()}
              | {:error, String.t()}
      def run(%Wymcp.Context{} = ctx, %{"action" => action_str} = params) do
        Wymcp.Tool.dispatch(__MODULE__, ctx, action_str, params["data"])
      end

      def run(_ctx, _params) do
        {:error, "Missing required 'action' parameter"}
      end

      @spec definition() :: map()
      def definition do
        definition_data = %{
          "name" => name(),
          "description" => description(),
          "inputSchema" => input_schema()
        }

        definition_data = Wymcp.Tool.maybe_put_title(definition_data, title())
        definition_data = Wymcp.Tool.maybe_put_annotations(definition_data, annotations())
        Wymcp.Tool.maybe_put_output_schema(definition_data, output_schema())
      end
    end
  end

  # -- Action-schema validation --

  @doc """
  Validate every action schema in `module`. Raises `ArgumentError` with a
  descriptive message on the first malformed action.

  Called by `Wymcp.Router.init/1` at boot and by
  `Wymcp.Session.register_tool/2` at runtime registration, so a
  misconfigured tool fails when it is wired in rather than at its first
  request.
  """
  @spec validate_actions!(module()) :: :ok
  def validate_actions!(module) when is_atom(module) do
    actions = module.actions()

    Enum.each(actions, fn {action, schema} ->
      validate_action_schema!(module, action, schema)
    end)

    :ok
  end

  @spec validate_action_schema!(module(), atom(), map()) :: :ok
  defp validate_action_schema!(module, action, schema) do
    validate_description!(module, action, schema)
    properties = validate_properties!(module, action, schema)

    validate_required!(module, action, Map.get(schema, :required, []), properties)

    validate_required_one_of!(
      module,
      action,
      Map.get(schema, :required_one_of, []),
      properties
    )

    validate_doc_fields!(module, action, schema)

    :ok
  end

  # :description and :properties are load-bearing at request time — the
  # description is interpolated into every tools/list and both are read
  # unconditionally by the help tool — so their absence must fail here,
  # not as a KeyError on the first request.
  @spec validate_description!(module(), atom(), map()) :: :ok
  defp validate_description!(module, action, schema) do
    case Map.fetch(schema, :description) do
      {:ok, description} when is_binary(description) ->
        :ok

      {:ok, other} ->
        raise ArgumentError,
              "Tool #{inspect(module)} action #{inspect(action)}: " <>
                ":description must be a string, got #{inspect(other)}"

      :error ->
        raise ArgumentError,
              "Tool #{inspect(module)} action #{inspect(action)}: missing :description"
    end
  end

  @spec validate_properties!(module(), atom(), map()) :: map()
  defp validate_properties!(module, action, schema) do
    case Map.fetch(schema, :properties) do
      {:ok, properties} when is_map(properties) ->
        properties

      {:ok, other} ->
        raise ArgumentError,
              "Tool #{inspect(module)} action #{inspect(action)}: " <>
                ":properties must be a map, got #{inspect(other)}"

      :error ->
        raise ArgumentError,
              "Tool #{inspect(module)} action #{inspect(action)}: missing :properties"
    end
  end

  @spec validate_required!(module(), atom(), term(), map()) :: :ok
  defp validate_required!(module, action, required, properties) do
    unless is_list(required) and Enum.all?(required, &is_binary/1) do
      raise ArgumentError,
            "Tool #{inspect(module)} action #{inspect(action)}: " <>
              ":required must be a list of binaries, got #{inspect(required)}"
    end

    if length(required) != length(Enum.uniq(required)) do
      raise ArgumentError,
            "Tool #{inspect(module)} action #{inspect(action)}: " <>
              ":required has duplicate entries: #{inspect(required)}"
    end

    case Enum.reject(required, &Map.has_key?(properties, &1)) do
      [] ->
        :ok

      unknown ->
        raise ArgumentError,
              "Tool #{inspect(module)} action #{inspect(action)}: " <>
                ":required references field(s) not declared in :properties: " <>
                inspect(unknown)
    end
  end

  @spec validate_required_one_of!(module(), atom(), term(), map()) :: :ok
  defp validate_required_one_of!(_module, _action, [], _properties), do: :ok

  defp validate_required_one_of!(module, action, groups, properties) do
    unless is_list(groups) and
             Enum.all?(groups, fn g ->
               is_list(g) and Enum.all?(g, &is_binary/1)
             end) do
      raise ArgumentError,
            "Tool #{inspect(module)} action #{inspect(action)}: " <>
              ":required_one_of must be a list of lists of binaries, got " <>
              inspect(groups)
    end

    Enum.each(groups, fn group ->
      cond do
        group == [] ->
          raise ArgumentError,
                "Tool #{inspect(module)} action #{inspect(action)}: " <>
                  ":required_one_of contains an empty group"

        length(group) != length(Enum.uniq(group)) ->
          raise ArgumentError,
                "Tool #{inspect(module)} action #{inspect(action)}: " <>
                  ":required_one_of group has duplicate entries: #{inspect(group)}"

        true ->
          validate_group_fields!(module, action, group, properties)
      end
    end)

    if length(groups) != length(Enum.uniq(groups)) do
      raise ArgumentError,
            "Tool #{inspect(module)} action #{inspect(action)}: " <>
              ":required_one_of has duplicate groups: #{inspect(groups)}"
    end

    check_no_strict_superset!(module, action, groups)
    :ok
  end

  @spec validate_group_fields!(module(), atom(), [String.t()], map()) :: :ok
  defp validate_group_fields!(module, action, group, properties) do
    case Enum.reject(group, &Map.has_key?(properties, &1)) do
      [] ->
        :ok

      unknown ->
        raise ArgumentError,
              "Tool #{inspect(module)} action #{inspect(action)}: " <>
                ":required_one_of group references field(s) not declared " <>
                "in :properties: #{inspect(unknown)}"
    end
  end

  @spec check_no_strict_superset!(module(), atom(), [[String.t()]]) :: :ok
  defp check_no_strict_superset!(module, action, groups) do
    indexed = groups |> Enum.map(&MapSet.new/1) |> Enum.with_index()
    pairs = for {a, i} <- indexed, {b, j} <- indexed, i != j, do: {a, i, b, j}

    case Enum.find(pairs, fn {a, _i, b, _j} -> MapSet.subset?(a, b) and a != b end) do
      nil ->
        :ok

      {_a, i, _b, j} ->
        raise ArgumentError,
              "Tool #{inspect(module)} action #{inspect(action)}: " <>
                ":required_one_of group #{inspect(Enum.at(groups, j))} is a " <>
                "strict superset of #{inspect(Enum.at(groups, i))} (dead code: " <>
                "the smaller group always satisfies first)"
    end
  end

  @spec validate_doc_fields!(module(), atom(), map()) :: :ok
  defp validate_doc_fields!(module, action, schema) do
    validate_notes!(module, action, schema)
    validate_related!(module, action, schema)
    validate_examples!(module, action, schema)
    :ok
  end

  @spec validate_notes!(module(), atom(), map()) :: :ok
  defp validate_notes!(module, action, schema) do
    case Map.fetch(schema, :notes) do
      :error ->
        :ok

      {:ok, value} when is_binary(value) ->
        :ok

      {:ok, value} ->
        raise ArgumentError,
              "Tool #{inspect(module)} action #{inspect(action)}: " <>
                ":notes must be a binary, got #{inspect(value)}"
    end
  end

  @spec validate_related!(module(), atom(), map()) :: :ok
  defp validate_related!(module, action, schema) do
    case Map.fetch(schema, :related) do
      :error ->
        :ok

      {:ok, value} ->
        if is_list(value) and Enum.all?(value, &is_binary/1) do
          :ok
        else
          raise ArgumentError,
                "Tool #{inspect(module)} action #{inspect(action)}: " <>
                  ":related must be a list of binaries, got #{inspect(value)}"
        end
    end
  end

  @spec validate_examples!(module(), atom(), map()) :: :ok
  defp validate_examples!(module, action, schema) do
    case Map.fetch(schema, :examples) do
      :error ->
        :ok

      {:ok, value} ->
        if is_list(value) and Enum.all?(value, &is_map/1) do
          :ok
        else
          raise ArgumentError,
                "Tool #{inspect(module)} action #{inspect(action)}: " <>
                  ":examples must be a list of maps, got #{inspect(value)}"
        end
    end
  end

  # -- Dispatch (called by generated run/2) --

  @doc false
  @spec dispatch(module(), Context.t(), String.t(), map() | nil) ::
          {:ok, Context.content()} | {:ok, Context.content(), map()} | {:error, String.t()}
  def dispatch(module, ctx, action_str, data) do
    actions = module.actions()
    data = data || %{}

    with {:ok, action} <- parse_action(action_str, actions),
         schema = Map.fetch!(actions, action),
         :ok <- check_required(data, schema, action_str),
         :ok <- check_required_one_of(data, schema, action_str),
         :ok <- check_unknown_params(data, schema, action_str) do
      merged = apply_defaults(data, Map.get(schema, :defaults, %{}))
      handle_result(module, action, ctx, module.run_action(action, merged, ctx))
    else
      {:error, :unknown_action} ->
        unknown_action_error(module, action_str, actions)

      {:error, {:missing_required, missing, action_str, schema}} ->
        {:error,
         JSON.encode!(%{
           error: "missing_required_fields",
           message: "Required fields missing: #{Enum.join(missing, ", ")}",
           missing: missing,
           action: action_str,
           input_schema: schema_summary(schema),
           help: help_pointer(module, action_str)
         })}

      {:error, {:missing_required_groups, groups, action_str, schema}} ->
        {:error,
         JSON.encode!(%{
           error: "missing_required_group",
           message:
             "At least one of these field groups must be fully present: " <>
               format_groups(groups),
           required_one_of: groups,
           action: action_str,
           input_schema: schema_summary(schema),
           help: help_pointer(module, action_str)
         })}

      {:error, {:unknown_params, unknown, action_str, schema}} ->
        {:error,
         JSON.encode!(%{
           error: "unknown_params",
           message:
             "Unknown parameter(s) for action '#{action_str}': #{Enum.join(unknown, ", ")}. " <>
               "These are rejected rather than silently ignored.",
           unknown: unknown,
           action: action_str,
           input_schema: schema_summary(schema),
           help: help_pointer(module, action_str)
         })}
    end
  end

  @spec parse_action(String.t(), map()) :: {:ok, atom()} | {:error, :unknown_action}
  defp parse_action(action_str, actions) do
    action = String.to_existing_atom(action_str)

    if Map.has_key?(actions, action),
      do: {:ok, action},
      else: {:error, :unknown_action}
  rescue
    ArgumentError -> {:error, :unknown_action}
  end

  @spec check_required(map(), action_schema(), String.t()) :: :ok | {:error, tuple()}
  defp check_required(data, schema, action_str) do
    required = Map.get(schema, :required, [])
    missing = Enum.reject(required, &Map.has_key?(data, &1))

    if missing == [],
      do: :ok,
      else: {:error, {:missing_required, missing, action_str, schema}}
  end

  @spec check_unknown_params(map(), action_schema(), String.t()) ::
          :ok | {:error, {:unknown_params, [String.t()], String.t(), action_schema()}}
  defp check_unknown_params(data, schema, action_str) do
    allowed = schema |> Map.get(:properties, %{}) |> Map.keys() |> MapSet.new()
    unknown = data |> Map.keys() |> Enum.reject(&MapSet.member?(allowed, &1))

    if unknown == [],
      do: :ok,
      else: {:error, {:unknown_params, Enum.sort(unknown), action_str, schema}}
  end

  @spec check_required_one_of(map(), action_schema(), String.t()) ::
          :ok | {:error, tuple()}
  defp check_required_one_of(data, schema, action_str) do
    case Map.get(schema, :required_one_of, []) do
      [] ->
        :ok

      groups ->
        if Enum.any?(groups, &group_present?(&1, data)) do
          :ok
        else
          {:error, {:missing_required_groups, groups, action_str, schema}}
        end
    end
  end

  @spec group_present?([String.t()], map()) :: boolean()
  defp group_present?(group, data), do: Enum.all?(group, &Map.has_key?(data, &1))

  @spec format_groups([[String.t()]]) :: String.t()
  defp format_groups(groups) do
    Enum.map_join(groups, " OR ", fn group -> "(" <> Enum.join(group, " + ") <> ")" end)
  end

  @spec schema_summary(action_schema()) :: map()
  defp schema_summary(schema) do
    base = %{
      properties: schema.properties,
      required: Map.get(schema, :required, []),
      defaults: Map.get(schema, :defaults, %{})
    }

    case Map.get(schema, :required_one_of, []) do
      [] -> base
      groups -> Map.put(base, :required_one_of, groups)
    end
  end

  @spec apply_defaults(map(), map()) :: map()
  defp apply_defaults(data, defaults), do: Map.merge(defaults, data)

  @spec handle_result(module(), atom(), Wymcp.Context.t(), tuple()) ::
          {:ok, Context.content()} | {:ok, Context.content(), map()} | {:error, String.t()}
  defp handle_result(module, action, ctx, {:ok, response}) do
    {:ok, Context.json(maybe_add_context(response, module, action, ctx))}
  end

  defp handle_result(module, action, ctx, {:ok, response, hint_context}) do
    hints = module.hints(action, hint_context)

    response =
      if hints != [],
        do: Map.put(response, :hints, hints),
        else: response

    {:ok, Context.json(maybe_add_context(response, module, action, ctx))}
  end

  defp handle_result(module, action, ctx, {:error, reason, hint_context}) do
    message = module.handle_error(reason)
    hints = module.hints(action, hint_context)
    error_data = %{error: message}

    error_data =
      if hints != [],
        do: Map.put(error_data, :hints, hints),
        else: error_data

    error_data = maybe_add_context(error_data, module, action, ctx)

    {:error, JSON.encode!(error_data)}
  end

  defp handle_result(module, _action, _ctx, {:error, reason}) do
    {:error, module.handle_error(reason)}
  end

  # -- Definition helpers (called from generated definition/0) --

  # The help-pointer format lives here and nowhere else: both Wymcp.Help
  # and Wymcp.Tool.dispatch/4 render pointers through these two clauses.
  @doc false
  @spec help_pointer(module()) :: String.t()
  def help_pointer(module) do
    ~s|help {tool: "#{module.name()}"}|
  end

  @doc false
  @spec help_pointer(module(), String.t()) :: String.t()
  def help_pointer(module, action_str) do
    ~s|help {tool: "#{module.name()}", action: "#{action_str}"}|
  end

  # One home for the wrong-action answer. Wymcp.Help's action level and
  # Wymcp.Tool.dispatch/4's error branch are the same signal to a calling
  # LLM; building the payload twice invites two error dialects.
  @doc false
  @spec unknown_action_error(module(), String.t(), map()) :: {:error, String.t()}
  def unknown_action_error(module, action_name, actions) do
    valid = actions |> Map.keys() |> Enum.map(&Atom.to_string/1) |> Enum.sort()

    {:error,
     JSON.encode!(%{
       error: "unknown_action",
       message:
         "Unknown action '#{action_name}' for tool '#{module.name()}'. " <>
           "Valid actions: #{Enum.join(valid, ", ")}.",
       valid_actions: valid,
       help: help_pointer(module)
     })}
  end

  @doc false
  @spec maybe_put_title(map(), String.t() | nil) :: map()
  def maybe_put_title(definition_data, nil), do: definition_data

  def maybe_put_title(definition_data, title) when is_binary(title),
    do: Map.put(definition_data, "title", title)

  @doc false
  @spec maybe_put_annotations(map(), map() | nil) :: map()
  def maybe_put_annotations(definition_data, nil), do: definition_data

  def maybe_put_annotations(definition_data, %{} = ann) when map_size(ann) > 0,
    do: Map.put(definition_data, "annotations", ann)

  def maybe_put_annotations(definition_data, _), do: definition_data

  @doc false
  @spec maybe_put_output_schema(map(), map() | nil) :: map()
  def maybe_put_output_schema(definition_data, nil), do: definition_data

  def maybe_put_output_schema(definition_data, schema) when is_map(schema),
    do: Map.put(definition_data, "outputSchema", schema)

  # -- Helpers --

  @spec maybe_add_context(map(), module(), atom(), Wymcp.Context.t()) :: map()
  defp maybe_add_context(response, module, action, ctx) do
    case module.action_context(action, ctx) do
      nil -> response
      context when is_map(context) -> Map.put(response, :context, context)
    end
  end
end
