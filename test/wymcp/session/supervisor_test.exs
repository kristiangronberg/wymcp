defmodule Wymcp.Session.SupervisorTest do
  use ExUnit.Case, async: true

  @moduledoc """
  Tests for session lifecycle under the DynamicSupervisor.

  Sessions are started via `Wymcp.Session.start_session/1` which
  delegates to the DynamicSupervisor. Each session is an independent
  GenServer that can be stopped without affecting others.
  """

  alias Wymcp.Session

  describe "start_session/1" do
    test "starts a session under the supervisor and returns pid + session_id" do
      {:ok, pid, session_id} =
        Session.start_session(%{
          client_capabilities: %{},
          client_info: %{"name" => "test", "version" => "1.0"},
          protocol_version: "2025-11-25",
          tools: [],
          auth: nil
        })

      assert is_pid(pid)
      assert is_binary(session_id)
      assert Process.alive?(pid)
    end

    test "each session gets a unique session_id" do
      opts = %{
        client_capabilities: %{},
        client_info: %{"name" => "test", "version" => "1.0"},
        protocol_version: "2025-11-25",
        tools: [],
        auth: nil
      }

      {:ok, _, id1} = Session.start_session(opts)
      {:ok, _, id2} = Session.start_session(opts)

      refute id1 == id2
    end
  end
end
