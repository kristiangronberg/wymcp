defmodule Wymcp.Plugs.OriginCheckTest do
  use ExUnit.Case, async: true

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

    @tag doc: """
         get_req_header/2 returns every value of a repeated header — the old
         two-clause case head crashed with CaseClauseError (a 500) on a
         duplicated Origin. Duplication is malformed even when every value
         is allowlisted: first-value-wins would mask a broken proxy and
         invite smuggling-style ambiguity.
         """
    test "rejects requests with a duplicated Origin header with 400" do
      conn =
        conn(:post, "/")
        |> assign(:wymcp, origin: ["http://localhost:4000"])
        |> put_req_header("origin", "http://localhost:4000")
        |> prepend_req_headers([{"origin", "http://localhost:4000"}])
        |> OriginCheck.call(@opts)

      assert conn.halted
      assert conn.status == 400
      body = JSON.decode!(conn.resp_body)
      assert body["error"]["code"] == -32600
      assert body["error"]["data"]["error"] =~ "Duplicated Origin"
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

  describe "error dialect" do
    test "the default dialect keeps the JSON-RPC envelope" do
      conn =
        conn(:post, "/")
        |> assign(:wymcp, origin: ["http://localhost:4000"])
        |> put_req_header("origin", "http://evil.com")
        |> OriginCheck.call(@opts)

      assert conn.status == 403
      assert JSON.decode!(conn.resp_body)["error"]["code"] == -32600
    end

    test ":plain_json answers the flat object on a disallowed origin" do
      conn =
        conn(:get, "/")
        |> assign(:wymcp, origin: ["http://allowed.example"])
        |> put_req_header("origin", "http://evil.example")
        |> OriginCheck.call(OriginCheck.init(error_dialect: :plain_json))

      assert conn.status == 403
      assert conn.halted

      assert JSON.decode!(conn.resp_body) ==
               %{"error" => "Origin not allowed: http://evil.example"}
    end

    test ":plain_json answers the flat object on a duplicated Origin header" do
      conn =
        conn(:get, "/")
        |> assign(:wymcp, origin: ["http://allowed.example"])
        |> put_req_header("origin", "http://allowed.example")
        |> prepend_req_headers([{"origin", "http://allowed.example"}])
        |> OriginCheck.call(OriginCheck.init(error_dialect: :plain_json))

      assert conn.status == 400

      assert JSON.decode!(conn.resp_body) ==
               %{"error" => "Duplicated Origin header. Send exactly one Origin header."}
    end
  end
end
