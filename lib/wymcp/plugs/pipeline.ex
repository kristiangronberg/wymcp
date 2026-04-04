defmodule Wymcp.Plugs.Pipeline do
  @moduledoc false

  use Plug.Builder

  alias Wymcp.Plugs

  plug(Plugs.OriginCheck)
  plug(:parse_body)
  plug(Plugs.Classify)
  plug(Plugs.Auth)
  plug(Plugs.Session)
  plug(Plugs.Validate)
  plug(Plugs.Dispatch)

  @parsers_opts Plug.Parsers.init(
                  parsers: [:json],
                  pass: ["application/json"],
                  json_decoder: JSON
                )

  @spec parse_body(Plug.Conn.t(), term()) :: Plug.Conn.t()
  defp parse_body(conn, _opts) do
    Plug.Parsers.call(conn, @parsers_opts)
  rescue
    Plug.Parsers.ParseError ->
      response = Wymcp.JsonRpc.error_response(:parse_error, nil, %{reason: "Malformed JSON"})

      conn
      |> put_status(400)
      |> Wymcp.Response.send_json(response)
  end
end
