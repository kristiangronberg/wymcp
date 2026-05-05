defmodule Wymcp.Tool do
  @moduledoc """
  Behaviour for MCP tools using the action-dispatched pattern.

  Each tool exposes multiple actions under a single tool name. The
  `use Wymcp.Tool` macro generates a spec-compliant `inputSchema` with
  `oneOf` variants from `actions/0`, handles dispatch via `run_action/2`,
  validates required fields, applies defaults, injects hints, and formats
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
  - `:required` — list of required property names (strings)
  - `:defaults` — map of default values merged into `data` before dispatch

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
          description: String.t(),
          properties: map(),
          required: [String.t()],
          defaults: map()
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
  @callback action_context(action :: atom(), ctx :: Wymcp.Context.t()) :: map() | nil
  @callback title() :: String.t() | nil
  @callback annotations() :: map() | nil
  @callback output_schema() :: map() | nil

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
        with {:ok, action_atom, action, schema} <- fetch_action(actions, topic) do
          response = %{action: action, schema: slim_action_schema(schema)}
          {:ok, Context.json(maybe_add_context(response, module, action_atom, ctx))}
        else
          {:error, :unknown_action} -> {:error, "Unknown action: #{topic}"}
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
        with {:ok, action_atom, action, schema} <- fetch_action(actions, topic) do
          full =
            Map.take(schema, [
              :description,
              :properties,
              :required,
              :defaults,
              :notes,
              :related,
              :examples
            ])

          response = %{action: action, schema: full}
          {:ok, Context.json(maybe_add_context(response, module, action_atom, ctx))}
        else
          {:error, :unknown_action} -> {:error, "Unknown action: #{topic}"}
        end
    end
  end

  def dispatch(module, ctx, action_str, data) do
    actions = module.actions()
    data = data || %{}

    with {:ok, action} <- parse_action(action_str, actions),
         schema = Map.fetch!(actions, action),
         :ok <- check_required(data, schema, action_str),
         merged = apply_defaults(data, schema.defaults) do
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
           input_schema: %{
             properties: schema.properties,
             required: schema.required,
             defaults: schema.defaults
           }
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
    missing = Enum.reject(schema.required, &Map.has_key?(data, &1))

    if missing == [],
      do: :ok,
      else: {:error, {:missing_required, missing, action_str, schema}}
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
        {Atom.to_string(action), %{description: schema.description, required: schema.required}}
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

    %{description: schema.description, required: schema.required, properties: properties}
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
