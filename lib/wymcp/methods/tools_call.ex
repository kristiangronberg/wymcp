defmodule Wymcp.Methods.ToolsCall do
  @moduledoc false

  require Logger

  import Wymcp.Response
  alias Wymcp.{Context, JsonRpc, Session}

  @spec run(Plug.Conn.t(), [module()]) :: Plug.Conn.t()
  def run(%Plug.Conn{} = conn, compile_tools) do
    request = conn.body_params
    params = request["params"] || %{}
    name = params["name"]
    arguments = params["arguments"]
    tools = resolve_tools(conn, compile_tools)

    cond do
      is_nil(name) or not is_binary(name) ->
        send_json(
          conn,
          JsonRpc.error_response(:invalid_params, request["id"], %{
            reason: "Missing or invalid 'name' in params"
          })
        )

      is_nil(arguments) or not is_map(arguments) ->
        send_json(
          conn,
          JsonRpc.error_response(:invalid_params, request["id"], %{
            reason: "Missing or invalid 'arguments' in params"
          })
        )

      true ->
        execute_tool(conn, tools, name, arguments)
    end
  end

  @spec resolve_tools(Plug.Conn.t(), [module()]) :: [module()]
  defp resolve_tools(conn, compile_tools) do
    case conn.assigns[:wymcp_session_pid] do
      nil -> compile_tools
      pid -> Session.get_tools(pid)
    end
  end

  defp execute_tool(conn, tools, name, arguments) do
    request = conn.body_params

    with {:ok, tool} <- get_tool(tools, name),
         :ok <- validate_arguments(tool, arguments) do
      ctx = build_context(conn)
      start_time = System.monotonic_time()
      Wymcp.Telemetry.emit(:tool, :start, %{}, %{tool_name: name, session_id: ctx.session_id})

      try do
        result =
          case tool.run(ctx, arguments) do
            {:ok, content} ->
              send_tool_result(conn, request, tool, content, false)

            {:ok, content, assigns_updates} when is_map(assigns_updates) ->
              persist_assigns(conn, assigns_updates)
              send_tool_result(conn, request, tool, content, false)

            {:error, message} ->
              send_tool_result(
                conn,
                request,
                tool,
                [%{"type" => "text", "text" => message}],
                true
              )
          end

        duration = System.monotonic_time() - start_time
        Wymcp.Telemetry.emit(:tool, :stop, %{duration: duration}, %{tool_name: name})
        result
      rescue
        e ->
          duration = System.monotonic_time() - start_time

          Wymcp.Telemetry.emit(:tool, :error, %{duration: duration}, %{
            tool_name: name,
            error: Exception.message(e)
          })

          Logger.error("Tool #{name} raised: #{Exception.message(e)}")
          send_json(conn, JsonRpc.error_response(:internal_error, request["id"], %{}))
      end
    else
      {:error, :not_found} -> tool_not_found(conn, request)
      {:error, {:invalid_params, reason}} -> invalid_params(conn, request, reason)
    end
  end

  @spec send_tool_result(Plug.Conn.t(), map(), module(), list(), boolean()) :: Plug.Conn.t()
  defp send_tool_result(conn, request, tool, content, is_error) do
    result =
      %{"content" => content, "isError" => is_error}
      |> maybe_add_structured_content(tool, content, is_error)
      |> maybe_add_warning(conn)

    response = JsonRpc.success_response(request["id"], result)
    send_json(conn, response)
  end

  @spec maybe_add_warning(map(), Plug.Conn.t()) :: map()
  defp maybe_add_warning(result, conn) do
    case conn.assigns[:wymcp_session_warning] do
      nil -> result
      warning -> put_in(result, ["_meta"], %{"warnings" => [warning]})
    end
  end

  @spec maybe_add_structured_content(map(), module(), list(), boolean()) :: map()
  defp maybe_add_structured_content(result, tool, content, is_error) do
    case tool.output_schema() do
      nil ->
        result

      schema when is_map(schema) and not is_error ->
        structured = extract_structured_content(content)

        case JsonRpc.validate_schema(schema, structured) do
          :ok ->
            Map.put(result, "structuredContent", structured)

          {:error, reason} ->
            Logger.warning("Tool #{tool.name()} output_schema validation failed: #{reason}")
            result
        end

      _ ->
        result
    end
  end

  @spec extract_structured_content(list()) :: map()
  defp extract_structured_content(content) do
    case content do
      [%{"type" => "text", "text" => json_text}] ->
        case JSON.decode(json_text) do
          {:ok, decoded} when is_map(decoded) -> decoded
          _ -> %{}
        end

      _ ->
        %{}
    end
  end

  @spec build_context(Plug.Conn.t()) :: Context.t()
  defp build_context(conn) do
    request = conn.body_params
    meta = get_in(request, ["params", "_meta"])
    session_pid = conn.assigns[:wymcp_session_pid]

    session_assigns =
      if session_pid && Process.alive?(session_pid) do
        Session.get_state(session_pid).assigns
      else
        %{}
      end

    # Merge conn.assigns (per-request, from plugs like auth) as the base layer,
    # with session assigns taking precedence (accumulated tool state).
    # Filter out internal wymcp keys to avoid leaking framework plumbing.
    conn_assigns = filter_internal_assigns(conn.assigns)
    assigns = Map.merge(conn_assigns, session_assigns)

    %Context{
      session_pid: session_pid,
      session_id: conn.assigns[:wymcp_session_id],
      request_id: request["id"],
      meta: meta,
      assigns: assigns
    }
  end

  @spec filter_internal_assigns(map()) :: map()
  defp filter_internal_assigns(assigns) do
    Map.reject(assigns, fn {key, _value} ->
      key == :wymcp or (is_atom(key) and String.starts_with?(Atom.to_string(key), "wymcp_"))
    end)
  end

  @spec persist_assigns(Plug.Conn.t(), map()) :: :ok
  defp persist_assigns(conn, assigns_updates) do
    session_pid = conn.assigns[:wymcp_session_pid]

    if session_pid && Process.alive?(session_pid) do
      Session.put_assigns(session_pid, assigns_updates)
    end

    :ok
  end

  @spec get_tool([module()], String.t()) :: {:ok, module()} | {:error, :not_found}
  defp get_tool(tools, name) do
    case Enum.find(tools, &(&1.name() == name)) do
      nil -> {:error, :not_found}
      tool -> {:ok, tool}
    end
  end

  @spec validate_arguments(module(), map()) :: :ok | {:error, {:invalid_params, String.t()}}
  defp validate_arguments(_tool, %{"action" => action}) when action in ["help", "describe"],
    do: :ok

  defp validate_arguments(tool, arguments) do
    case Wymcp.JsonRpc.validate_schema(tool.input_schema(), arguments) do
      :ok -> :ok
      {:error, reason} -> {:error, {:invalid_params, reason}}
    end
  end

  @spec tool_not_found(Plug.Conn.t(), map()) :: Plug.Conn.t()
  defp tool_not_found(conn, request) do
    data = %{original_request: request}
    response = JsonRpc.error_response(:method_not_found, request["id"], data)
    send_json(conn, response)
  end

  @spec invalid_params(Plug.Conn.t(), map(), String.t()) :: Plug.Conn.t()
  defp invalid_params(conn, request, reason) do
    data = %{error: reason, original_request: request}
    response = JsonRpc.error_response(:invalid_params, request["id"], data)
    send_json(conn, response)
  end
end
