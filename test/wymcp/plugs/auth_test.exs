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

  defp build_conn(auth_module) do
    body = %{"jsonrpc" => "2.0", "id" => 42, "method" => "tools/call"}

    conn(:post, "/")
    |> put_req_header("content-type", "application/json")
    |> Map.put(:body_params, body)
    |> assign(:wymcp, %{auth: auth_module})
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
end
