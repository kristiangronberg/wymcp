defmodule Wymcp.ApplicationTest do
  use ExUnit.Case, async: true

  @moduledoc """
  Tests for the Wymcp application supervision tree.

  The application starts a Registry for session lookup and supervisors
  for both sessions and SSE streams. The stream supervisor is a
  Task.Supervisor used by the GET endpoint to spawn StreamManager
  processes.
  """

  describe "supervision tree" do
    @tag doc: """
         The StreamSupervisor must be running for GET /mcp to spawn stream
         processes. A failure here means Application.start/2 is missing the
         Task.Supervisor child or using the wrong name.
         """
    test "Wymcp.StreamSupervisor is running" do
      pid = Process.whereis(Wymcp.StreamSupervisor)
      assert is_pid(pid)
      assert Process.alive?(pid)
    end

    test "Wymcp.Session.Supervisor is running" do
      pid = Process.whereis(Wymcp.Session.Supervisor)
      assert is_pid(pid)
      assert Process.alive?(pid)
    end
  end
end
