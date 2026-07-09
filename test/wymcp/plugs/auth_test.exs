defmodule Wymcp.Plugs.AuthTest do
  use ExUnit.Case, async: false

  @moduledoc """
  Tests for the `Wymcp.Plugs.Auth` plug.

  The plug owns three responsibilities: dispatching to the configured
  `c:Wymcp.Auth.authenticate/1` callback, returning a spec-compliant
  401 with `WWW-Authenticate: Bearer` on rejection, and emitting
  telemetry + structured logs so consumers can attribute auth-failure
  spikes.

  The previous plug logged nothing on the expected rejection branch.
  Tests here pin the structured-logging contract: a `[:wymcp, :auth,
  :reject]` event on `{:error, _}` and a `[:wymcp, :auth, :error]`
  event on rescue. Failure of these tests means the wire still works
  but observability has regressed.

  This module runs `async: false` because telemetry handler
  attachments are global — concurrent modules attaching to the same
  event would see each other's emissions.

  The 401 challenge is bare "Bearer" by default and gains RFC 6750
  auth-params (resource_metadata pointer, scope hint) when the consumer sets
  the router's :www_authenticate option.
  """

  import ExUnit.CaptureLog
  import Plug.Test
  import Plug.Conn

  alias Wymcp.Plugs.Auth

  defmodule RejectingAuth do
    @behaviour Wymcp.Auth
    def authenticate(_conn), do: {:error, "Invalid token"}
  end

  defmodule RaisingAuth do
    @behaviour Wymcp.Auth
    def authenticate(_conn), do: raise("boom")
  end

  defmodule MetadataUrl do
    def url, do: "https://example.com/.well-known/oauth-protected-resource/mcp"
  end

  defp build_conn(auth_module, extra_config \\ %{}) do
    body = %{"jsonrpc" => "2.0", "id" => 42, "method" => "tools/call"}

    conn(:post, "/")
    |> put_req_header("content-type", "application/json")
    |> Map.put(:body_params, body)
    |> assign(:wymcp, Map.merge(%{auth: auth_module}, extra_config))
  end

  describe "rejection path" do
    test "returns 401 with WWW-Authenticate: Bearer" do
      conn = build_conn(RejectingAuth) |> Auth.call([])

      assert conn.status == 401
      assert get_resp_header(conn, "www-authenticate") == ["Bearer"]
    end

    @tag doc: """
         Pins the JSON-RPC error contract: code -32600, the rejection
         message echoed under `data.error`, and the request id preserved
         so clients can correlate. A failure here breaks every existing
         Wymcp client that surfaces auth errors to the user.
         """
    test "JSON-RPC body carries -32600 and the rejection message" do
      conn = build_conn(RejectingAuth) |> Auth.call([])
      body = JSON.decode!(conn.resp_body)

      assert body["id"] == 42
      assert body["error"]["code"] == -32600
      assert body["error"]["data"]["error"] == "Invalid token"
    end

    @tag doc: """
         Verifies the structured-log contract on the expected rejection
         branch. Previous behaviour was silent — operators couldn't
         distinguish "10 rejections from one user" from "one rejection
         repeated 10 times". Failure means the Logger.warning call was
         removed or its metadata keys were renamed.
         """
    test "emits structured Logger.warning with metadata" do
      log =
        capture_log([level: :warning], fn ->
          build_conn(RejectingAuth) |> Auth.call([])
        end)

      assert log =~ "MCP auth rejected"
      assert log =~ "Invalid token"
    end

    @tag capture_log: true
    test "emits [:wymcp, :auth, :reject] telemetry event" do
      ref = make_ref()
      handler_id = "auth-reject-#{inspect(ref)}"

      :telemetry.attach(
        handler_id,
        [:wymcp, :auth, :reject],
        fn _event, _measurements, metadata, _config ->
          send(self(), {:telemetry, ref, metadata})
        end,
        nil
      )

      try do
        build_conn(RejectingAuth) |> Auth.call([])

        assert_received {:telemetry, ^ref, metadata}
        assert metadata.auth_module == RejectingAuth
        assert metadata.reason == "Invalid token"
        assert metadata.request_id == 42
        assert metadata.method == "tools/call"
      after
        :telemetry.detach(handler_id)
      end
    end
  end

  describe "rescue path" do
    @tag capture_log: true
    test "returns 401 when the auth module raises" do
      conn = build_conn(RaisingAuth) |> Auth.call([])

      assert conn.status == 401
      assert get_resp_header(conn, "www-authenticate") == ["Bearer"]
    end

    @tag capture_log: true
    test "emits [:wymcp, :auth, :error] telemetry event with exception class" do
      ref = make_ref()
      handler_id = "auth-error-#{inspect(ref)}"

      :telemetry.attach(
        handler_id,
        [:wymcp, :auth, :error],
        fn _event, _measurements, metadata, _config ->
          send(self(), {:telemetry, ref, metadata})
        end,
        nil
      )

      try do
        build_conn(RaisingAuth) |> Auth.call([])

        assert_received {:telemetry, ^ref, metadata}
        assert metadata.auth_module == RaisingAuth
        assert metadata.exception == "RuntimeError"
        assert metadata.request_id == 42
      after
        :telemetry.detach(handler_id)
      end
    end
  end

  describe "WWW-Authenticate auth-params" do
    @tag doc: """
         RFC 9728 §5.1 requires the 401 challenge to carry a resource_metadata
         pointer; RFC 6750 §3 defines the scope auth-param. Failure means
         spec-following MCP clients (mcp-remote's WWW-Authenticate rung) lose the
         discovery pointer and scope hint and fall back to defaults the consumer's
         authorization server may reject.
         """
    test "renders configured auth-params after the Bearer challenge" do
      conn =
        build_conn(RejectingAuth, %{
          www_authenticate: [
            resource_metadata: "https://example.com/.well-known/oauth-protected-resource/mcp",
            scope: "mcp"
          ]
        })

      conn = Auth.call(conn, [])

      assert get_resp_header(conn, "www-authenticate") == [
               ~s(Bearer resource_metadata="https://example.com/.well-known/oauth-protected-resource/mcp", scope="mcp")
             ]
    end

    @tag doc: """
         Phoenix forward options are evaluated at compile time, but values like a
         public URL are often only known at runtime — an MFA value must be applied
         per request, not at init.
         """
    test "resolves {module, function, args} values at request time" do
      conn =
        build_conn(RejectingAuth, %{
          www_authenticate: [resource_metadata: {MetadataUrl, :url, []}]
        })

      conn = Auth.call(conn, [])

      assert get_resp_header(conn, "www-authenticate") == [
               ~s(Bearer resource_metadata="https://example.com/.well-known/oauth-protected-resource/mcp")
             ]
    end

    test "escapes quoted-string special characters in values" do
      conn = build_conn(RejectingAuth, %{www_authenticate: [realm: ~s(my "realm")]})

      conn = Auth.call(conn, [])

      assert get_resp_header(conn, "www-authenticate") == [~s(Bearer realm="my \\"realm\\"")]
    end

    @tag capture_log: true
    @tag doc: """
         The rescue branch (auth module raises) is the second 401 producer and must
         carry the same configured auth-params as the rejection branch. Pinned
         independently — mirroring the existing bare-Bearer rescue-path test — so a
         future refactor that splits the branches cannot silently drop the RFC 9728
         pointer from the rescue path while the suite stays green.
         """
    test "rescue-path 401 also renders configured auth-params" do
      conn =
        build_conn(RaisingAuth, %{www_authenticate: [scope: "mcp"]})
        |> Auth.call([])

      assert conn.status == 401
      assert get_resp_header(conn, "www-authenticate") == [~s(Bearer scope="mcp")]
    end

    @tag doc: """
         Misconfiguration must not break the 401 contract: a :www_authenticate
         entry that raises when rendered (a typo'd MFA that passed the shape-only
         init validation, or an MFA returning a non-binary) degrades the WHOLE
         challenge to bare "Bearer" for that request, with a Logger.error naming
         the option. Failure means the raise escapes into do_authenticate/2's
         rescue: every unauthenticated request becomes a 500 instead of the
         MCP-mandated 401 challenge, and [:wymcp, :auth, :error] misattributes the
         crash to the auth module.
         """
    test "degrades to bare Bearer when rendering a configured entry raises" do
      {conn, log} =
        with_log(fn ->
          build_conn(RejectingAuth, %{
            www_authenticate: [resource_metadata: {MetadataUrl, :nonexistent, []}]
          })
          |> Auth.call([])
        end)

      assert conn.status == 401
      assert get_resp_header(conn, "www-authenticate") == ["Bearer"]
      assert log =~ "www_authenticate"
    end
  end
end
