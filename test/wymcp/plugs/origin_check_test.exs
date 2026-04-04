defmodule Wymcp.Plugs.OriginCheckTest do
  use ExUnit.Case, async: true

  @moduledoc """
  Tests for Origin header validation (DNS rebinding protection).

  Browser-based MCP clients send an Origin header. A malicious page on
  the internet could make requests to localhost via DNS rebinding. The
  OriginCheck plug validates Origin against a configurable allowlist
  read from conn.assigns[:wymcp][:origin].

  Three cases:
  1. No Origin header -> pass through (non-browser clients: curl, SDKs)
  2. Origin in allowlist -> pass through
  3. Origin not in allowlist -> 403 Forbidden

  When no allowlist is configured (default), all origins are allowed
  for backwards compatibility. The plug runs before body parsing, so
  error responses use request_id=nil.
  """

  import Plug.Test
  import Plug.Conn

  alias Wymcp.Plugs.OriginCheck

  @opts OriginCheck.init([])

  describe "with allowlist configured" do
    @tag doc: """
         When an allowlist is set, only matching origins pass. This is the
         security-critical path — a failure means DNS rebinding protection
         is broken. The allowlist matches exact strings (scheme + host + port).
         """
    test "allows requests without Origin header" do
      conn =
        conn(:post, "/")
        |> assign(:wymcp, origin: ["http://localhost:4000"])
        |> OriginCheck.call(@opts)

      refute conn.halted
    end

    test "allows requests with Origin in allowlist" do
      conn =
        conn(:post, "/")
        |> assign(:wymcp, origin: ["http://localhost:4000"])
        |> put_req_header("origin", "http://localhost:4000")
        |> OriginCheck.call(@opts)

      refute conn.halted
    end

    test "rejects requests with Origin not in allowlist" do
      conn =
        conn(:post, "/")
        |> assign(:wymcp, origin: ["http://localhost:4000"])
        |> put_req_header("origin", "http://evil.com")
        |> OriginCheck.call(@opts)

      assert conn.halted
      assert conn.status == 403
      body = JSON.decode!(conn.resp_body)
      assert body["error"]["code"] == -32600
    end

    test "supports multiple origins in allowlist" do
      conn =
        conn(:post, "/")
        |> assign(:wymcp, origin: ["http://localhost:4000", "http://localhost:3000"])
        |> put_req_header("origin", "http://localhost:3000")
        |> OriginCheck.call(@opts)

      refute conn.halted
    end
  end

  describe "without allowlist configured" do
    @tag doc: """
         When no allowlist is configured (origin option not set), all origins
         are allowed for backwards compatibility. Existing deployments that
         don't set the option continue working unchanged.
         """
    test "allows all origins when no allowlist is set" do
      conn =
        conn(:post, "/")
        |> assign(:wymcp, [])
        |> put_req_header("origin", "http://evil.com")
        |> OriginCheck.call(@opts)

      refute conn.halted
    end

    test "allows all origins when wymcp assigns not set" do
      conn =
        conn(:post, "/")
        |> put_req_header("origin", "http://evil.com")
        |> OriginCheck.call(@opts)

      refute conn.halted
    end
  end
end
