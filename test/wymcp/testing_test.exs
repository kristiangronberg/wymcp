defmodule Wymcp.TestingTest do
  use ExUnit.Case, async: true

  alias Wymcp.{Session, Testing}

  doctest Wymcp.Testing

  describe "build_session_opts/1" do
    test "defaults cover exactly the keys Session.init/1 requires" do
      assert Testing.build_session_opts() == %{
               protocol_version: Wymcp.ProtocolVersion.latest(),
               client_capabilities: %{},
               client_info: %{"name" => "test", "version" => "1.0"},
               tools: [],
               auth: nil
             }
    end

    test "overrides replace their defaults; other keys keep theirs" do
      opts = Testing.build_session_opts(protocol_version: "2025-03-26", client_info: %{})

      assert opts.protocol_version == "2025-03-26"
      assert opts.client_info == %{}
      assert opts.client_capabilities == %{}
      assert opts.auth == nil
    end

    test "optional Session.init keys enter the map only when passed" do
      refute Map.has_key?(Testing.build_session_opts(), :server)
      refute Map.has_key?(Testing.build_session_opts(), :session_idle_timeout)
      refute Map.has_key?(Testing.build_session_opts(), :ack_window)

      opts =
        Testing.build_session_opts(
          server: SomeServer,
          session_idle_timeout: 50,
          ack_window: 50
        )

      assert opts.server == SomeServer
      assert opts.session_idle_timeout == 50
      assert opts.ack_window == 50
    end

    test "the default map starts a real session" do
      assert {:ok, pid, session_id} = Session.start_session(Testing.build_session_opts())
      assert is_pid(pid)
      assert is_binary(session_id)
    end
  end
end
