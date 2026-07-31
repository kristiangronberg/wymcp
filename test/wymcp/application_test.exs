defmodule Wymcp.ApplicationTest do
  use ExUnit.Case, async: true

  @moduledoc """
  Tests for the Wymcp application supervision tree.

  The application starts a Registry for session lookup and the session
  DynamicSupervisor. StreamManager processes are not supervised — they
  are started (linked) by the GET request process that owns the SSE
  response.
  """

  describe "supervision tree" do
    test "Wymcp.Session.Supervisor is running" do
      pid = Process.whereis(Wymcp.Session.Supervisor)
      assert is_pid(pid)
      assert Process.alive?(pid)
    end
  end
end
