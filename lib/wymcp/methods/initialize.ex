defmodule Wymcp.Methods.Initialize do
  @moduledoc false

  import Plug.Conn
  import Wymcp.Response
  require Logger
  alias Wymcp.{JsonRpc, ProtocolVersion, Session}

  # Whitelist of accepted Icon input keys (snake_case atoms) and
  # their MCP wire names. Per CLAUDE.md module-layout convention,
  # this attribute lives between aliases and the public API.
  @icon_key_map %{
    src: "src",
    mime_type: "mimeType",
    sizes: "sizes",
    theme: "theme"
  }

  @spec run(Plug.Conn.t()) :: Plug.Conn.t()
  def run(conn) do
    request = conn.body_params
    params = request["params"] || %{}
    wymcp_opts = conn.assigns[:wymcp] || []
    requested_version = params["protocolVersion"]

    negotiated_version =
      if ProtocolVersion.supported?(requested_version) do
        requested_version
      else
        ProtocolVersion.latest()
      end

    do_initialize(conn, request, params, wymcp_opts, negotiated_version)
  end

  defp do_initialize(conn, request, params, wymcp_opts, negotiated_version) do
    name = Application.get_env(:wymcp, :name, "MCP Server")
    version = Application.get_env(:wymcp, :version, "1.0.0")

    client_info = params["clientInfo"] || %{}

    {:ok, _pid, session_id} =
      Session.start_session(%{
        client_capabilities: params["capabilities"] || %{},
        client_info: client_info,
        protocol_version: negotiated_version,
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

    server_info =
      build_server_info(name, version, wymcp_opts[:server_info], negotiated_version)

    result = %{
      "capabilities" => capabilities,
      "protocolVersion" => negotiated_version,
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

  @spec build_server_info(String.t(), String.t(), map() | nil, String.t()) :: map()
  defp build_server_info(name, version, nil, negotiated_version) do
    %{"name" => name, "version" => version}
    |> ProtocolVersion.strip_server_info(negotiated_version)
  end

  defp build_server_info(name, version, opts, negotiated_version) when is_map(opts) do
    %{"name" => name, "version" => version}
    |> maybe_put("title", opts[:title])
    |> maybe_put("description", opts[:description])
    |> maybe_put("websiteUrl", opts[:website_url])
    |> maybe_put_icons(opts[:icons])
    |> ProtocolVersion.strip_server_info(negotiated_version)
  end

  @spec maybe_put(%{required(String.t()) => term()}, String.t(), term()) ::
          %{required(String.t()) => term()}
  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  @spec maybe_put_icons(map(), [%{atom() => term()}] | nil) :: map()
  defp maybe_put_icons(map, nil), do: map
  defp maybe_put_icons(map, []), do: map

  defp maybe_put_icons(map, icons) when is_list(icons) do
    Map.put(map, "icons", Enum.map(icons, &encode_icon/1))
  end

  @spec encode_icon(%{atom() => term()}) :: %{String.t() => term()}
  defp encode_icon(icon) do
    {known, unknown} = Map.split(icon, Map.keys(@icon_key_map))
    _ = log_dropped_keys(unknown)
    Map.new(known, fn {k, v} -> {Map.fetch!(@icon_key_map, k), v} end)
  end

  @spec log_dropped_keys(map()) :: :ok
  defp log_dropped_keys(unknown) when map_size(unknown) == 0, do: :ok

  defp log_dropped_keys(unknown) do
    Logger.warning(
      "Wymcp.Methods.Initialize: dropping unknown icon keys " <>
        "#{inspect(Map.keys(unknown))}. Accepted keys: " <>
        "#{inspect(Map.keys(@icon_key_map))}."
    )
  end
end
