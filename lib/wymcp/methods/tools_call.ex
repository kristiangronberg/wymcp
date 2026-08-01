defmodule Wymcp.Methods.ToolsCall do
  @moduledoc false

  require Logger

  import Wymcp.Response
  alias Wymcp.{Context, JsonRpc, ProtocolVersion, Session}

  def run(%Plug.Conn{} = conn, compile_tools) do
    request = conn.body_params
    params = request["params"] || %{}
    name = params["name"]
    arguments = default_arguments(params["arguments"])
    tools = resolve_tools(conn, compile_tools)

    cond do
      is_nil(name) or not is_binary(name) ->
        send_json(
          conn,
          JsonRpc.error_response(:invalid_params, request["id"], %{
            reason: "Missing or invalid 'name' in params"
          })
        )

      not is_map(arguments) ->
        send_json(
          conn,
          JsonRpc.error_response(:invalid_params, request["id"], %{
            reason: "Invalid 'arguments' in params: expected an object"
          })
        )

      true ->
        execute_tool(conn, tools, name, arguments)
    end
  end

  defp resolve_tools(conn, _compile_tools) do
    Session.get_tools(conn.assigns[:wymcp_session_pid])
  end

  # Absent and JSON-null arguments are indistinguishable after decode; the
  # MCP schema (CallToolRequestParams) requires only "name", so both read as
  # the empty object. Present-but-not-an-object (5, "x", false) stays -32602
  # in run/2's cond — which is why this is not `arguments || %{}`.
  defp default_arguments(nil), do: %{}
  defp default_arguments(arguments), do: arguments

  defp execute_tool(conn, tools, name, arguments) do
    request = conn.body_params

    with {:ok, tool} <- get_tool(tools, name),
         :ok <- validate_arguments(tool, arguments) do
      ctx = build_context(conn)
      action = arguments["action"]
      start_time = System.monotonic_time()

      Wymcp.Telemetry.emit(:tool, :start, %{}, %{
        tool_name: name,
        action: action,
        session_id: ctx.session_id
      })

      try do
        {content, is_error, error_kind} =
          case tool.run(ctx, arguments) do
            {:ok, content} ->
              {content, false, nil}

            {:ok, content, assigns_updates} when is_map(assigns_updates) ->
              persist_assigns(conn, assigns_updates)
              {content, false, nil}

            {:error, message} ->
              {Context.text(message), true, :tool}

            # The kind vocabulary is deliberately closed here: an
            # off-contract third element (e.g. run_action's hint-context
            # map escaping a hand-written run/2) must crash into the
            # rescue below, not leak into telemetry.
            {:error, message, kind} when kind in [:dispatch, :tool] ->
              {Context.text(message), true, kind}
          end

        result = send_tool_result(conn, request, tool, content, is_error)
        duration = System.monotonic_time() - start_time

        Wymcp.Telemetry.emit(:tool, :stop, %{duration: duration}, %{
          tool_name: name,
          action: action,
          session_id: ctx.session_id,
          is_error: is_error,
          error_kind: error_kind
        })

        result
      rescue
        e ->
          duration = System.monotonic_time() - start_time

          Wymcp.Telemetry.emit(:tool, :error, %{duration: duration}, %{
            tool_name: name,
            action: action,
            session_id: ctx.session_id,
            request_id: request["id"],
            exception: inspect(e.__struct__),
            error: Exception.message(e)
          })

          Logger.error("Tool #{name} raised: #{Exception.message(e)}",
            crash_reason: {e, __STACKTRACE__}
          )

          diagnostic = %{
            errorType: "tool_raised",
            tool: name,
            exception: inspect(e.__struct__),
            message: Exception.message(e)
          }

          content = [%{"type" => "text", "text" => JSON.encode!(diagnostic)}]
          send_tool_result(conn, request, tool, content, true)
      end
    else
      {:error, :not_found} -> tool_not_found(conn, request)
      {:error, {:invalid_params, reason}} -> invalid_params(conn, request, reason)
    end
  end

  defp send_tool_result(conn, request, tool, content, is_error) do
    version = Session.negotiated_version(conn)

    result =
      %{"content" => content, "isError" => is_error}
      |> maybe_add_structured_content(tool, content, is_error)
      |> ProtocolVersion.strip_tool_call_result(version)

    response = JsonRpc.success_response(request["id"], result)
    send_json(conn, response)
  end

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

  defp build_context(conn) do
    request = conn.body_params
    meta = get_in(request, ["params", "_meta"])
    session_pid = conn.assigns[:wymcp_session_pid]
    session_assigns = Session.get_state(session_pid).assigns

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

  defp filter_internal_assigns(assigns) do
    Map.reject(assigns, fn {key, _value} ->
      key == :wymcp or (is_atom(key) and String.starts_with?(Atom.to_string(key), "wymcp_"))
    end)
  end

  defp persist_assigns(conn, assigns_updates) do
    session_pid = conn.assigns[:wymcp_session_pid]
    Session.put_assigns(session_pid, assigns_updates)
    :ok
  end

  defp get_tool(tools, name) do
    case Enum.find(tools, &(&1.name() == name)) do
      nil -> {:error, :not_found}
      tool -> {:ok, tool}
    end
  end

  defp validate_arguments(tool, arguments) do
    schema = drop_action_enum(tool.input_schema())

    case Wymcp.JsonRpc.validate_schema(schema, arguments) do
      :ok -> :ok
      {:error, reason} -> {:error, {:invalid_params, reason}}
    end
  end

  # The action enum is published in tools/list for upfront guidance;
  # membership is checked in Wymcp.Tool.dispatch/4 so a wrong action gets a
  # structured isError answer naming the valid actions, not a -32602.
  defp drop_action_enum(
         %{"properties" => %{"action" => %{"enum" => _} = action_schema} = properties} = schema
       ) do
    %{schema | "properties" => %{properties | "action" => Map.delete(action_schema, "enum")}}
  end

  defp drop_action_enum(schema), do: schema

  defp tool_not_found(conn, request) do
    data = %{original_request: request}
    response = JsonRpc.error_response(:method_not_found, request["id"], data)
    send_json(conn, response)
  end

  defp invalid_params(conn, request, reason) do
    data = %{error: reason, original_request: request}
    response = JsonRpc.error_response(:invalid_params, request["id"], data)
    send_json(conn, response)
  end
end
