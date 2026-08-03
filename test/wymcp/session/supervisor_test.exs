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

  describe "restart policy" do
    @tag doc: """
         Guards the expiry-resurrection leak: under the default :permanent
         restart, an idle-expired session was restarted under the same
         session id, so lookup/1 kept answering {:ok, pid} and the idle
         timeout never converged access to closed — and a fast-expiring
         test session cycled expire→restart until the whole session
         supervisor tripped max_restarts and collapsed. A failure means
         the session child_spec lost restart: :temporary.
         """
    test "an idle-expired session stays gone" do
      {:ok, pid, session_id} =
        Session.start_session(Testing.build_session_opts(session_idle_timeout: 50))

      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, {:shutdown, :session_expired}}, 500

      assert_stays_unregistered(session_id)
    end

    test "a crashed session stays gone" do
      {:ok, pid, session_id} = Session.start_session(Testing.build_session_opts())

      ref = Process.monitor(pid)
      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^pid, :killed}, 500

      assert_stays_unregistered(session_id)
    end
  end

  # The Registry clears its entry asynchronously after the session dies:
  # poll until the id is gone, then confirm it STAYS gone — a restarted
  # session would re-register under the same id within the settle window.
  defp assert_stays_unregistered(session_id, remaining_ms \\ 500) do
    case Session.lookup(session_id) do
      {:error, :not_found} ->
        Process.sleep(50)
        assert {:error, :not_found} = Session.lookup(session_id)

      {:ok, _pid} when remaining_ms > 0 ->
        Process.sleep(10)
        assert_stays_unregistered(session_id, remaining_ms - 10)

      {:ok, pid} ->
        flunk("session still registered as #{inspect(pid)} after death")
    end
  end
end
