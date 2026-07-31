defmodule Wymcp.Testing do
  @moduledoc """
  Conveniences for testing Wymcp tools from a consuming application's
  test suite.

  Three groups of helpers:

  1. **Session setup** — `build_session_opts/1` builds the opts map
     `Wymcp.Session.init/1` requires, with a test default per key.

  2. **Direct tool testing** — `build_context/1` plus the `unwrap_*`
     extractors: assert on `{:ok, content}` / `{:error, message}` return
     values from `tool.run/2`, unit-testing a tool module in isolation.

  3. **HTTP response testing** — the `build_*_request` builders and
     `*_response` extractors: build `tools/call` bodies and pull content
     out of a `Plug.Conn` response body, integration-testing through
     `Wymcp.Router`.

  ## Direct tool testing

      ctx = Wymcp.Testing.build_context()
      assert {:ok, content} = MyTool.run(ctx, %{"input" => "value"})
      assert "expected" = Wymcp.Testing.unwrap_text(content)

  ## With assigns

      ctx = Wymcp.Testing.build_context(assigns: %{count: 0})
      assert {:ok, content, %{count: 1}} = CounterTool.run(ctx, %{})

  ## HTTP response testing

      conn = call_router(body)
      assert "expected" = Wymcp.Testing.text_response(conn)
  """

  alias Wymcp.{Context, ProtocolVersion}

  # -- Session setup helpers --

  @doc """
  Builds the opts map `Wymcp.Session.init/1` requires — the session opts:
  `protocol_version`, `client_capabilities`, `client_info`, `tools`, and
  `auth`, plus the optional `server` and `session_idle_timeout`.

  Every required key has a test-appropriate default; pass keyword
  overrides for the ones a test cares about. `protocol_version` defaults to
  `Wymcp.ProtocolVersion.latest/0`, so a session built here negotiates at
  whatever revision the library currently leads with. The two optional keys
  enter the map only when passed — `Wymcp.Session.init/1` applies its own
  defaults to their absence (`session_idle_timeout` in particular must be
  absent, not nil, to get the default).

  Callers keep their own start call: the same map serves
  `Wymcp.Session.start_session/1` and
  `Wymcp.Session.start_link({session_id, opts})` alike.

  ## Examples

      iex> Wymcp.Testing.build_session_opts().protocol_version
      "2025-11-25"

      iex> Wymcp.Testing.build_session_opts(tools: [MyTool]).tools
      [MyTool]

      iex> Map.has_key?(Wymcp.Testing.build_session_opts(), :server)
      false

  """
  def build_session_opts(overrides \\ []) when is_list(overrides) do
    Map.merge(
      %{
        protocol_version: ProtocolVersion.latest(),
        client_capabilities: %{},
        client_info: %{"name" => "test", "version" => "1.0"},
        tools: [],
        auth: nil
      },
      Map.new(overrides)
    )
  end

  # -- Direct tool testing helpers --

  @doc """
  Builds a `Wymcp.Context` for calling a tool's `run/2` directly, without
  a router or a session. Every field defaults to a test-appropriate value;
  pass overrides for the ones a test cares about (most often `:assigns`).
  A context built without `:session_pid` serves tools that do not message
  the session.

  ## Examples

      iex> Wymcp.Testing.build_context().session_id
      "test-session"

      iex> Wymcp.Testing.build_context(assigns: %{user: "u1"}).assigns
      %{user: "u1"}

  """
  def build_context(opts \\ []) do
    %Context{
      session_pid: opts[:session_pid],
      session_id: opts[:session_id] || "test-session",
      request_id: opts[:request_id] || 1,
      meta: opts[:meta],
      assigns: opts[:assigns] || %{}
    }
  end

  @doc """
  Extracts the text of a single-item text content array — the shape most
  tool responses have. Raises when the content is not exactly one text
  item.

  ## Examples

      iex> Wymcp.Testing.unwrap_text([%{"type" => "text", "text" => "done"}])
      "done"

  """
  def unwrap_text(content) do
    content |> unwrap_single() |> Map.fetch!("text")
  end

  @doc """
  Decodes the text of a single-item text content array as JSON — for
  tools that answer with `Wymcp.Context.json/1` content.

  ## Examples

      iex> Wymcp.Testing.unwrap_json([%{"type" => "text", "text" => ~s({"id": 7})}])
      %{"id" => 7}

  """
  def unwrap_json(content) do
    content |> unwrap_text() |> JSON.decode!()
  end

  @doc """
  Unwraps a one-item content array, raising with the full content in the
  message when there are zero or several items — the failure names what
  actually arrived instead of a bare `MatchError`.

  ## Examples

      iex> Wymcp.Testing.unwrap_single([%{"type" => "image"}])
      %{"type" => "image"}

  """
  def unwrap_single([item]), do: item

  def unwrap_single(content),
    do: raise("expected single content item, got: #{inspect(content)}")

  # -- HTTP response testing helpers --

  @doc """
  Builds a complete `tools/call` JSON-RPC request body for POSTing
  through the router (request id fixed at 1).

  ## Examples

      iex> Wymcp.Testing.build_call_request("tasks", %{"action" => "get"})["method"]
      "tools/call"

  """
  def build_call_request(tool_name, arguments) do
    %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => "tools/call",
      "params" => %{
        "name" => tool_name,
        "arguments" => arguments
      }
    }
  end

  @doc """
  Builds a `tools/call` request body for an action-dispatched tool:
  wraps the action name and optional `data` into the `arguments` object.
  An empty `data` is omitted rather than sent as an empty object.

  ## Examples

      iex> Wymcp.Testing.build_action_request("tasks", "get", %{"id" => "7"})["params"]["arguments"]
      %{"action" => "get", "data" => %{"id" => "7"}}

      iex> Wymcp.Testing.build_action_request("tasks", "list")["params"]["arguments"]
      %{"action" => "list"}

  """
  def build_action_request(tool_name, action, data \\ %{}) do
    args =
      if data == %{},
        do: %{"action" => action},
        else: %{"action" => action, "data" => data}

    build_call_request(tool_name, args)
  end

  @doc """
  Extracts the text of a successful single-item tool response from a
  router `Plug.Conn` — raising if the result is `isError: true`, so a
  test failure names the wrong branch instead of asserting on error text
  as if it were data.
  """
  def text_response(conn) do
    conn |> decode_result() |> check_success() |> get_content() |> unwrap_text()
  end

  @doc """
  Like `text_response/1`, then decodes the text as JSON — for tools that
  answer with `Wymcp.Context.json/1` content.
  """
  def json_response(conn) do
    conn |> text_response() |> JSON.decode!()
  end

  @doc """
  Extracts the text of an `isError: true` tool response from a router
  `Plug.Conn` — raising on a successful result, the mirror of
  `text_response/1`.
  """
  def error_response(conn) do
    conn |> decode_result() |> check_error() |> get_content() |> unwrap_text()
  end

  @doc """
  Extracts the single content item of a successful tool response — for
  image content, where the item map (`"data"`, `"mimeType"`) is the
  assertion target rather than a text field.
  """
  def image_response(conn) do
    conn |> decode_result() |> check_success() |> get_content() |> unwrap_single()
  end

  @doc """
  `image_response/1` for audio content: extracts the single content item
  of a successful tool response.
  """
  def audio_response(conn) do
    conn |> decode_result() |> check_success() |> get_content() |> unwrap_single()
  end

  defp decode_result(conn), do: JSON.decode!(conn.resp_body)

  defp check_success(%{"result" => %{"isError" => true}}),
    do: raise("expected success, got error")

  defp check_success(response), do: response

  defp check_error(%{"result" => %{"isError" => true}} = response), do: response
  defp check_error(_response), do: raise("expected error, got success")

  defp get_content(%{"result" => %{"content" => content}}), do: content
end
