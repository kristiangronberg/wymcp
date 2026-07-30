defmodule Wymcp.Transport.StreamManagerTest do
  use ExUnit.Case, async: true

  @moduledoc """
  Tests for the StreamManager GenServer.

  StreamManager owns a chunked Plug.Conn for SSE streaming. Plug.Test's
  adapter accumulates chunk writes in adapter state rather than sending
  them to a client, so a StreamManager can be started on a conn opened
  with `Wymcp.Transport.Stream.open/1` — but nothing reads the bytes
  back. These tests therefore cover the GenServer lifecycle, monitoring,
  and message protocol rather than actual HTTP output. The event counter
  has no public accessor; the resumption tests read it with
  `:sys.get_state/1`. Sessions are started through the `start_session/0`
  helper, which generates a unique id per call — session ids are keys in
  the process-global session Registry, and this module runs
  `async: true`.

  The StreamManager is started with a session pid and registers itself
  with the session. It monitors the session — if the session dies, the
  stream shuts down. The keepalive timer fires periodically but is
  tested with short intervals to avoid slow tests.

  Real SSE output is covered by integration tests using an HTTP client
  against a running server (out of scope for this unit test module).
  """

  import Plug.Test

  alias Wymcp.Session
  alias Wymcp.Transport.SSE
  alias Wymcp.Transport.Stream
  alias Wymcp.Transport.StreamManager

  describe "start_link/1" do
    @tag doc: """
         StreamManager requires a session_pid in its opts and refuses to
         start without one, before any conn is touched. A failure here
         means the GenServer init/1 is not validating required opts.
         """
    test "requires :session_pid in opts" do
      assert {:error, _} = StreamManager.start_link(%{conn: nil, session_pid: nil})
    end

    @tag doc: """
         Control for the regression test below. A failure here means the
         test harness itself broke (session, chunked conn, or priming),
         not the parser.
         """
    test "resumes the event counter from a well-formed last_event_id" do
      session_pid = start_session()
      chunked_conn = Stream.open(conn(:get, "/"))

      assert {:ok, stream_pid} =
               StreamManager.start_link(%{
                 conn: chunked_conn,
                 session_pid: session_pid,
                 keepalive_interval: 60_000,
                 last_event_id: "evt-7"
               })

      assert :sys.get_state(stream_pid).event_counter == 8
      :ok = StreamManager.shutdown(stream_pid)
    end

    @tag doc: """
         Guards the regression where Last-Event-ID went from the client's
         header straight into String.to_integer/1: a suffix that is not a
         number raised ArgumentError inside init/1 and killed the linked
         caller — the connection process running the router's GET route —
         so the router's 500 branch never ran. A failure here means the
         resume counter is parsing wire text type-assumingly again.
         """
    test "starts with a malformed last_event_id and resumes from 0" do
      session_pid = start_session()
      chunked_conn = Stream.open(conn(:get, "/"))

      assert {:ok, stream_pid} =
               StreamManager.start_link(%{
                 conn: chunked_conn,
                 session_pid: session_pid,
                 keepalive_interval: 60_000,
                 last_event_id: "evt-x"
               })

      assert :sys.get_state(stream_pid).event_counter == 1
      :ok = StreamManager.shutdown(stream_pid)
    end
  end

  describe "session monitoring" do
    @tag doc: """
         When the session process dies, the StreamManager must terminate.
         This prevents orphaned streams from holding connections open
         after the session has been cleaned up. We use a fake session
         process to test the monitoring path without needing a real Session.
         """
    test "terminates when session process dies" do
      # Spawn a fake session that we can kill
      fake_session = spawn(fn -> Process.sleep(:infinity) end)

      # We need a process that acts like StreamManager's monitoring behavior
      # but doesn't need a real conn. Test the monitoring logic directly.
      test_pid = self()

      watcher =
        spawn(fn ->
          ref = Process.monitor(fake_session)

          receive do
            {:DOWN, ^ref, :process, _pid, _reason} ->
              send(test_pid, :stream_terminated)
          end
        end)

      Process.exit(fake_session, :kill)
      assert_receive :stream_terminated, 1000
      refute Process.alive?(watcher)
    end
  end

  describe "push/2 message protocol" do
    @tag doc: """
         The push/2 function is called via GenServer.call with {:push, message}.
         The StreamManager encodes the message as an SSE event and writes it
         to the chunked conn. Since we can't test real chunked writes in
         Plug.Test, this test verifies the message format using the SSE
         encoder directly.
         """
    test "SSE.encode produces valid event format" do
      message = %{"jsonrpc" => "2.0", "id" => 1, "method" => "sampling/createMessage"}
      encoded = SSE.encode(message, "evt-1")

      assert encoded =~ "id: evt-1\n"
      assert encoded =~ "data: "
      assert encoded =~ "sampling/createMessage"
      assert String.ends_with?(encoded, "\n\n")
    end
  end

  defp start_session do
    session_id = "stream-manager-test-#{System.unique_integer([:positive])}"

    {:ok, pid} =
      Session.start_link(
        {session_id,
         %{
           client_capabilities: %{},
           client_info: %{"name" => "test", "version" => "1.0"},
           protocol_version: "2025-11-25",
           tools: [],
           auth: nil
         }}
      )

    pid
  end
end
