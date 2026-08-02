defmodule Wymcp.WireCheckInvariantTest do
  @moduledoc """
  One describe per non-fallthrough route, generated from @routes — the
  version_matrix_test.exs pattern, so a failing run names the route in the
  describe heading. A new non-fallthrough route must be added to @routes to
  come under the invariant (definition: `Wymcp.Router`'s moduledoc). No
  request here carries an Mcp-Session-Id header: a wire-check answer
  arriving instead of the routes' missing-header 400 is what proves the
  checks run before the session-header read. The POST legs pass by
  construction (its wire checks live in Plugs.Pipeline) and pin that
  arrangement. The fallthrough (any other verb) stays check-free by
  design — it touches nothing.
  """

  use ExUnit.Case, async: true

  import Plug.Test
  import Plug.Conn

  defmodule FailAuth do
    @behaviour Wymcp.Auth

    @impl Wymcp.Auth
    def authenticate(_conn), do: {:error, "Unauthorized"}
  end

  @routes [:post, :get, :delete]

  for method <- @routes do
    describe "#{method |> Atom.to_string() |> String.upcase()} /" do
      test "an unauthenticated request answers 401" do
        opts = Wymcp.Router.init(tools: [], auth: FailAuth)

        conn = request(unquote(method), opts)

        assert conn.status == 401
        assert get_resp_header(conn, "www-authenticate") == ["Bearer"]
        assert_route_dialect(unquote(method), conn, "Unauthorized")
      end

      test "a disallowed-Origin request answers 403" do
        opts = Wymcp.Router.init(tools: [], origin: ["http://allowed.example"])

        conn = request(unquote(method), opts, [{"origin", "http://evil.example"}])

        assert conn.status == 403
        assert_route_dialect(unquote(method), conn, "Origin not allowed: http://evil.example")
      end
    end
  end

  # -- Helpers --

  defp request(method, opts, extra_headers \\ [])

  # POST runs its wire checks inside Plugs.Pipeline, where the auth check
  # sits after body parsing — the body must be valid JSON for the request
  # to reach it.
  defp request(:post, opts, extra_headers) do
    conn(:post, "/", JSON.encode!(%{"jsonrpc" => "2.0", "id" => 1, "method" => "ping"}))
    |> put_req_header("content-type", "application/json")
    |> merge_req_headers(extra_headers)
    |> Wymcp.Router.call(opts)
  end

  defp request(method, opts, extra_headers) when method in [:get, :delete] do
    conn(method, "/")
    |> merge_req_headers(extra_headers)
    |> Wymcp.Router.call(opts)
  end

  # A wire-check rejection speaks the error dialect of the route it ran
  # on — pinned here per route so a new @routes entry cannot pass while
  # answering the wrong dialect.
  defp assert_route_dialect(:post, conn, message) do
    body = JSON.decode!(conn.resp_body)
    assert body["error"]["code"] == -32600
    assert body["error"]["data"]["error"] == message
  end

  defp assert_route_dialect(method, conn, message) when method in [:get, :delete] do
    assert JSON.decode!(conn.resp_body) == %{"error" => message}
  end
end
