defmodule Wymcp.WireCheckInvariantTest do
  @moduledoc """
  One describe per non-fallthrough route, generated from @routes — the
  version_matrix_test.exs pattern, so a failing run names the route in the
  describe heading. A new non-fallthrough route must be added to @routes to
  come under the invariant (definition: `Wymcp.Router`'s moduledoc). No
  request here carries an Mcp-Session-Id header: a wire-check answer
  arriving instead of the routes' missing-header 400 is what proves the
  checks run before the session-header read. The origin and auth checks
  discriminate by status (403, 401); the singleton-header check answers a
  400 of its own, so its leg discriminates on the message text instead —
  which is why it duplicates MCP-Protocol-Version rather than
  Mcp-Session-Id, leaving the premise above intact. The POST legs pass by
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

      @tag doc: """
           The third wire check. Unlike the 401 and 403 above, this rejection
           is itself a 400 — the same status the routes answer for a missing
           Mcp-Session-Id header — so the discriminator here is the message,
           not the status: the check ran before the session-header read iff the
           body names the duplicated header instead of the missing one.
           MCP-Protocol-Version is duplicated rather than Mcp-Session-Id so
           this module's no-session-header premise survives.
           """
      test "a request duplicating a reject-class singleton header answers 400" do
        opts = Wymcp.Router.init(tools: [])

        conn =
          request(unquote(method), opts, [
            {"mcp-protocol-version", "2025-11-25"},
            {"mcp-protocol-version", "2025-11-25"}
          ])

        assert conn.status == 400

        assert_route_dialect(
          unquote(method),
          conn,
          "Duplicated MCP-Protocol-Version header. Send exactly one MCP-Protocol-Version header."
        )
      end
    end
  end

  # -- Helpers --

  defp request(method, opts, extra_headers \\ [])

  # POST runs its wire checks inside Plugs.Pipeline, where the auth check
  # sits after body parsing — the body must be valid JSON for the request
  # to reach it.
  # prepend_req_headers/2, not merge_req_headers/2: merge replaces by key
  # (List.keystore/4), so it cannot express the duplicated header the
  # singleton-header check exists to reject.
  defp request(:post, opts, extra_headers) do
    conn(:post, "/", JSON.encode!(%{"jsonrpc" => "2.0", "id" => 1, "method" => "ping"}))
    |> put_req_header("content-type", "application/json")
    |> prepend_req_headers(extra_headers)
    |> Wymcp.Router.call(opts)
  end

  defp request(method, opts, extra_headers) when method in [:get, :delete] do
    conn(method, "/")
    |> prepend_req_headers(extra_headers)
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
