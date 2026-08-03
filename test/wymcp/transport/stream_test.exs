defmodule Wymcp.Transport.StreamTest do
  @moduledoc """
  serve/3 blocks for the stream's lifetime, so tests run it in a Task and
  unblock it through the module API (replace/1) or by stopping the session.
  The Plug.Test adapter accumulates chunk writes onto the conn each write
  returns, so byte assertions read `resp_body` from the conn the Task
  yields. Conns are built inside the Task closure so the adapter's
  `{:plug_conn, :sent}` owner notification lands in the loop's own mailbox
  (the loop drops it) rather than the test's — except in the two
  pre-commit tests, which build the conn here on purpose so
  `refute_received {:plug_conn, :sent}` can prove nothing was committed.
  Sessions get a unique id per test — session ids are keys in the
  process-global session Registry and this module runs `async: true`. The
  keepalive interval is set long except in the keepalive tests.

  Plug.Test's adapter can never fail a chunk write, so the disconnect
  tests swap the conn's adapter *module* for one of the stand-ins below,
  keeping Plug.Test's payload (`with_adapter/2`).
  """

  use ExUnit.Case, async: true

  import ExUnit.CaptureLog
  import Plug.Conn
  import Plug.Test

  alias Wymcp.Session
  alias Wymcp.Testing
  alias Wymcp.Transport.Stream

  defmodule RefusingSession do
    @moduledoc false
    use GenServer

    @impl GenServer
    def init(nil), do: {:ok, nil}

    @impl GenServer
    def handle_call({:register_stream, _pid}, _from, state), do: {:stop, :boom, state}
  end

  defmodule ClosedSocket do
    @moduledoc false
    # A conn adapter whose every chunk write fails: the client that is
    # already gone when the priming event goes out. Headers still commit
    # (send_chunked/3 delegates), so the failure is a write failure, not
    # a registration failure. Deliberately not `@behaviour
    # Plug.Conn.Adapter` — declaring it would demand every callback, and
    # a chunked response only ever reaches these two.
    alias Plug.Adapters.Test.Conn

    def send_chunked(payload, status, headers) do
      Conn.send_chunked(payload, status, headers)
    end

    def chunk(_payload, _body), do: {:error, :closed}
  end

  defmodule VanishingSocket do
    @moduledoc false
    # Same idea, one write later: the priming event gets through and
    # everything after it fails — the client that connects, receives the
    # priming event, and vanishes. The invariant that makes it exact:
    # Plug.Test's payload carries `chunks: ""` only between send_chunked/3
    # and the first successful write, so the `%{chunks: ""}` clause fires
    # once. Tests using this stand-in must keep the keepalive interval
    # long unless they *want* the keepalive to be the one write that
    # succeeds.
    alias Plug.Adapters.Test.Conn

    def send_chunked(payload, status, headers) do
      Conn.send_chunked(payload, status, headers)
    end

    def chunk(%{chunks: ""} = payload, body) do
      Conn.chunk(payload, body)
    end

    def chunk(_payload, _body), do: {:error, :closed}
  end

  defmodule StallingClosedSocket do
    @moduledoc false
    # ClosedSocket with a slow commit: send_chunked sleeps long enough for
    # a push to be dispatched into the loop's mailbox while the priming
    # write is still ahead of it, then every chunk write fails — a
    # deterministic stand-in for the registration→loop-entry gap.
    alias Plug.Adapters.Test.Conn

    def send_chunked(payload, status, headers) do
      Process.sleep(200)
      Conn.send_chunked(payload, status, headers)
    end

    def chunk(_payload, _body), do: {:error, :closed}
  end

  @quiet_keepalive %{keepalive_interval: 60_000}

  describe "serve/3" do
    @tag doc: """
         Control for the tests below, and the regression guard for the
         topic's bug: the priming event must be written by the process
         that owns the conn — this process's Task — and land in the conn
         serve returns. A failure here means the harness (session,
         serve, replace, Task) broke, or the bytes stopped reaching the
         request process's conn.
         """
    test "commits the 200 with SSE headers and sends the priming event" do
      session_pid = start_session()
      task = serve_task(session_pid, [], @quiet_keepalive)
      stream_pid = wait_for_stream(session_pid)

      :ok = Stream.replace(stream_pid)

      assert {:ok, conn} = Task.await(task)
      assert conn.status == 200
      assert conn.state == :chunked

      {_, content_type} =
        Enum.find(conn.resp_headers, fn {k, _} -> k == "content-type" end)

      assert content_type =~ "text/event-stream"

      {_, cache_control} =
        Enum.find(conn.resp_headers, fn {k, _} -> k == "cache-control" end)

      assert cache_control == "no-cache"
      assert conn.resp_body == "id: evt-1\ndata: \n\n"
    end

    test "resumes the counter from a well-formed Last-Event-ID header" do
      session_pid = start_session()
      task = serve_task(session_pid, [{"last-event-id", "evt-7"}], @quiet_keepalive)
      stream_pid = wait_for_stream(session_pid)

      :ok = Stream.replace(stream_pid)

      assert {:ok, conn} = Task.await(task)
      assert conn.resp_body == "id: evt-8\ndata: \n\n"
    end

    @tag doc: """
         Guards the regression where Last-Event-ID went from the client's
         header straight into String.to_integer/1 and crashed the stream
         during startup. The header is raw client input: a malformed id
         resumes from 0, and the discard is logged as a warning naming
         the raw value — the operator's problem is a proxy mangling the
         header being invisible at info level.
         """
    test "discards a malformed Last-Event-ID, starts fresh, and warns" do
      session_pid = start_session()

      log =
        capture_log(fn ->
          task = serve_task(session_pid, [{"last-event-id", "evt-x"}], @quiet_keepalive)
          stream_pid = wait_for_stream(session_pid)

          :ok = Stream.replace(stream_pid)

          assert {:ok, conn} = Task.await(task)
          assert conn.resp_body == "id: evt-1\ndata: \n\n"
        end)

      assert log =~ "SSE resumption point discarded"
      assert log =~ "evt-x"
    end

    test "evt-0 keeps the info reconnected line, not the discard warning" do
      session_pid = start_session()

      log =
        capture_log(fn ->
          task = serve_task(session_pid, [{"last-event-id", "evt-0"}], @quiet_keepalive)
          stream_pid = wait_for_stream(session_pid)

          :ok = Stream.replace(stream_pid)

          assert {:ok, conn} = Task.await(task)
          assert conn.resp_body == "id: evt-1\ndata: \n\n"
        end)

      assert log =~ "SSE stream reconnected"
      refute log =~ "discarded"
    end

    @tag doc: """
         Registration failure — timeout included — answers before the 200
         commits, so the router can still send a clean 404. Nothing may
         have been committed: a commit here would mean serve wrote bytes
         before knowing the session exists. The proof is the mailbox, not
         the conn — `conn` is immutable, so the binding below is the
         pre-call struct whatever serve/3 did internally, and it is
         `:unset` by construction. The conn is built in *this* process on
         purpose, so a send_chunked anywhere inside serve/3 would deliver
         `{:plug_conn, :sent}` here.
         """
    test "answers {:error, :session_gone} before committing when the session is dead" do
      session_pid = start_session()
      :ok = GenServer.stop(session_pid)

      conn = conn(:get, "/")
      assert {:error, :session_gone} = Stream.serve(conn, session_pid, @quiet_keepalive)
      refute_received {:plug_conn, :sent}
      assert conn.state == :unset
    end

    @tag doc: """
         A registration failure that does not mean "session gone" — a
         session crash, a call timeout from a saturated mailbox — still
         answers {:error, :session_gone} (the client's 404 reads
         "re-initialize" either way), but it must not be silent: without
         this line an operator cannot tell an expired session from a
         server too busy to register the stream. The stub is started with
         GenServer.start/2, not start_link/2, so its abnormal exit does
         not reach the test process.
         """
    test "logs a registration failure whose reason is not a dead session" do
      {:ok, session_pid} = GenServer.start(RefusingSession, nil)

      log =
        capture_log(fn ->
          assert {:error, :session_gone} =
                   Stream.serve(conn(:get, "/"), session_pid, @quiet_keepalive)
        end)

      refute_received {:plug_conn, :sent}
      assert log =~ "SSE stream registration failed"
      assert log =~ ":boom"
    end

    @tag doc: """
         When the session process dies, the stream must end and hand its
         conn back — the request process returns it up the plug stack.
         This prevents orphaned streams from holding connections open
         after the session has been cleaned up.
         """
    test "the stream ends when the session dies" do
      session_pid = start_session()
      task = serve_task(session_pid, [], @quiet_keepalive)
      _stream_pid = wait_for_stream(session_pid)

      :ok = GenServer.stop(session_pid)

      assert {:ok, conn} = Task.await(task)
      assert conn.status == 200
    end

    @tag doc: """
         Adapter shutdown: Bandit's connection process traps exits, so the
         supervisor's shutdown signal on deploy/stop arrives as an
         {:EXIT, _, :shutdown} message. The loop must treat it as the end
         of the stream — a catch-all that drops it leaves every open
         stream holding the supervisor's shutdown timeout and being
         brutally killed mid-stream.
         """
    test "the stream ends when the adapter asks for shutdown" do
      session_pid = start_session()
      task = serve_task(session_pid, [], @quiet_keepalive)
      stream_pid = wait_for_stream(session_pid)

      send(stream_pid, {:EXIT, self(), :shutdown})

      assert {:ok, conn} = Task.await(task)
      assert conn.status == 200
    end
  end

  describe "push/3" do
    test "writes the payload and answers a {:caller, from} reply_to via GenServer.reply" do
      session_pid = start_session()
      task = serve_task(session_pid, [], @quiet_keepalive)
      stream_pid = wait_for_stream(session_pid)

      ref = make_ref()
      json = JSON.encode!(%{"jsonrpc" => "2.0", "method" => "test"})
      assert :ok = Stream.push(stream_pid, json, {:caller, {self(), ref}})
      assert_receive {^ref, :ok}, 1000

      :ok = Stream.replace(stream_pid)
      assert {:ok, conn} = Task.await(task)
      assert conn.resp_body =~ "id: evt-2\ndata: {"
      assert conn.resp_body =~ ~s("method":"test")
    end

    @tag doc: """
         The server-request round trip's push leg: an {:ack, session, tag}
         reply_to must come back as a {:push_ack, tag, result} message —
         the shape the session's ack state machine handles by name. A
         failure means the loop and the session no longer agree on the
         ack protocol.
         """
    test "answers an {:ack, session, tag} reply_to with a {:push_ack, tag, result} message" do
      session_pid = start_session()
      task = serve_task(session_pid, [], @quiet_keepalive)
      stream_pid = wait_for_stream(session_pid)

      tag = {"srv-1", make_ref()}

      json =
        JSON.encode!(%{"jsonrpc" => "2.0", "id" => "srv-1", "method" => "sampling/createMessage"})

      assert :ok = Stream.push(stream_pid, json, {:ack, self(), tag})
      assert_receive {:push_ack, ^tag, :ok}, 1000

      :ok = Stream.replace(stream_pid)
      assert {:ok, conn} = Task.await(task)
      assert conn.resp_body =~ ~s("method":"sampling/createMessage")
    end

    test "a :none reply_to writes without expecting an answer" do
      session_pid = start_session()
      task = serve_task(session_pid, [], @quiet_keepalive)
      stream_pid = wait_for_stream(session_pid)

      json = JSON.encode!(%{"jsonrpc" => "2.0", "method" => "notifications/tools/list_changed"})
      assert :ok = Stream.push(stream_pid, json, :none)

      :ok = Stream.replace(stream_pid)
      assert {:ok, conn} = Task.await(task)
      assert conn.resp_body =~ ~s("method":"notifications/tools/list_changed")
    end
  end

  describe "replace/1" do
    @tag doc: """
         Replacement is asking, not killing: the new GET registers, the
         session asks the old loop to stop, the old serve returns its
         committed conn, and the replaced request completes normally.
         The first stream's bytes stay exactly its priming event.
         """
    test "a second serve on the same session replaces the first" do
      session_pid = start_session()
      first = serve_task(session_pid, [], @quiet_keepalive)
      first_pid = wait_for_stream(session_pid)

      second = serve_task(session_pid, [], @quiet_keepalive)
      second_pid = wait_for_stream(session_pid, first_pid)

      assert {:ok, first_conn} = Task.await(first)
      assert first_conn.resp_body == "id: evt-1\ndata: \n\n"

      :ok = Stream.replace(second_pid)
      assert {:ok, _second_conn} = Task.await(second)
    end
  end

  describe "keepalive" do
    @tag doc: """
         First keepalive test in the suite (the old module's tests only
         ever set the interval long to suppress the timer). The loop owns
         scheduling: a short interval must produce the SSE comment frame
         in the stream bytes.
         """
    test "writes keepalive comments on the configured interval" do
      session_pid = start_session()
      task = serve_task(session_pid, [], %{keepalive_interval: 30})
      stream_pid = wait_for_stream(session_pid)

      Process.sleep(120)
      :ok = Stream.replace(stream_pid)

      assert {:ok, conn} = Task.await(task)
      assert conn.resp_body =~ ":keepalive\n\n"
    end
  end

  describe "client disconnect" do
    @tag doc: """
         A disconnect is the one ending the Session cannot observe for
         itself: the loop's process belongs to the adapter and outlives
         the stream, so no :DOWN ever reaches the Session's stream
         monitor. The failing write is the whole signal, and the loop has
         to relay it. A failure of the last assertion means a vanished
         client leaves stream_pid registered and every later plain push
         waits out its caller's full call timeout against a mailbox nobody
         drains.
         """
    test "a failed push answers {:error, :disconnected} and clears the registration" do
      session_pid = start_session()
      task = serve_task(session_pid, [], @quiet_keepalive, VanishingSocket)
      stream_pid = wait_for_stream(session_pid)

      ref = make_ref()
      json = JSON.encode!(%{"jsonrpc" => "2.0", "method" => "test"})
      :ok = Stream.push(stream_pid, json, {:caller, {self(), ref}})
      assert_receive {^ref, {:error, :disconnected}}, 1000

      assert {:ok, conn} = Task.await(task)
      assert conn.resp_body == "id: evt-1\ndata: \n\n"
      assert wait_for_no_stream(session_pid)
    end

    @tag doc: """
         The keepalive write is the same disconnect with nobody waiting
         on it — no caller to answer, so the cleared registration is the
         only observable. Without it a client that vanishes and is never
         pushed to stays registered until the connection process happens
         to die.
         """
    test "a failed keepalive write ends the stream and clears the registration" do
      session_pid = start_session()
      task = serve_task(session_pid, [], %{keepalive_interval: 30}, VanishingSocket)

      assert {:ok, conn} = Task.await(task)
      assert conn.resp_body == "id: evt-1\ndata: \n\n"
      assert wait_for_no_stream(session_pid)
    end

    @tag doc: """
         The write can already fail on the priming event, and that path
         never enters the loop. It must still end the same way — hand the
         conn back, clear the registration — rather than arm a keepalive
         timer and wait in a loop on a connection that is already gone,
         which is what the carried-over code did (the failed write was
         swallowed and the counter simply did not advance).
         """
    test "a failed priming write ends the stream before the loop and clears the registration" do
      session_pid = start_session()
      task = serve_task(session_pid, [], @quiet_keepalive, ClosedSocket)

      assert {:ok, conn} = Task.await(task)
      assert conn.state == :chunked
      assert conn.resp_body == ""
      assert wait_for_no_stream(session_pid)
    end

    @tag doc: """
         push/3's @doc promises a push queued in the registration→loop-entry
         gap is answered. When the priming write fails the loop is never
         entered, so the answer has to come from the close path's drain —
         without it the queued push waits out its caller's full call
         timeout and answers {:error, :timeout} for a client that is
         provably gone.
         """
    test "a push queued during a failed priming write is answered {:error, :disconnected}" do
      session_pid = start_session()
      task = serve_task(session_pid, [], @quiet_keepalive, StallingClosedSocket)
      stream_pid = wait_for_stream(session_pid)

      ref = make_ref()
      json = JSON.encode!(%{"jsonrpc" => "2.0", "method" => "test"})
      :ok = Stream.push(stream_pid, json, {:caller, {self(), ref}})
      assert_receive {^ref, {:error, :disconnected}}, 1000

      assert {:ok, conn} = Task.await(task)
      assert conn.resp_body == ""
      assert wait_for_no_stream(session_pid)
    end
  end

  describe "stray messages" do
    @tag doc: """
         D5 regression guard: the loop is the request process holding a
         committed 200, so a stray message must never crash it (the old
         GenServer had no catch-all — a stray was a function_clause crash
         the link turned fatal). A successful push after two strays
         proves the loop consumed them and kept serving.
         """
    test "the loop drops unknown messages and keeps serving" do
      session_pid = start_session()
      task = serve_task(session_pid, [], @quiet_keepalive)
      stream_pid = wait_for_stream(session_pid)

      send(stream_pid, {:unexpected, :garbage})
      send(stream_pid, :read_timeout)

      ref = make_ref()
      json = JSON.encode!(%{"jsonrpc" => "2.0", "method" => "still-alive"})
      assert :ok = Stream.push(stream_pid, json, {:caller, {self(), ref}})
      assert_receive {^ref, :ok}, 1000

      :ok = Stream.replace(stream_pid)
      assert {:ok, conn} = Task.await(task)
      assert conn.resp_body =~ "still-alive"
    end
  end

  defp start_session do
    session_id = "stream-test-#{System.unique_integer([:positive])}"

    {:ok, pid} = Session.start_link({session_id, Testing.build_session_opts()})

    pid
  end

  defp serve_task(session_pid, req_headers, opts, adapter \\ nil) do
    Task.async(fn ->
      conn =
        Enum.reduce(req_headers, conn(:get, "/"), fn {name, value}, acc ->
          put_req_header(acc, name, value)
        end)

      Stream.serve(with_adapter(conn, adapter), session_pid, opts)
    end)
  end

  # Swaps the conn's adapter module while keeping Plug.Test's payload —
  # both send_chunked/2 and chunk/2 thread the payload and leave the
  # module alone, so the stand-ins delegate whatever they do not fail.
  defp with_adapter(conn, nil), do: conn

  defp with_adapter(conn, module) do
    {_adapter, payload} = conn.adapter
    %{conn | adapter: {module, payload}}
  end

  # Registration is asynchronous from the test's viewpoint: poll the
  # session for the (new) stream pid instead of sleeping a fixed 100 ms.
  # `previous` lets the replacement test wait for the *second* stream.
  defp wait_for_stream(session_pid, previous \\ nil, remaining_ms \\ 2_000) do
    case Session.get_state(session_pid).stream_pid do
      pid when is_pid(pid) and pid != previous ->
        pid

      _ when remaining_ms > 0 ->
        Process.sleep(10)
        wait_for_stream(session_pid, previous, remaining_ms - 10)

      _ ->
        flunk("stream did not register within 2s")
    end
  end

  # The disconnect notification is a cast (the loop must never block on
  # the session it is reporting to), so the clear is polled the same way
  # registration is.
  defp wait_for_no_stream(session_pid, remaining_ms \\ 2_000) do
    case Session.get_state(session_pid).stream_pid do
      nil ->
        true

      _pid when remaining_ms > 0 ->
        Process.sleep(10)
        wait_for_no_stream(session_pid, remaining_ms - 10)

      _pid ->
        flunk("the stream registration was not cleared within 2s")
    end
  end
end
