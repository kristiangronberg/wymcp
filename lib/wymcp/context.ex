defmodule Wymcp.Context do
  @moduledoc """
  Tool execution context and result builders.

  Every tool receives a `%Context{}` as its first argument. The struct
  carries the session reference, request metadata, and per-session
  assigns. Module functions build MCP-compliant content arrays that
  tools return in their result tuples.

  ## Assigns

  The `assigns` field contains the merged result of per-request
  `conn.assigns` (set by upstream plugs like auth) and per-session state
  (set by previous tool calls or during initialization). Session assigns
  take precedence over conn.assigns when keys collide — this ensures
  accumulated tool state is not overwritten by plug defaults.

  This means auth plugs can store data in `conn.assigns` and tools will
  see it in `ctx.assigns` without any process dictionary workarounds:

      # In your auth plug:
      {:ok, Plug.Conn.assign(conn, :current_scope, scope)}

      # In your tool's run_action:
      def run_action(:create, data, ctx) do
        scope = ctx.assigns[:current_scope]
        # ...
      end

  Internal wymcp keys (`:wymcp`, `:wymcp_session_pid`, etc.) are filtered
  out and not visible in `ctx.assigns`.

  Tools can update session-persistent assigns by returning
  `{:ok, content, assigns_updates}` where `assigns_updates` is a map
  that gets merged into the session's assigns for future requests.

  ## Design decisions

  Result builders (`text/1`, `json/1`, `image/2`, `audio/2`) are pure
  functions — no side effects, no process messages. This makes tools
  easy to test in isolation. The `%Context{}` struct is there for future
  phases when tools need to call `sample/3` or `elicit/4`, which
  communicate with the session GenServer.

  The deliberate split between "build content" (pure) and "interact
  with session" (effectful) keeps the common case simple: most tools
  just compute a result and return it.

  ```mermaid
  sequenceDiagram
      autonumber
      participant T as Tool
      participant C as Context
      participant S as Session
      participant SM as StreamManager
      participant CL as Client

      T->>C: sample(ctx, prompt) or elicit(ctx, message, schema)
      C->>S: check_capability
      S-->>C: :ok
      C->>S: await_client_response(request_id, message, timeout)
      S->>SM: push request via SSE
      SM->>CL: SSE event
      Note over S: Caller blocked (deferred reply)
      CL->>S: POST response (deliver_response)
      S-->>C: {:ok, result}
      C-->>T: {:ok, result}
  ```

  ## Related Modules

  See: `Wymcp.Tool`, `Wymcp.Session`

  ## Tests

  See: `Wymcp.ContextTest`
  """

  defstruct [:session_pid, :session_id, :request_id, :meta, assigns: %{}]

  @type t :: %__MODULE__{
          session_pid: pid() | nil,
          session_id: String.t() | nil,
          request_id: term(),
          meta: map() | nil,
          assigns: map()
        }

  @type content :: [map()]

  @spec text(String.t()) :: content()
  def text(text) when is_binary(text) do
    [%{"type" => "text", "text" => text}]
  end

  @spec json(term()) :: content()
  def json(data) do
    text(JSON.encode!(data))
  end

  @spec image(String.t(), String.t()) :: content()
  def image(base64_data, mime_type)
      when is_binary(base64_data) and is_binary(mime_type) do
    [%{"type" => "image", "data" => base64_data, "mimeType" => mime_type}]
  end

  @spec audio(String.t(), String.t()) :: content()
  def audio(base64_data, mime_type)
      when is_binary(base64_data) and is_binary(mime_type) do
    [%{"type" => "audio", "data" => base64_data, "mimeType" => mime_type}]
  end

  @spec progress_token(t()) :: String.t() | integer() | nil
  def progress_token(%__MODULE__{meta: nil}), do: nil
  def progress_token(%__MODULE__{meta: meta}), do: Map.get(meta, "progressToken")

  @doc """
  Sends a progress notification to the client via the SSE stream.

  Only sends if the request included a `progressToken` in `_meta`.
  The `progress` value must increase with each call. The `total`
  and `message` parameters are optional.

  No-ops silently when there is no progress token or no session —
  this lets tools call report_progress unconditionally without
  checking whether the client requested progress updates.
  """
  @spec report_progress(t(), number(), number() | nil, String.t() | nil) :: :ok
  def report_progress(ctx, progress, total \\ nil, message \\ nil)

  def report_progress(%__MODULE__{session_pid: nil}, _progress, _total, _message), do: :ok

  def report_progress(%__MODULE__{} = ctx, progress, total, message) do
    case progress_token(ctx) do
      nil ->
        :ok

      token ->
        params = %{"progressToken" => token, "progress" => progress}
        params = if total, do: Map.put(params, "total", total), else: params
        params = if message, do: Map.put(params, "message", message), else: params

        notification = %{
          "jsonrpc" => "2.0",
          "method" => "notifications/progress",
          "params" => params
        }

        Wymcp.Session.push_event(ctx.session_pid, notification)
        :ok
    end
  end

  @log_level_order %{
    "debug" => 0,
    "info" => 1,
    "notice" => 2,
    "warning" => 3,
    "error" => 4,
    "critical" => 5,
    "alert" => 6,
    "emergency" => 7
  }

  @doc """
  Sends a log message notification to the client via the SSE stream.

  The message is filtered against the session's configured log level
  (set via `logging/setLevel`). Messages below the threshold are
  silently dropped. When no level has been configured, all messages
  are sent.

  The `data` parameter can be any JSON-serializable term — a string
  for simple messages, or a map/list for structured data.
  """
  @spec log(t(), String.t(), term(), keyword()) :: :ok
  def log(ctx, level, data, opts \\ [])

  def log(%__MODULE__{session_pid: nil}, _level, _data, _opts), do: :ok

  def log(%__MODULE__{session_pid: pid}, level, data, opts) do
    if should_log?(pid, level) do
      params = %{"level" => level, "data" => data}

      params =
        case Keyword.get(opts, :logger) do
          nil -> params
          name -> Map.put(params, "logger", name)
        end

      notification = %{
        "jsonrpc" => "2.0",
        "method" => "notifications/message",
        "params" => params
      }

      Wymcp.Session.push_event(pid, notification)
      :ok
    else
      :ok
    end
  end

  @spec should_log?(pid(), String.t()) :: boolean()
  defp should_log?(pid, level) do
    state = Wymcp.Session.get_state(pid)

    case state.log_level do
      nil ->
        true

      threshold ->
        Map.get(@log_level_order, level, 0) >= Map.get(@log_level_order, threshold, 0)
    end
  end

  @default_sample_timeout 30_000
  @default_elicit_timeout 120_000

  @doc """
  Asks the client's LLM a question mid-tool-execution.

  Pushes a `sampling/createMessage` request to the client via the SSE
  stream and blocks until the client responds. The client has full
  discretion over model selection, prompt modification, and approval.

  `opts` are merged into the `params` of the request. Common options:
  - `"maxTokens"` (integer, required by spec but defaults to 1024)
  - `"modelPreferences"` (map with `"hints"`, priority axes)
  - `"systemPrompt"` (string)
  - `"temperature"` (float)

  Returns `{:error, :not_supported}` if the client did not declare
  `sampling` capability. Returns `{:error, :no_session}` if called
  outside a session (e.g. in a unit test with nil session_pid).
  """
  @spec sample(t(), String.t(), map()) ::
          {:ok, map()} | {:error, :no_session | :no_stream | :not_supported | :timeout | map()}
  def sample(ctx, prompt, opts \\ %{})

  def sample(%__MODULE__{session_pid: nil}, _prompt, _opts), do: {:error, :no_session}

  def sample(%__MODULE__{session_pid: pid}, prompt, opts) do
    with :ok <- check_capability(pid, "sampling") do
      request_id = generate_request_id()
      max_tokens = Map.get(opts, "maxTokens", 1024)

      params =
        Map.merge(
          %{
            "messages" => [
              %{"role" => "user", "content" => %{"type" => "text", "text" => prompt}}
            ],
            "maxTokens" => max_tokens
          },
          Map.drop(opts, ["maxTokens"])
        )

      message = %{
        "jsonrpc" => "2.0",
        "id" => request_id,
        "method" => "sampling/createMessage",
        "params" => params
      }

      timeout = Map.get(opts, :timeout, @default_sample_timeout)
      Wymcp.Session.await_client_response(pid, request_id, message, timeout)
    end
  end

  @doc """
  Asks the human user for structured input mid-tool-execution (form mode).

  Pushes an `elicitation/create` request to the client via the SSE
  stream and blocks until the user responds. The client renders a form
  based on the JSON Schema and returns typed, validated data.

  The `schema` must be a flat JSON Schema object (primitive properties
  only, no nested objects). The client renders appropriate UI controls
  for each field type.

  The response includes an `"action"` field: `"accept"` (user submitted),
  `"decline"` (user refused), or `"cancel"` (user dismissed). When
  action is `"accept"`, `"content"` contains the validated form data.
  """
  @spec elicit(t(), String.t(), map(), map()) ::
          {:ok, map()} | {:error, :no_session | :no_stream | :not_supported | :timeout | map()}
  def elicit(ctx, message, schema, opts \\ %{})

  def elicit(%__MODULE__{session_pid: nil}, _message, _schema, _opts),
    do: {:error, :no_session}

  def elicit(%__MODULE__{session_pid: pid}, message, schema, opts) do
    with :ok <- check_capability(pid, "elicitation") do
      request_id = generate_request_id()

      params = %{
        "message" => message,
        "requestedSchema" => schema
      }

      request = %{
        "jsonrpc" => "2.0",
        "id" => request_id,
        "method" => "elicitation/create",
        "params" => params
      }

      timeout = Map.get(opts, :timeout, @default_elicit_timeout)
      Wymcp.Session.await_client_response(pid, request_id, request, timeout)
    end
  end

  @spec check_capability(pid(), String.t()) :: :ok | {:error, :not_supported}
  defp check_capability(pid, capability) do
    state = Wymcp.Session.get_state(pid)

    if Map.has_key?(state.client_capabilities, capability) do
      :ok
    else
      {:error, :not_supported}
    end
  end

  @spec generate_request_id() :: String.t()
  defp generate_request_id do
    "srv-" <> Base.url_encode64(:crypto.strong_rand_bytes(8), padding: false)
  end
end
