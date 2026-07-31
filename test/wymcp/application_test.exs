defmodule Wymcp.ApplicationTest do
  use ExUnit.Case, async: true

  describe "supervision tree" do
    test "Wymcp.Session.Supervisor is running" do
      pid = Process.whereis(Wymcp.Session.Supervisor)
      assert is_pid(pid)
      assert Process.alive?(pid)
    end
  end
end
