defmodule Wymcp.AuthTest do
  use ExUnit.Case, async: true

  import Plug.Test

  alias Wymcp.Auth.Noop

  describe "Wymcp.Auth.Noop" do
    test "returns {:ok, conn} without modification" do
      conn = conn(:post, "/")
      assert {:ok, ^conn} = Noop.authenticate(conn)
    end
  end
end
