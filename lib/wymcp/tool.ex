defmodule Wymcp.Tool do
  @moduledoc """
  Behaviour for MCP tools using the action-dispatched pattern.

  Each tool exposes multiple actions under a single tool name. The
  `use Wymcp.Tool` macro generates a spec-compliant `inputSchema` with
  `oneOf` variants from `actions/0`, handles dispatch via `run_action/2`,
  validates required fields, rejects unknown parameters (when
  `strict_params?/0`), applies defaults, injects hints, and formats
  errors.

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

  - `:description` — human-readable description (appears in oneOf schema)
  - `:properties` — JSON Schema properties for the action's `data` parameter

  Optional fields:

  - `:required` — list of unconditionally required property names (defaults to `[]`).
    Every listed field must be present in `data` (AND-semantics).
  - `:required_one_of` — list of groups, where each group is a list of property
    names. At least one group must be fully present (OR-of-AND semantics).
    Combines with `:required` — both checks run, both must pass. Surfaces in
    `help` output and is rendered into the `inputSchema` as `anyOf` on the
    action variant's `data`.
  - `:defaults` — map of default values merged into `data` before dispatch
    (defaults to `%{}`).
  - `:notes` — long-form notes returned by `describe` and `help` with topic.
  - `:related` — list of related action name strings returned by `describe`.
  - `:examples` — list of example payload maps returned by `describe`.

  Defaults are applied after validation: values supplied via `:defaults`
  do not count toward satisfying `:required` or `:required_one_of`. Both
  checks run against the caller's `data` as received.

  Action schemas are validated at server boot via `Wymcp.Router.init/1`. A
  malformed schema (e.g. a `:required_one_of` group referencing a field not
  declared in `:properties`) raises `ArgumentError` immediately, surfacing
  the misconfiguration before any request is served.

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

  ### Slim mode trade-off for `:required_one_of`

  In slim schema mode (`schema_mode/0` returns `:slim`), the `inputSchema`
  emitted by `tools/list` does not encode per-action constraints — it only
  lists action names and one-line descriptions. `:required_one_of` is
  therefore visible to clients only via the `help`/`describe` round-trip.
  Full schema mode (default) renders the constraint as `anyOf` on the
  variant's `data`.

  ## Built-in `help` and `describe` actions

  Every tool exposes two built-in introspection actions:

  - `help` — terse listing. With no topic: `{action_name => {description, required}}`.
    With a topic: slim schema for that action.
  - `describe` — full listing. With no topic: full schema for every action
    (properties, defaults, notes, examples). With a topic: full schema for that
    action.

  ## Return values from `run_action/2`

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
  - `schema_mode/0` — returns `:full` (default) or `:slim`. Slim mode emits a
    compact `tools/list` schema with action names and one-liners instead of full
    `oneOf` variants.
  - `strict_params?/0` — returns `true` (default) or `false`. When `true`,
    `dispatch` rejects any key in `data` not declared in the action's
    `:properties`, returning an `unknown_params` error instead of silently
    ignoring it. Set to `false` to preserve the permissive legacy behavior.
  - `action_context/2` — returns a map of runtime context for the given
    action, or `nil`. Receives `(action_atom, ctx)`, where `ctx` is the
    same `Wymcp.Context.t()` passed to `run_action/3`. Called during
    help (with topic), describe (with topic), and normal action
    dispatch. The map appears under a `"context"` key in the response.
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
          D --> H["help / describe"]
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

  ## Related Modules

  See: `Wymcp.Tool.Schema` — builds oneOf JSON Schema from action definitions

  ## Tests

  See: `test/wymcp/tool_test.exs`
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
  @callback schema_mode() :: :full | :slim
  @callback strict_params?() :: boolean()
  @callback action_context(action :: atom(), ctx :: Wymcp.Context.t()) :: map() | nil
  @callback title() :: String.t() | nil
  @callback annotations() :: map() | nil
  @callback output_schema() :: map() | nil

  @optional_callbacks hints: 2,
                      handle_error: 1,
                      schema_mode: 0,
                      strict_params?: 0,
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

      @spec schema_mode() :: :full | :slim
      def schema_mode, do: :full

      @spec strict_params?() :: boolean()
      def strict_params?, do: true

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
                     schema_mode: 0,
                     strict_params?: 0,
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
        Wymcp.Tool.Schema.build(actions(), schema_mode())
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

  # -- Boot-time validation --

  @doc """
  Validate every action schema in `module`. Raises `ArgumentError` with a
  descriptive message on the first malformed action.

  Called by `Wymcp.Router.init/1` so that misconfigured tools fail at boot
  rather than at the first request.
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
    properties = Map.get(schema, :properties, %{})

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
  def dispatch(module, ctx, "help", data) do
    actions = module.actions()
    data = data || %{}

    case Map.get(data, "topic") do
      nil ->
        {:ok, Context.json(action_summary(module, actions))}

      topic ->
        case fetch_action(actions, topic) do
          {:ok, action_atom, action, schema} ->
            response = %{action: action, schema: slim_action_schema(schema)}
            {:ok, Context.json(maybe_add_context(response, module, action_atom, ctx))}

          {:error, :unknown_action} ->
            {:error, "Unknown action: #{topic}"}
        end
    end
  end

  def dispatch(module, ctx, "describe", data) do
    actions = module.actions()
    data = data || %{}

    case Map.get(data, "topic") do
      nil ->
        {:ok, Context.json(full_action_listing(module, actions))}

      topic ->
        case fetch_action(actions, topic) do
          {:ok, action_atom, action, schema} ->
            full =
              Map.take(schema, [
                :description,
                :properties,
                :required,
                :required_one_of,
                :defaults,
                :notes,
                :related,
                :examples
              ])

            response = %{action: action, schema: full}
            {:ok, Context.json(maybe_add_context(response, module, action_atom, ctx))}

          {:error, :unknown_action} ->
            {:error, "Unknown action: #{topic}"}
        end
    end
  end

  def dispatch(module, ctx, action_str, data) do
    actions = module.actions()
    data = data || %{}

    with {:ok, action} <- parse_action(action_str, actions),
         schema = Map.fetch!(actions, action),
         :ok <- check_required(data, schema, action_str),
         :ok <- check_required_one_of(data, schema, action_str),
         :ok <- check_unknown_params(data, schema, action_str, module.strict_params?()) do
      merged = apply_defaults(data, Map.get(schema, :defaults, %{}))
      handle_result(module, action, ctx, module.run_action(action, merged, ctx))
    else
      {:error, :unknown_action} ->
        {:error, "Unknown action: #{action_str}"}

      {:error, {:missing_required, missing, action_str, schema}} ->
        {:ok,
         Context.json(%{
           error: "missing_required_fields",
           message: "Required fields missing: #{Enum.join(missing, ", ")}",
           missing: missing,
           action: action_str,
           input_schema: schema_summary(schema)
         })}

      {:error, {:missing_required_groups, groups, action_str, schema}} ->
        {:ok,
         Context.json(%{
           error: "missing_required_group",
           message:
             "At least one of these field groups must be fully present: " <>
               format_groups(groups),
           required_one_of: groups,
           action: action_str,
           input_schema: schema_summary(schema)
         })}

      {:error, {:unknown_params, unknown, action_str, schema}} ->
        {:ok,
         Context.json(%{
           error: "unknown_params",
           message:
             "Unknown parameter(s) for action '#{action_str}': #{Enum.join(unknown, ", ")}. " <>
               "These are rejected rather than silently ignored. " <>
               "Use 'help' or 'describe' with this action to see valid parameters.",
           unknown: unknown,
           action: action_str,
           input_schema: schema_summary(schema)
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

  @spec check_unknown_params(map(), action_schema(), String.t(), boolean()) ::
          :ok | {:error, {:unknown_params, [String.t()], String.t(), action_schema()}}
  defp check_unknown_params(_data, _schema, _action_str, false), do: :ok

  defp check_unknown_params(data, schema, action_str, true) do
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

  @spec action_summary(module(), map()) :: map()
  defp action_summary(module, actions) do
    summary =
      Map.new(actions, fn {action, schema} ->
        entry = %{
          description: schema.description,
          required: Map.get(schema, :required, [])
        }

        entry =
          case Map.get(schema, :required_one_of, []) do
            [] -> entry
            groups -> Map.put(entry, :required_one_of, groups)
          end

        {Atom.to_string(action), entry}
      end)

    %{tool: module.name(), actions: summary}
  end

  @spec full_action_listing(module(), map()) :: map()
  defp full_action_listing(module, actions) do
    actions_map =
      Enum.into(actions, %{}, fn {action_atom, schema} ->
        full =
          Map.take(schema, [
            :description,
            :properties,
            :required,
            :required_one_of,
            :defaults,
            :notes,
            :related,
            :examples
          ])

        {Atom.to_string(action_atom), full}
      end)

    %{tool: module.name(), actions: actions_map}
  end

  @spec slim_action_schema(action_schema()) :: map()
  defp slim_action_schema(schema) do
    properties =
      Map.new(schema.properties, fn {name, prop} ->
        {name, Map.take(prop, ["type", "description"])}
      end)

    base = %{
      description: schema.description,
      required: Map.get(schema, :required, []),
      properties: properties
    }

    case Map.get(schema, :required_one_of, []) do
      [] -> base
      groups -> Map.put(base, :required_one_of, groups)
    end
  end

  @spec fetch_action(map(), String.t()) ::
          {:ok, atom(), String.t(), map()} | {:error, :unknown_action}
  defp fetch_action(actions, topic) do
    atom = String.to_existing_atom(topic)

    if Map.has_key?(actions, atom),
      do: {:ok, atom, topic, Map.fetch!(actions, atom)},
      else: {:error, :unknown_action}
  rescue
    ArgumentError -> {:error, :unknown_action}
  end

  @spec maybe_add_context(map(), module(), atom(), Wymcp.Context.t()) :: map()
  defp maybe_add_context(response, module, action, ctx) do
    case module.action_context(action, ctx) do
      nil -> response
      context when is_map(context) -> Map.put(response, :context, context)
    end
  end
end
