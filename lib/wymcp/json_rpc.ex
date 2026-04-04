defmodule Wymcp.JsonRpc do
  @moduledoc false

  @error_type_map %{
    parse_error: {-32700, "Parse error"},
    invalid_request: {-32600, "Invalid Request"},
    method_not_found: {-32601, "Method not found"},
    invalid_params: {-32602, "Invalid params"},
    internal_error: {-32603, "Internal error"}
  }
  @error_types Map.keys(@error_type_map)

  @spec success_response(term(), map()) :: map()
  def success_response(request_id, result) do
    %{
      "jsonrpc" => "2.0",
      "id" => request_id,
      "result" => result
    }
  end

  @spec error_response(atom(), term(), term()) :: map()
  def error_response(error_type, request_id, data) when error_type in @error_types do
    {code, message} = Map.get(@error_type_map, error_type)

    %{
      "jsonrpc" => "2.0",
      "id" => request_id,
      "error" => %{
        "code" => code,
        "message" => message,
        "data" => data
      }
    }
  end

  # -- MCP schema validation (JSV, JSON Schema 2020-12) --
  #
  # The MCP protocol schema uses `$defs` to define all message types.
  # To validate against a single definition (e.g. JSONRPCMessage), we
  # build a wrapper schema at compile time that `$ref`s into $defs.
  # JSV.build! returns a %JSV.Root{} struct (plain Elixir data) that
  # can be stored as a module attribute.

  @schema_json File.read!("priv/schema.json") |> JSON.decode!()
  @defs Map.get(@schema_json, "$defs", %{})

  @jsonrpc_message_root JSV.build!(%{
                          "$schema" => "https://json-schema.org/draft/2020-12/schema",
                          "$ref" => "#/$defs/JSONRPCMessage",
                          "$defs" => @defs
                        })

  @spec validate_mcp_request(String.t(), map()) :: :ok | {:error, String.t()}
  def validate_mcp_request("JSONRPCMessage", data) do
    do_validate(@jsonrpc_message_root, data)
  end

  @spec validate_schema(map(), map()) :: :ok | {:error, String.t()}
  def validate_schema(schema, data) do
    root = JSV.build!(schema)
    do_validate(root, data)
  end

  @spec do_validate(JSV.Root.t(), term()) :: :ok | {:error, String.t()}
  defp do_validate(root, data) do
    case JSV.validate(data, root) do
      {:ok, _cast_data} -> :ok
      {:error, error} -> {:error, format_error(error)}
    end
  end

  @spec format_error(JSV.ValidationError.t()) :: String.t()
  defp format_error(%JSV.ValidationError{} = error) do
    error
    |> JSV.normalize_error()
    |> inspect()
  end
end
