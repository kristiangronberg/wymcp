defmodule Wymcp.Methods.Initialize do
  @moduledoc false

  import Plug.Conn
  import Wymcp.Response
  alias Wymcp.{JsonRpc, Session}

  @supported_versions ["2025-11-25"]
  @latest_version hd(@supported_versions)

  @spec run(Plug.Conn.t()) :: Plug.Conn.t()
  def run(conn) do
    request = conn.body_params
    params = request["params"] || %{}
    wymcp_opts = conn.assigns[:wymcp] || []
    requested_version = params["protocolVersion"]

    if requested_version in @supported_versions do
      do_initialize(conn, request, params, wymcp_opts, requested_version)
    else
      data = %{
        reason: "Unsupported protocol version: #{requested_version}",
        supported_versions: @supported_versions
      }

      response = JsonRpc.error_response(:invalid_params, request["id"], data)
      send_json(conn, response)
    end
  end

  defp do_initialize(conn, request, params, wymcp_opts, _requested_version) do
    name = Application.get_env(:wymcp, :name, "MCP Server")
    version = Application.get_env(:wymcp, :version, "1.0.0")

    client_info = params["clientInfo"] || %{}

    {:ok, _pid, session_id} =
      Session.start_session(%{
        client_capabilities: params["capabilities"] || %{},
        client_info: client_info,
        protocol_version: @latest_version,
        tools: wymcp_opts[:tools] || [],
        auth: wymcp_opts[:auth],
        server: wymcp_opts[:server]
      })

    Wymcp.Telemetry.emit(:session, :start, %{}, %{
      session_id: session_id,
      client_info: client_info
    })

    client_caps = params["capabilities"] || %{}

    capabilities = %{"tools" => %{"listChanged" => true}, "logging" => %{}}

    capabilities =
      if Map.has_key?(client_caps, "sampling"),
        do: Map.put(capabilities, "sampling", %{}),
        else: capabilities

    capabilities =
      if Map.has_key?(client_caps, "elicitation"),
        do: Map.put(capabilities, "elicitation", %{}),
        else: capabilities

    server_info = build_server_info(name, version, wymcp_opts[:server_info])

    result = %{
      "capabilities" => capabilities,
      "protocolVersion" => @latest_version,
      "serverInfo" => server_info
    }

    result =
      case wymcp_opts[:instructions] do
        nil -> result
        text when is_binary(text) -> Map.put(result, "instructions", text)
      end

    response = JsonRpc.success_response(request["id"], result)

    conn
    |> put_resp_header("mcp-session-id", session_id)
    |> send_json(response)
  end

  @spec build_server_info(String.t(), String.t(), map() | nil) :: map()
  defp build_server_info(name, version, nil) do
    %{"name" => name, "version" => version}
  end

  defp build_server_info(name, version, opts) when is_map(opts) do
    %{"name" => name, "version" => version}
    |> maybe_put("title", opts[:title])
    |> maybe_put("description", opts[:description])
    |> maybe_put("websiteUrl", opts[:website_url])
    |> maybe_put_icons(opts[:icons])
  end

  @spec maybe_put(%{required(String.t()) => term()}, String.t(), term()) ::
          %{required(String.t()) => term()}
  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  @spec maybe_put_icons(map(), list() | nil) :: map()
  defp maybe_put_icons(map, nil), do: map
  defp maybe_put_icons(map, []), do: map

  defp maybe_put_icons(map, icons) when is_list(icons) do
    encoded =
      Enum.map(icons, fn icon ->
        icon
        |> Map.new(fn {k, v} -> {Atom.to_string(k), v} end)
        |> then(fn m ->
          case Map.pop(m, "media_type") do
            {nil, m} -> m
            {val, m} -> Map.put(m, "mediaType", val)
          end
        end)
      end)

    Map.put(map, "icons", encoded)
  end
end
