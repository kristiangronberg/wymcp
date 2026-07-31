defmodule Wymcp.SessionTest do
  use ExUnit.Case, async: true

  alias Wymcp.Session
  alias Wymcp.Testing
  alias Wymcp.Transport.StreamManager

  defmodule TerminateTracker do
    @moduledoc false
    use Wymcp.Server

    @impl Wymcp.Server
    def terminate(reason, assigns) do
      send(assigns[:test_pid], {:terminated, reason})
      :ok
    end
  end

  defmodule RuntimeTool do
    @moduledoc false
    use Wymcp.Tool

    @impl true
    def name, do: "runtime_tool"

    @impl true
    def description, do: "A tool registered at runtime"

    @impl true
    def actions do
      %{
        run: %{
          description: "Run",
          properties: %{},
          required: [],
          defaults: %{}
        }
      }
    end

    @impl Wymcp.Tool
    def run_action(:run, _data, _ctx) do
      {:ok, %{result: "runtime"}}
    end
  end

  defmodule ReservedNameRuntimeTool do
    @moduledoc false
    use Wymcp.Tool

    @impl true
    def name, do: "help"

    @impl true
    def description, do: "Illegally claims the reserved name"

    @impl true
    def actions do
      %{run: %{description: "Run", properties: %{}, required: [], defaults: %{}}}
    end

    @impl Wymcp.Tool
    def run_action(:run, _data, _ctx), do: {:ok, %{}}
  end

  defmodule MalformedRuntimeTool do
    @moduledoc false
    use Wymcp.Tool

    @impl true
    def name, do: "malformed"

    @impl true
    def description, do: "References a field absent from :properties"

    @impl true
    def actions do
      %{run: %{description: "Run", properties: %{}, required: ["ghost"], defaults: %{}}}
    end

    @impl Wymcp.Tool
    def run_action(:run, _data, _ctx), do: {:ok, %{}}
  end

  defmodule NewlineDescriptionRuntimeTool do
    @moduledoc false
    use Wymcp.Tool

    @impl true
    def name, do: "newline_description"

    @impl true
    def description, do: "An action description contains a newline"

    @impl true
    def actions do
      %{
        run: %{
          description: "First line\nsecond line",
          properties: %{},
          required: [],
          defaults: %{}
        }
      }
    end

    @impl Wymcp.Tool
    def run_action(:run, _data, _ctx), do: {:ok, %{}}
  end

  defmodule StrayKeyRuntimeTool do
    @moduledoc false
    use Wymcp.Tool

    @impl true
    def name, do: "stray_key_runtime_tool"

    @impl true
    def description, do: "Carries an action-schema key outside the vocabulary"

    @impl true
    def actions do
      %{run: %{description: "Run", properties: %{}, example: [%{}]}}
    end

    @impl Wymcp.Tool
    def run_action(:run, _data, _ctx), do: {:ok, %{}}
  end

  describe "start_link/1" do
    test "starts a session and stores capabilities" do
      {:ok, pid} =
        Session.start_link(
          {"test-session-1",
           Testing.build_session_opts(client_capabilities: %{"sampling" => %{}})}
        )

      assert is_pid(pid)
      assert Process.alive?(pid)

      state = Session.get_state(pid)
      assert state.protocol_version == "2025-11-25"
      assert state.client_capabilities == %{"sampling" => %{}}
      assert is_binary(state.session_id)
      assert byte_size(state.session_id) > 0
      assert state.assigns == %{}
      assert state.status == :initializing
    end
  end

  describe "mark_ready/1" do
    test "transitions status from initializing to ready" do
      {:ok, pid} = Session.start_link({"test-ready-1", Testing.build_session_opts()})

      assert Session.get_state(pid).status == :initializing
      :ok = Session.mark_ready(pid)
      assert Session.get_state(pid).status == :ready
    end
  end

  describe "ready?/1" do
    @tag doc: """
         Sessions start in :initializing status and transition to :ready after
         notifications/initialized. ready?/1 must reflect the current status
         without side effects.
         """
    test "returns false for a new session" do
      {:ok, pid, _id} = Session.start_session(Testing.build_session_opts())

      refute Session.ready?(pid)
    end

    test "returns true after mark_ready" do
      {:ok, pid, _id} = Session.start_session(Testing.build_session_opts())

      Session.mark_ready(pid)
      assert Session.ready?(pid)
    end
  end

  describe "get_state/1" do
    test "returns the full session state" do
      {:ok, pid} = Session.start_link({"test-state-1", Testing.build_session_opts()})

      state = Session.get_state(pid)
      assert %Session.State{} = state
      assert state.client_info == %{"name" => "test", "version" => "1.0"}
    end
  end

  describe "assigns" do
    test "put_assigns/2 merges new values into assigns" do
      {:ok, pid} = Session.start_link({"test-assigns-1", Testing.build_session_opts()})

      :ok = Session.put_assigns(pid, %{counter: 0, user: "alice"})
      state = Session.get_state(pid)
      assert state.assigns == %{counter: 0, user: "alice"}

      :ok = Session.put_assigns(pid, %{counter: 1})
      state = Session.get_state(pid)
      assert state.assigns == %{counter: 1, user: "alice"}
    end
  end

  describe "session idle timeout" do
    test "session terminates after idle timeout" do
      Process.flag(:trap_exit, true)

      {:ok, pid} =
        Session.start_link(
          {"test-timeout-1", Testing.build_session_opts(session_idle_timeout: 50)}
        )

      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, {:shutdown, :session_expired}}, 200
    end

    test "activity resets the idle timer" do
      {:ok, pid} =
        Session.start_link(
          {"test-touch-1", Testing.build_session_opts(session_idle_timeout: 100)}
        )

      # Touch session before timeout
      Process.sleep(60)
      Session.touch(pid)
      Process.sleep(60)
      assert Process.alive?(pid)
    end
  end

  describe "lookup/1" do
    test "finds a session by its session_id" do
      {:ok, pid, session_id} = Session.start_session(Testing.build_session_opts())

      assert {:ok, ^pid} = Session.lookup(session_id)
    end

    test "returns error for unknown session_id" do
      assert {:error, :not_found} = Session.lookup("nonexistent")
    end
  end

  describe "request tracking" do
    test "tracks and completes requests" do
      {:ok, pid, _} = Session.start_session(Testing.build_session_opts())

      :ok = Session.track_request(pid, "req-1", "tools/call")
      state = Session.get_state(pid)
      assert Map.has_key?(state.pending_requests, "req-1")
      assert state.pending_requests["req-1"].method == "tools/call"

      :ok = Session.complete_request(pid, "req-1")
      state = Session.get_state(pid)
      refute Map.has_key?(state.pending_requests, "req-1")
    end
  end

  describe "server callbacks" do
    @tag doc: """
         When a server module is configured, its terminate/2 callback must
         fire when the session shuts down. The callback receives the shutdown
         reason and the final assigns. A failure here means the GenServer
         terminate/2 is not invoking the server module.
         """
    test "invokes server.terminate/2 on session shutdown" do
      {:ok, pid, _id} =
        Session.start_session(Testing.build_session_opts(server: TerminateTracker))

      # Store our pid in assigns so the terminate callback can notify us
      Session.put_assigns(pid, %{test_pid: self()})
      Session.terminate_session(Session.get_state(pid).session_id)

      assert_receive {:terminated, _reason}, 1000
    end

    test "session works without server module" do
      {:ok, pid, _id} = Session.start_session(Testing.build_session_opts())

      assert is_pid(pid)
      Session.terminate_session(Session.get_state(pid).session_id)
    end
  end

  describe "runtime tool registration" do
    @tag doc: """
         Runtime tools are stored separately from compile-time tools and
         merged on access. register_tool/2 adds a tool module to the
         session's runtime_tools list. unregister_tool/2 removes by name.
         get_tools/1 returns the merged list with runtime taking precedence.
         """
    test "register_tool/2 adds a tool to the session" do
      {:ok, pid, _id} = start_session()
      assert :ok = Session.register_tool(pid, RuntimeTool)
      tools = Session.get_tools(pid)
      assert Enum.any?(tools, &(&1.name() == "runtime_tool"))
    end

    test "unregister_tool/2 removes a tool by name" do
      {:ok, pid, _id} = start_session()
      Session.register_tool(pid, RuntimeTool)
      assert :ok = Session.unregister_tool(pid, "runtime_tool")
      tools = Session.get_tools(pid)
      refute Enum.any?(tools, &(&1.name() == "runtime_tool"))
    end

    test "get_tools/1 merges compile-time and runtime tools" do
      {:ok, pid, _id} = start_session()
      Session.register_tool(pid, RuntimeTool)
      tools = Session.get_tools(pid)

      compile_names = Enum.map(start_session_tools(), & &1.name())
      runtime_names = ["runtime_tool"]
      tool_names = Enum.map(tools, & &1.name())
      assert Enum.all?(compile_names ++ runtime_names, &(&1 in tool_names))
    end

    @tag doc: """
         When a runtime tool has the same name as a compile-time tool, the
         runtime version takes precedence. This enables the Server.init/2
         callback to override default tools with user-specific variants.
         """
    test "runtime tools take precedence on name collision" do
      {:ok, pid, _id} = start_session()

      Session.register_tool(pid, RuntimeTool)
      Session.register_tool(pid, RuntimeTool)
      tools = Session.get_tools(pid)

      runtime_count = Enum.count(tools, &(&1.name() == "runtime_tool"))
      assert runtime_count == 1
    end

    test "get_tools/1 returns compile-time tools when no runtime tools" do
      {:ok, pid, _id} = start_session()
      tools = Session.get_tools(pid)
      assert length(tools) == length(start_session_tools())
    end

    test "register_tool/2 pushes listChanged notification" do
      {:ok, pid, _id} = start_session()
      stream_pid = spawn_fake_stream(pid)

      Session.register_tool(pid, RuntimeTool)

      assert_receive {:fake_stream_push,
                      %{
                        "jsonrpc" => "2.0",
                        "method" => "notifications/tools/list_changed"
                      }},
                     1000

      Process.exit(stream_pid, :normal)
    end

    test "unregister_tool/2 pushes listChanged notification" do
      {:ok, pid, _id} = start_session()
      Session.register_tool(pid, RuntimeTool)
      stream_pid = spawn_fake_stream(pid)

      Session.unregister_tool(pid, "runtime_tool")

      assert_receive {:fake_stream_push,
                      %{
                        "jsonrpc" => "2.0",
                        "method" => "notifications/tools/list_changed"
                      }},
                     1000

      Process.exit(stream_pid, :normal)
    end

    test "register_tool/2 succeeds even without a stream" do
      {:ok, pid, _id} = start_session()
      assert :ok = Session.register_tool(pid, RuntimeTool)
    end
  end

  describe "register_tool/2 validation" do
    test "raises on the reserved tool name and registers nothing" do
      {:ok, pid, _id} = start_session()

      assert_raise ArgumentError,
                   ~r/reserved name "help"\. The help tool is provided by Wymcp and cannot be replaced at runtime\./,
                   fn ->
                     Session.register_tool(pid, ReservedNameRuntimeTool)
                   end

      assert Session.get_tools(pid) == []
    end

    test "raises on a malformed action schema, same as boot validation" do
      {:ok, pid, _id} = start_session()

      assert_raise ArgumentError, ~r/:required references field\(s\)/, fn ->
        Session.register_tool(pid, MalformedRuntimeTool)
      end

      assert Session.get_tools(pid) == []
    end

    test "raises on an action description containing a newline, same as boot validation" do
      {:ok, pid, _id} = start_session()

      assert_raise ArgumentError, ~r/newline/, fn ->
        Session.register_tool(pid, NewlineDescriptionRuntimeTool)
      end

      assert Session.get_tools(pid) == []
    end

    test "raises on an action-schema key outside the vocabulary, same as boot validation" do
      {:ok, pid, _id} = start_session()

      assert_raise ArgumentError, ~r/unknown action-schema key/, fn ->
        Session.register_tool(pid, StrayKeyRuntimeTool)
      end

      assert Session.get_tools(pid) == []
    end
  end

  describe "protocol_version/1" do
    test "returns the negotiated protocol version" do
      {:ok, pid, _session_id} = Session.start_session(Testing.build_session_opts())

      assert Session.protocol_version(pid) == "2025-11-25"
    end
  end

  describe "log_level" do
    test "defaults to nil" do
      {:ok, pid, _id} = start_session()
      state = Session.get_state(pid)
      assert state.log_level == nil
    end

    test "set_log_level/2 updates the level" do
      {:ok, pid, _id} = start_session()
      assert :ok = Session.set_log_level(pid, "warning")
      state = Session.get_state(pid)
      assert state.log_level == "warning"
    end

    test "set_log_level/2 rejects invalid levels" do
      {:ok, pid, _id} = start_session()
      assert {:error, :invalid_level} = Session.set_log_level(pid, "verbose")
    end
  end

  describe "stream management" do
    @tag doc: """
         register_stream/2 stores the stream pid on the session and monitors
         it. If the stream process dies, the session clears :stream_pid
         automatically. This mutual monitoring is critical for SSE cleanup —
         without it, a disconnected client leaves a dangling stream reference.
         """
    test "register_stream/2 stores the stream pid" do
      {:ok, pid, _id} = start_session()
      stream_pid = spawn(fn -> Process.sleep(:infinity) end)

      assert :ok = Session.register_stream(pid, stream_pid)
      state = Session.get_state(pid)
      assert state.stream_pid == stream_pid
    end

    test "register_stream/2 with nil clears the stream pid" do
      {:ok, pid, _id} = start_session()
      stream_pid = spawn(fn -> Process.sleep(:infinity) end)

      Session.register_stream(pid, stream_pid)
      assert :ok = Session.register_stream(pid, nil)
      state = Session.get_state(pid)
      assert state.stream_pid == nil
    end

    @tag doc: """
         One active stream per session: registering a new stream pid must
         stop the previous manager, or a reconnecting client leaves a
         zombie stream consuming keepalives until its next write fails.
         The stop is an asynchronous :replaced cast, never
         Process.exit(old, :kill): a StreamManager is linked to the GET
         request process that started it, and a :killed exit propagates
         across that link and tears the request process down before it can
         finish its response. The stand-in is spawn_link'd for exactly
         that reason — this test process stands in for the request
         process, so a regression to :kill surfaces here as the test
         process itself exiting :killed rather than as a failed assertion.
         """
    test "register_stream/2 with a new pid stops the previously registered stream" do
      {:ok, pid, _id} = start_session()
      old_stream = spawn_linked_stream(self())
      new_stream = spawn_linked_stream(self())
      ref = Process.monitor(old_stream)

      Session.register_stream(pid, old_stream)
      assert :ok = Session.register_stream(pid, new_stream)

      assert_receive {:replaced_cast, ^old_stream}, 1000
      assert_receive {:DOWN, ^ref, :process, ^old_stream, :normal}, 1000
      assert Session.get_state(pid).stream_pid == new_stream
    end

    test "register_stream/2 with the already-registered pid does not stop it" do
      {:ok, pid, _id} = start_session()
      stream_pid = spawn_linked_stream(self())

      Session.register_stream(pid, stream_pid)
      assert :ok = Session.register_stream(pid, stream_pid)

      refute_receive {:replaced_cast, ^stream_pid}, 50
      assert Process.alive?(stream_pid)
      assert Session.get_state(pid).stream_pid == stream_pid
    end

    @tag doc: """
         A dead pid can arrive here: the registering manager's own
         register_stream call timed out (a session mailbox running behind),
         start_link answered :ignore, and the manager exited — but a
         timed-out GenServer.call leaves its request in the target's
         mailbox, so the session still dequeues it later. Acting on that
         poison message would stop the healthy current stream and leave
         stream_pid nil; it must leave the registration untouched.
         """
    test "register_stream/2 with a dead pid does not replace the current stream" do
      {:ok, pid, _id} = start_session()
      stream_pid = spawn_linked_stream(self())
      Session.register_stream(pid, stream_pid)

      dead_pid = spawn(fn -> :ok end)
      ref = Process.monitor(dead_pid)
      assert_receive {:DOWN, ^ref, :process, ^dead_pid, :normal}

      assert :ok = Session.register_stream(pid, dead_pid)

      refute_receive {:replaced_cast, ^stream_pid}, 50
      assert Session.get_state(pid).stream_pid == stream_pid
    end

    @tag doc: """
         When the stream process crashes, the session must automatically
         clear :stream_pid via the monitor's :DOWN message. A failure here
         means the session is not monitoring the stream, which would leave
         stale references and break future GET reconnections.
         """
    test "clears stream_pid when stream process dies" do
      {:ok, pid, _id} = start_session()
      stream_pid = spawn(fn -> Process.sleep(:infinity) end)

      Session.register_stream(pid, stream_pid)
      Process.exit(stream_pid, :kill)

      # Give the :DOWN message time to arrive
      Process.sleep(50)
      state = Session.get_state(pid)
      assert state.stream_pid == nil
    end

    test "push_event/2 returns {:error, :no_stream} when no stream registered" do
      {:ok, pid, _id} = start_session()
      assert {:error, :no_stream} = Session.push_event(pid, %{"test" => true})
    end

    @tag doc: """
         push_event/2 delegates to the stream process. We test with a fake
         stream that receives the message, since real StreamManager requires
         a Plug.Conn. A failure here means the session is not forwarding
         to the stream pid correctly.
         """
    test "push_event/2 sends message to stream process" do
      {:ok, pid, _id} = start_session()

      test_pid = self()

      stream_pid =
        spawn(fn ->
          receive do
            {:"$gen_call", from, {:push, message}} ->
              GenServer.reply(from, :ok)
              send(test_pid, {:pushed, message})
          end

          Process.sleep(:infinity)
        end)

      Session.register_stream(pid, stream_pid)
      assert :ok = Session.push_event(pid, %{"jsonrpc" => "2.0", "method" => "test"})
      assert_receive {:pushed, %{"jsonrpc" => "2.0", "method" => "test"}}, 1000
    end
  end

  describe "await_client_response/4 and deliver_response/3" do
    @tag doc: """
         The core deferred-reply cycle: await_client_response pushes a
         message via SSE and blocks the caller. deliver_response unblocks
         it with the client's answer. This is the mechanism that makes
         sampling and elicitation work. A failure here means tools cannot
         get responses from the client mid-execution.
         """
    test "deliver_response unblocks a waiting await_client_response" do
      {:ok, pid, _id} = start_ready_session()

      # We need a stream to push events — use a fake that captures messages
      stream_pid = spawn_fake_stream(pid)

      request_id = "srv-1"
      message = %{"jsonrpc" => "2.0", "id" => request_id, "method" => "sampling/createMessage"}

      # await blocks, so run it in a task
      task =
        Task.async(fn ->
          Session.await_client_response(pid, request_id, message, 5000)
        end)

      # Give the GenServer time to process the call and push the event
      Process.sleep(50)

      # Deliver the response
      response_result = %{"role" => "assistant", "content" => %{"type" => "text", "text" => "hi"}}
      :ok = Session.deliver_response(pid, request_id, {:ok, response_result})

      # The task should now complete
      assert {:ok, ^response_result} = Task.await(task, 1000)

      # Stream should have received the pushed message
      assert_received {:fake_stream_push, ^message}

      Process.exit(stream_pid, :normal)
    end

    @tag doc: """
         When no client response arrives within the timeout, the blocked
         caller must receive {:error, :timeout}. The pending request entry
         must be cleaned up so it doesn't leak memory.
         """
    test "returns {:error, :timeout} when no response arrives" do
      {:ok, pid, _id} = start_ready_session()
      stream_pid = spawn_fake_stream(pid)

      request_id = "srv-timeout"
      message = %{"jsonrpc" => "2.0", "id" => request_id, "method" => "sampling/createMessage"}

      result = Session.await_client_response(pid, request_id, message, 100)
      assert result == {:error, :timeout}

      # Verify cleanup: no pending requests left
      state = Session.get_state(pid)
      assert state.pending_server_requests == %{}

      Process.exit(stream_pid, :normal)
    end

    @tag doc: """
         When no SSE stream is connected, await_client_response must
         return {:error, :no_stream} immediately rather than blocking.
         There's no way to push the request to the client.
         """
    test "returns {:error, :no_stream} when no SSE stream is connected" do
      {:ok, pid, _id} = start_ready_session()

      request_id = "srv-nostream"
      message = %{"jsonrpc" => "2.0", "id" => request_id, "method" => "sampling/createMessage"}

      assert {:error, :no_stream} = Session.await_client_response(pid, request_id, message, 5000)
    end

    @tag doc: """
         The register→attach window: a real StreamManager registers with the
         session in init/1 but holds no conn until attach/2, so its push
         answers {:error, :no_stream}. await_client_response must forward
         that immediately, the way push_event/2 does. A failure here shows
         up as {:error, :timeout} after the full timeout instead — the
         request was never delivered and the caller was never told, which
         is what discarding the push result costs.
         """
    test "returns {:error, :no_stream} when the stream is registered but not attached" do
      {:ok, pid, _id} = start_ready_session()

      assert {:ok, stream_pid} = StreamManager.start_link(%{session_pid: pid})
      assert Session.get_state(pid).stream_pid == stream_pid

      request_id = "srv-preattach"
      message = %{"jsonrpc" => "2.0", "id" => request_id, "method" => "sampling/createMessage"}

      assert {:error, :no_stream} = Session.await_client_response(pid, request_id, message, 200)

      :ok = GenServer.stop(stream_pid)
    end

    @tag doc: """
         A response for an unknown request_id (e.g. the request timed out
         and was already cleaned up) must be silently ignored, not crash
         the session.
         """
    test "deliver_response for unknown request_id is ignored" do
      {:ok, pid, _id} = start_ready_session()

      assert :ok = Session.deliver_response(pid, "nonexistent", {:ok, %{}})
      # Session is still alive
      assert Session.ready?(pid)
    end

    @tag doc: """
         When the client returns a JSON-RPC error instead of a result,
         deliver_response must forward it as {:error, error_map} so the
         tool can handle the rejection.
         """
    test "delivers error responses" do
      {:ok, pid, _id} = start_ready_session()
      stream_pid = spawn_fake_stream(pid)

      request_id = "srv-err"
      message = %{"jsonrpc" => "2.0", "id" => request_id, "method" => "sampling/createMessage"}

      task =
        Task.async(fn ->
          Session.await_client_response(pid, request_id, message, 5000)
        end)

      Process.sleep(50)

      error = %{"code" => -1, "message" => "user denied"}
      :ok = Session.deliver_response(pid, request_id, {:error, error})

      assert {:error, ^error} = Task.await(task, 1000)

      Process.exit(stream_pid, :normal)
    end
  end

  describe "negotiated_version/1" do
    import Plug.Test
    import Plug.Conn

    test "returns the session's pinned version when a session pid is assigned" do
      {:ok, _pid, session_id} =
        Wymcp.Session.start_session(
          Testing.build_session_opts(client_info: %{}, protocol_version: "2025-03-26")
        )

      {:ok, pid} = Wymcp.Session.lookup(session_id)

      conn =
        :post
        |> conn("/", "")
        |> assign(:wymcp_session_pid, pid)

      assert Wymcp.Session.negotiated_version(conn) == "2025-03-26"
    end

    @tag doc: """
         Sessionless fallback honours the MCP-Protocol-Version request
         header when present and supported. Claude Code drops the
         Mcp-Session-Id header on tools/call but still sends this one.
         """
    test "falls back to the request header when no session pid is present" do
      conn =
        :post
        |> conn("/", "")
        |> put_req_header("mcp-protocol-version", "2025-06-18")

      assert Wymcp.Session.negotiated_version(conn) == "2025-06-18"
    end

    test "falls back to latest/0 when no session pid and no header" do
      conn = conn(:post, "/", "")

      assert Wymcp.Session.negotiated_version(conn) ==
               Wymcp.ProtocolVersion.latest()
    end

    test "ignores an unsupported header value and falls back to latest/0" do
      conn =
        :post
        |> conn("/", "")
        |> put_req_header("mcp-protocol-version", "1999-01-01")

      assert Wymcp.Session.negotiated_version(conn) ==
               Wymcp.ProtocolVersion.latest()
    end
  end

  defp start_ready_session do
    {:ok, pid, id} =
      Session.start_session(Testing.build_session_opts(client_capabilities: %{"sampling" => %{}}))

    Session.mark_ready(pid)
    {:ok, pid, id}
  end

  defp spawn_fake_stream(session_pid) do
    test_pid = self()

    stream_pid =
      spawn(fn ->
        receive_loop(test_pid)
      end)

    # Register with the session
    Session.register_stream(session_pid, stream_pid)
    stream_pid
  end

  # Stands in for a StreamManager the way the router really starts one: linked
  # to the process that started it (spawn_link here, StreamManager.start_link/1
  # there), so a replacement that kills instead of asking takes this test
  # process down with it. Forwards the session's :replaced cast instead of
  # handling it, then returns — exiting :normal, the same reason
  # StreamManager's own clause uses.
  defp spawn_linked_stream(test_pid) do
    spawn_link(fn ->
      receive do
        {:"$gen_cast", :replaced} -> send(test_pid, {:replaced_cast, self()})
      end
    end)
  end

  defp receive_loop(test_pid) do
    receive do
      {:"$gen_call", from, {:push, message}} ->
        send(test_pid, {:fake_stream_push, message})
        GenServer.reply(from, :ok)
        receive_loop(test_pid)
    end
  end

  defp start_session do
    Session.start_session(Testing.build_session_opts(tools: start_session_tools()))
  end

  defp start_session_tools, do: []
end
