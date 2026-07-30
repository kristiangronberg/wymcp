defmodule Wymcp.Testing do
  @moduledoc """
  Conveniences for testing Wymcp tools.

  Provides two sets of helpers:

  1. **Direct tool testing** — assert on `{:ok, content}` / `{:error, msg}`
     return values from `tool.run/2`. Use these when unit-testing a tool
     module in isolation.

  2. **HTTP response testing** — extract content from a `Plug.Conn`
     response body. Use these when integration-testing through the
     router.

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

  ## Related Modules

  See: `Wymcp.Context`, `Wymcp.Tool`
  """

  alias Wymcp.Context

  # -- Direct tool testing helpers --

  def build_context(opts \\ []) do
    %Context{
      session_pid: opts[:session_pid],
      session_id: opts[:session_id] || "test-session",
      request_id: opts[:request_id] || 1,
      meta: opts[:meta],
      assigns: opts[:assigns] || %{}
    }
  end

  def unwrap_text(content) do
    content |> unwrap_single() |> Map.fetch!("text")
  end

  def unwrap_json(content) do
    content |> unwrap_text() |> JSON.decode!()
  end

  def unwrap_single([item]), do: item

  def unwrap_single(content),
    do: raise("expected single content item, got: #{inspect(content)}")

  # -- HTTP response testing helpers --

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

  def build_action_request(tool_name, action, data \\ %{}) do
    args =
      if data == %{},
        do: %{"action" => action},
        else: %{"action" => action, "data" => data}

    build_call_request(tool_name, args)
  end

  def text_response(conn) do
    conn |> decode_result() |> check_success() |> get_content() |> unwrap_text()
  end

  def json_response(conn) do
    conn |> text_response() |> JSON.decode!()
  end

  def error_response(conn) do
    conn |> decode_result() |> check_error() |> get_content() |> unwrap_text()
  end

  def image_response(conn) do
    conn |> decode_result() |> check_success() |> get_content() |> unwrap_single()
  end

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
