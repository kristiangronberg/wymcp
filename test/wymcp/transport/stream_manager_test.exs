defmodule Wymcp.Transport.StreamManagerTest do
  @moduledoc """
  Plug.Test's adapter accumulates chunk writes in adapter state rather
  than sending them to a client, so a StreamManager can be started on a
  conn opened with `Wymcp.Transport.Stream.open/1` — but nothing reads
  the bytes back. These tests therefore cover the GenServer lifecycle,
  monitoring, and message protocol rather than actual HTTP output; real
  SSE output is integration-tested against a running server, out of
  scope here. The event counter has no public accessor; the resumption
  tests read it with `:sys.get_state/1`. Sessions are started through
  the `start_session/0` helper, which generates a unique id per call —
  session ids are keys in the process-global session Registry, and this
  module runs `async: true`. Keepalive timers are tested with short
  intervals to avoid slow tests.
  """

  use ExUnit.Case, async: true

  import Plug.Test
  import ExUnit.CaptureLog

  alias Wymcp.Session
  alias Wymcp.Testing
  alias Wymcp.Transport.SSE
  alias Wymcp.Transport.Stream
  alias Wymcp.Transport.StreamManager

  defmodule RefusingSession do
    @moduledoc false
    use GenServer

    @impl GenServer
    def init(nil), do: {:ok, nil}

    @impl GenServer
    def handle_call({:register_stream, _pid}, _from, state), do: {:stop, :boom, state}
  end

  describe "start_link/1" do
    @tag doc: """
         StreamManager requires a session_pid in its opts and refuses to
         start without one, before anything else happens. A failure here
         means start_link/1 lost its nil guard.
         """
    test "requires :session_pid in opts" do
      assert {:error, _} = StreamManager.start_link(%{session_pid: nil})
    end

    @tag doc: """
         Phase one of the two-phase start: registration happens in init/1,
         before the router commits the 200. A session dying between the
         router's lookup and registration must surface as :ignore — not a
         non-:normal init exit, which kills the linked GET request process
         before start_link returns (probed on OTP 28) — so the router can
         answer a clean pre-commit 404.
         """
    test "returns :ignore when the session is already dead" do
      session_pid = start_session()
      :ok = GenServer.stop(session_pid)

      assert :ignore = StreamManager.start_link(%{session_pid: session_pid})
    end

    @tag doc: """
         A registration failure that does not mean "session gone" — a call
         timeout from a saturated session mailbox, a session crash — still
         answers :ignore, because a non-:normal init exit would kill the
         linked GET request process. It must not be silent, though: the
         client sees the same "Session not found" 404 either way, so
         without this line an operator cannot tell an expired session from
         a server too busy to register the stream. The stub is started
         with GenServer.start/2, not start_link/2, so its abnormal exit
         does not reach the test process.
         """
    test "logs a registration failure whose reason is not a dead session" do
      {:ok, session_pid} = GenServer.start(RefusingSession, nil)

      log =
        capture_log(fn ->
          assert :ignore = StreamManager.start_link(%{session_pid: session_pid})
        end)

      assert log =~ "SSE stream registration failed"
      assert log =~ ":boom"
    end
  end

  describe "attach/2" do
    @tag doc: """
         Control for the tests below. A failure here means the test
         harness itself broke (session, start_link, chunked conn, or
         attach) — not the resumption parser.
         """
    test "sends the priming event and resumes the counter from a well-formed last_event_id" do
      session_pid = start_session()

      assert {:ok, stream_pid} =
               StreamManager.start_link(%{
                 session_pid: session_pid,
                 keepalive_interval: 60_000,
                 last_event_id: "evt-7"
               })

      chunked_conn = Stream.open(conn(:get, "/"))
      assert :ok = StreamManager.attach(stream_pid, chunked_conn)

      assert :sys.get_state(stream_pid).event_counter == 8
      :ok = GenServer.stop(stream_pid)
    end

    @tag doc: """
         Guards the regression where Last-Event-ID went from the client's
         header straight into String.to_integer/1 and crashed the stream
         during startup. The header is raw client input: a malformed id
         resumes from 0 — and (B8) the discard is logged as a warning
         naming the raw value, because the operator's problem is a proxy
         mangling the header being invisible at info level.
         """
    test "attaches with a malformed last_event_id, resumes from 0, and warns" do
      session_pid = start_session()

      assert {:ok, stream_pid} =
               StreamManager.start_link(%{
                 session_pid: session_pid,
                 keepalive_interval: 60_000,
                 last_event_id: "evt-x"
               })

      chunked_conn = Stream.open(conn(:get, "/"))

      log =
        capture_log(fn ->
          assert :ok = StreamManager.attach(stream_pid, chunked_conn)
        end)

      assert log =~ "SSE resumption point discarded"
      assert log =~ "evt-x"
      assert :sys.get_state(stream_pid).event_counter == 1
      :ok = GenServer.stop(stream_pid)
    end

    @tag doc: """
         evt-0 is a legitimate resumption point, not a discard: detection
         keys on parse failure, never on counter == 0. Same counter
         outcome as a discard, different operator signal.
         """
    test "evt-0 keeps the info reconnected line, not the discard warning" do
      session_pid = start_session()

      assert {:ok, stream_pid} =
               StreamManager.start_link(%{
                 session_pid: session_pid,
                 keepalive_interval: 60_000,
                 last_event_id: "evt-0"
               })

      chunked_conn = Stream.open(conn(:get, "/"))

      log =
        capture_log(fn ->
          assert :ok = StreamManager.attach(stream_pid, chunked_conn)
        end)

      assert log =~ "SSE stream reconnected"
      refute log =~ "discarded"
      assert :sys.get_state(stream_pid).event_counter == 1
      :ok = GenServer.stop(stream_pid)
    end

    test "push before attach answers {:error, :no_stream}" do
      session_pid = start_session()

      assert {:ok, stream_pid} = StreamManager.start_link(%{session_pid: session_pid})

      assert {:error, :no_stream} = StreamManager.push(stream_pid, %{"jsonrpc" => "2.0"})
      :ok = GenServer.stop(stream_pid)
    end

    @tag doc: """
         attach/2 must not crash its caller — the router's GET request
         process, which has already committed the 200 — when the manager
         died in the gap after start_link/1. Stopping the manager directly
         is the deterministic stand-in for that race. The catch is
         deliberately `:exit, _reason` rather than a narrowed reason
         pattern: the manager's gap-death shape varies with why the
         session went away, and none of them may escape to the caller.
         """
    test "attach on a dead manager answers {:error, :gone}" do
      session_pid = start_session()

      assert {:ok, stream_pid} = StreamManager.start_link(%{session_pid: session_pid})
      :ok = GenServer.stop(stream_pid)

      chunked_conn = Stream.open(conn(:get, "/"))

      assert {:error, :gone} = StreamManager.attach(stream_pid, chunked_conn)
    end
  end

  describe "session monitoring" do
    @tag doc: """
         When the session process dies, the StreamManager must terminate.
         This prevents orphaned streams from holding connections open
         after the session has been cleaned up.
         """
    test "terminates when session process dies" do
      session_pid = start_session()
      {:ok, stream_pid} = StreamManager.start_link(%{session_pid: session_pid})
      ref = Process.monitor(stream_pid)

      :ok = GenServer.stop(session_pid)

      assert_receive {:DOWN, ^ref, :process, ^stream_pid, :normal}, 1000
    end
  end

  describe "stream replacement" do
    @tag doc: """
         The session stops a replaced manager by asking it to stop — a
         :replaced cast the manager answers with {:stop, :normal, state}.
         The reason is load-bearing: the manager is linked to the GET
         request process that started it, and :normal is the one exit
         reason that link does not carry fatally, so the replaced request
         can still finish its response. A failure here means the clause is
         missing and `use GenServer`'s default cast handler answered
         instead, stopping with {:bad_cast, :replaced}.
         """
    test "a :replaced cast stops the manager with reason :normal" do
      session_pid = start_session()

      assert {:ok, stream_pid} =
               StreamManager.start_link(%{
                 session_pid: session_pid,
                 keepalive_interval: 60_000
               })

      ref = Process.monitor(stream_pid)
      GenServer.cast(stream_pid, :replaced)

      assert_receive {:DOWN, ^ref, :process, ^stream_pid, :normal}, 1000
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

    {:ok, pid} = Session.start_link({session_id, Testing.build_session_opts()})

    pid
  end
end
