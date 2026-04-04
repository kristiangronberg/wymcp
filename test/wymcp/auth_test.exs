defmodule Wymcp.AuthTest do
  use ExUnit.Case, async: true

  @moduledoc """
  Tests for the Wymcp.Auth behaviour and Wymcp.Auth.Noop implementation.

  The Auth behaviour is the extension point for MCP authentication. Consuming
  applications implement `c:authenticate/1` to validate Bearer tokens from the
  Authorization header. The callback returns `{:ok, conn}` on success (typically
  with identity info added to conn.assigns) or `{:error, message}` on failure.

  Wymcp.Auth.Noop is the default implementation — it passes every request through
  without checking credentials. This matches Vancouver's current behavior and is
  appropriate for local development or servers that don't need auth.
  """

  import Plug.Test

  describe "Wymcp.Auth.Noop" do
    test "returns {:ok, conn} without modification" do
      conn = conn(:post, "/")
      assert {:ok, ^conn} = Wymcp.Auth.Noop.authenticate(conn)
    end
  end
end
