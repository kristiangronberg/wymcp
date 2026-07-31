defmodule Wymcp.Session.SupervisorTest do
  use ExUnit.Case, async: true

  alias Wymcp.Session
  alias Wymcp.Testing

  describe "start_session/1" do
    test "starts a session under the supervisor and returns pid + session_id" do
      {:ok, pid, session_id} = Session.start_session(Testing.build_session_opts())

      assert is_pid(pid)
      assert is_binary(session_id)
      assert Process.alive?(pid)
    end

    test "each session gets a unique session_id" do
      opts = Testing.build_session_opts()

      {:ok, _, id1} = Session.start_session(opts)
      {:ok, _, id2} = Session.start_session(opts)

      refute id1 == id2
    end
  end
end
