defmodule Wymcp.SessionTest do
  use ExUnit.Case, async: true

  alias Wymcp.Session
  alias Wymcp.Testing

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

  defmodule OtherRuntimeTool do
    @moduledoc false
    use Wymcp.Tool

    @impl true
    def name, do: "other_runtime_tool"

    @impl true
    def description, do: "A second tool registered at runtime"

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
      {:ok, %{result: "other runtime"}}
    end
  end

  defmodule ShadowingRuntimeTool do
    @moduledoc false
    use Wymcp.Tool

    # Deliberately the same name as RuntimeTool, a different module: the
    # D4a case where the served list changes without the count changing.
    @impl true
    def name, do: "runtime_tool"

    @impl true
    def description, do: "A different module claiming RuntimeTool's name"

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
      {:ok, %{result: "shadowing"}}
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
      {:ok, pid, _session_id} =
        Session.start_session(Testing.build_session_opts(session_idle_timeout: 50))

      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, {:shutdown, :session_expired}}, 500
    end

    test "activity resets the idle timer" do
      {:ok, pid, _session_id} =
        Session.start_session(Testing.build_session_opts(session_idle_timeout: 100))

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

    @tag doc: """
         Pins the unregister's own notification, which needs the flag to be
         clean first: attach, register (the rising edge), consume that
         notification and clear the flag with a tools/list read, and only
         then unregister. Written this way because the obvious ordering —
         register, attach, unregister — makes the assertion match the
         attach's notification instead, and passes while proving nothing
         about unregister_tool/2.
         """
    test "unregister_tool/2 pushes listChanged notification" do
      {:ok, pid, _id} = start_session()
      stream_pid = spawn_fake_stream(pid)
      Session.register_tool(pid, RuntimeTool)

      assert_receive {:fake_stream_push,
                      %{
                        "jsonrpc" => "2.0",
                        "method" => "notifications/tools/list_changed"
                      }},
                     1000

      Session.get_tools_for_list(pid)

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

    @tag doc: """
         The topic's whole case: Server.init/2 registers tools during
         notifications/initialized, before the client opens its GET stream,
         so the change has nowhere to send. A failure means the obligation
         is being dropped again instead of recorded — the notification is
         lost and no stream attach will repair it.
         """
    test "register_tool/2 marks the dirty tool list when no stream is attached" do
      {:ok, pid, _id} = start_session()

      assert :ok = Session.register_tool(pid, RuntimeTool)

      assert Session.get_state(pid).tool_list_dirty
    end

    @tag doc: """
         D4: the flag follows the change, not the call. Before this topic an
         unknown-name unregister notified anyway; under the dirty tool list
         that quirk costs more than one spurious notification — it leaves
         the flag set until the client lists, and buys one notification per
         stream attach until then. A failure means the handler is marking on
         the call rather than comparing the list tools/list would serve.
         """
    test "unregister_tool/2 with an unregistered name changes nothing" do
      {:ok, pid, _id} = start_session()
      stream_pid = spawn_fake_stream(pid)

      assert :ok = Session.unregister_tool(pid, "never_registered")

      refute_receive {:fake_stream_push, _}, 100
      refute Session.get_state(pid).tool_list_dirty

      Process.exit(stream_pid, :normal)
    end

    test "register_tool/2 with the module already registered changes nothing" do
      {:ok, pid, _id} = start_session()
      stream_pid = spawn_fake_stream(pid)

      Session.register_tool(pid, RuntimeTool)
      assert_receive {:fake_stream_push, _}, 1000
      Session.get_tools_for_list(pid)

      assert :ok = Session.register_tool(pid, RuntimeTool)

      refute_receive {:fake_stream_push, _}, 100
      refute Session.get_state(pid).tool_list_dirty

      Process.exit(stream_pid, :normal)
    end

    @tag doc: """
         D4a, the case that made the trigger the served list rather than the
         runtime tool set: registering a module that is ALREADY a
         compile-time tool moves it between the two lists — merge_tools/1
         drops the compile-time entry it now shadows — so the client is
         served exactly the same modules and owes nothing. A failure means
         the comparison drifted back to runtime_tools, which marks here and
         then owes one notification per stream attach until the client
         lists, for a list that never changed. Supported pattern, not a
         corner case: register_tool/2's @doc documents runtime tools taking
         precedence on name collision, and that is how Server.init/2
         overrides a default tool with a user-specific variant.

         "Changes nothing" is about the wire, not the bookkeeping — hence
         the last assertion. apply_tool_change/2 decides two things, whether
         to accept the new runtime_tools and whether to mark, and only the
         second is conditional; this is the only case in the suite where the
         two come apart, so a failure on that line means they got fused and
         a successful register_tool/2 left no trace of itself.
         """
    test "register_tool/2 with a module that is already a compile-time tool changes nothing" do
      {:ok, pid, _id} = Session.start_session(Testing.build_session_opts(tools: [RuntimeTool]))
      stream_pid = spawn_fake_stream(pid)

      assert :ok = Session.register_tool(pid, RuntimeTool)

      refute_receive {:fake_stream_push, _}, 100
      refute Session.get_state(pid).tool_list_dirty
      assert Session.get_state(pid).runtime_tools == [RuntimeTool]

      Process.exit(stream_pid, :normal)
    end

    @tag doc: """
         D4a's discriminating counterpart, and the reason the test above is
         not satisfied by a predicate that simply never marks once
         compile-time tools exist: a DIFFERENT module claiming a
         compile-time tool's name swaps which module the client is served
         under that name, so the served set really did change. The list
         length is identical throughout — a count-based check would miss
         this, which is why the comparison is over sets of modules.
         """
    test "register_tool/2 with a different module shadowing a compile-time name marks the flag" do
      {:ok, pid, _id} = Session.start_session(Testing.build_session_opts(tools: [RuntimeTool]))
      stream_pid = spawn_fake_stream(pid)

      assert :ok = Session.register_tool(pid, ShadowingRuntimeTool)

      assert_receive {:fake_stream_push, %{"method" => "notifications/tools/list_changed"}},
                     1000

      assert Session.get_state(pid).tool_list_dirty
      assert Session.get_tools(pid) == [ShadowingRuntimeTool]

      Process.exit(stream_pid, :normal)
    end

    @tag doc: """
         The mirror of the case above, and the last row of D4a's table:
         unregistering the module that was shadowing a compile-time tool
         lets that compile-time tool reappear in the served list, so the
         change is real even though nothing was added. The list holds one
         entry throughout, so a count-based check misses this exactly as it
         misses the register-side case — and this is the unregister
         handler's half of the shared comparison, the only place removal is
         shown to change the served set rather than shrink it.
         """
    test "unregister_tool/2 removing a shadow reveals the compile-time tool it shadowed" do
      {:ok, pid, _id} = Session.start_session(Testing.build_session_opts(tools: [RuntimeTool]))
      stream_pid = spawn_fake_stream(pid)

      Session.register_tool(pid, ShadowingRuntimeTool)
      assert_receive {:fake_stream_push, _}, 1000
      Session.get_tools_for_list(pid)

      assert :ok = Session.unregister_tool(pid, "runtime_tool")

      assert_receive {:fake_stream_push, %{"method" => "notifications/tools/list_changed"}},
                     1000

      assert Session.get_state(pid).tool_list_dirty
      assert Session.get_tools(pid) == [RuntimeTool]

      Process.exit(stream_pid, :normal)
    end

    @tag doc: """
         D2: the notification fires on the clean → dirty rising edge only, so
         a batch of registrations on a live stream sends one notification
         instead of N. Safe because the flag, not the notification, carries
         the obligation — the suppressed change is still recorded. A failure
         means the coalescing is gone and the wire shows one notification per
         call again.
         """
    test "a second change while the flag is already dirty sends nothing" do
      {:ok, pid, _id} = start_session()
      stream_pid = spawn_fake_stream(pid)

      Session.register_tool(pid, RuntimeTool)
      assert_receive {:fake_stream_push, _}, 1000

      Session.register_tool(pid, OtherRuntimeTool)

      refute_receive {:fake_stream_push, _}, 100
      assert Session.get_state(pid).tool_list_dirty

      Process.exit(stream_pid, :normal)
    end
  end

  describe "get_tools_for_list/1" do
    test "returns the same merged list as get_tools/1" do
      {:ok, pid, _id} = start_session()
      Session.register_tool(pid, RuntimeTool)

      assert Session.get_tools_for_list(pid) == Session.get_tools(pid)
    end

    @tag doc: """
         The clear is the whole reason this read exists, and it is atomic
         with the read because both are handle_calls sharing one handler:
         flag clean implies the client's last-served list is current. A
         failure means the clear drifted away from the read — either the
         list is served without clearing (the client is told nothing changed
         forever) or the clear happens somewhere the client never saw a
         list, which is the silent staleness bug the flag exists to prevent.
         """
    test "marks the dirty tool list clean" do
      {:ok, pid, _id} = start_session()
      Session.register_tool(pid, RuntimeTool)
      assert Session.get_state(pid).tool_list_dirty

      Session.get_tools_for_list(pid)

      refute Session.get_state(pid).tool_list_dirty
    end

    test "a change after the list marks the flag dirty again" do
      {:ok, pid, _id} = start_session()
      Session.register_tool(pid, RuntimeTool)
      Session.get_tools_for_list(pid)

      Session.unregister_tool(pid, "runtime_tool")

      assert Session.get_state(pid).tool_list_dirty
    end

    test "get_tools/1 does not mark the dirty tool list clean" do
      {:ok, pid, _id} = start_session()
      Session.register_tool(pid, RuntimeTool)

      Session.get_tools(pid)

      assert Session.get_state(pid).tool_list_dirty
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

    @tag doc: """
         One active stream per session: registering a new stream pid must
         stop the previous stream, or a reconnecting client leaves a
         zombie stream consuming keepalives until its next write fails.
         The stop is an asking :replaced message (Transport.Stream.replace/1),
         never Process.exit(old, :kill): the stream IS the GET request
         process serving a committed 200, so killing it kills the response
         mid-stream. The stand-in is spawn_link'd for exactly that reason —
         this test process stands in for the request process, so a
         regression to a kill surfaces here as the test process itself
         exiting :killed rather than as a failed assertion.
         """
    test "register_stream/2 with a new pid stops the previously registered stream" do
      {:ok, pid, _id} = start_session()
      old_stream = spawn_linked_stream(self())
      new_stream = spawn_linked_stream(self())
      ref = Process.monitor(old_stream)

      Session.register_stream(pid, old_stream)
      assert :ok = Session.register_stream(pid, new_stream)

      assert_receive {:stream_replaced, ^old_stream}, 1000
      assert_receive {:DOWN, ^ref, :process, ^old_stream, :normal}, 1000
      assert Session.get_state(pid).stream_pid == new_stream
    end

    test "register_stream/2 with the already-registered pid does not stop it" do
      {:ok, pid, _id} = start_session()
      stream_pid = spawn_linked_stream(self())

      Session.register_stream(pid, stream_pid)
      assert :ok = Session.register_stream(pid, stream_pid)

      refute_receive {:stream_replaced, ^stream_pid}, 50
      assert Process.alive?(stream_pid)
      assert Session.get_state(pid).stream_pid == stream_pid
    end

    @tag doc: """
         A dead pid can arrive here: GET1's register_stream call timed out
         (a session mailbox running behind) and GET1 died; GET2 registered
         and is streaming — and the session then dequeues GET1's stale
         register, because a timed-out GenServer.call leaves its request
         in the target's mailbox. Acting on that poison message would stop
         GET2's healthy stream and register a corpse; it must leave the
         registration untouched.
         """
    test "register_stream/2 with a dead pid does not replace the current stream" do
      {:ok, pid, _id} = start_session()
      stream_pid = spawn_linked_stream(self())
      Session.register_stream(pid, stream_pid)

      dead_pid = spawn(fn -> :ok end)
      ref = Process.monitor(dead_pid)
      # :normal when the monitor won the race, :noproc when the pid was
      # already gone — either way the pid is now provably dead.
      assert_receive {:DOWN, ^ref, :process, ^dead_pid, _reason}

      assert :ok = Session.register_stream(pid, dead_pid)

      refute_receive {:stream_replaced, ^stream_pid}, 50
      assert Session.get_state(pid).stream_pid == stream_pid
    end

    @tag doc: """
         The deferred notification, discharged. Server.init/2 registers tools
         before the client's GET exists, so the change marks the flag with
         nowhere to send; the attach is where the session finally has
         somewhere. A failure means the declared listChanged capability is a
         promise the wire breaks again on every session that registers tools
         at init.
         """
    test "register_stream/2 sends the owed notification, exactly once" do
      {:ok, pid, _id} = start_session()
      Session.register_tool(pid, RuntimeTool)

      stream_pid = spawn_fake_stream(pid)

      assert_receive {:fake_stream_push,
                      %{
                        "jsonrpc" => "2.0",
                        "method" => "notifications/tools/list_changed"
                      }},
                     1000

      refute_receive {:fake_stream_push, _}, 100

      Process.exit(stream_pid, :normal)
    end

    test "register_stream/2 sends nothing when the dirty tool list is clean" do
      {:ok, pid, _id} = start_session()

      stream_pid = spawn_fake_stream(pid)

      refute_receive {:fake_stream_push, _}, 100

      Process.exit(stream_pid, :normal)
    end

    @tag doc: """
         The attach does not clear the flag (D1): only a served tools/list
         proves the client saw the list. So a client that takes the
         notification and never lists gets one per attach — accepted residue,
         and the reason the notification is payload-free and idempotent. A
         failure in the other direction (nothing on the second attach) means
         the attach started clearing, which loses the obligation on every
         reconnect where the client never listed.

         It is also the suite's only pin on WHICH pid the attach addresses
         (rule 5): the send must reach the stream just registered, not the
         one being replaced. Both streams stay alive here — a replaced fake
         is only told :replaced, and this one does not act on it — and
         spawn_fake_stream/1 would have both forwarding indistinguishable
         pushes to this same mailbox, so a send that drifted above the state
         update and addressed the outgoing stream would still satisfy an
         untagged assertion. Tagging each push with the forwarding stream's
         own pid is what makes the assertion discriminate; the refute below
         it says the replaced stream got nothing at all.
         """
    test "a second attach without an intervening tools/list sends again" do
      {:ok, pid, _id} = start_session()
      Session.register_tool(pid, RuntimeTool)

      first_stream = spawn_tagged_stream(pid)
      assert_receive {:tagged_stream_push, ^first_stream, _}, 1000

      second_stream = spawn_tagged_stream(pid)

      assert_receive {:tagged_stream_push, ^second_stream,
                      %{"method" => "notifications/tools/list_changed"}},
                     1000

      refute_receive {:tagged_stream_push, ^first_stream, _}, 100

      Process.exit(first_stream, :normal)
      Process.exit(second_stream, :normal)
    end

    @tag doc: """
         Rule 7: re-registering the pid that is already registered takes the
         LIVE branch — stop_replaced_stream(same, same) is a no-op but the
         branch still runs — so it sends again. Real in production, not
         theoretical: Bandit's connection process serves sequential requests,
         so a second GET on a reused connection arrives with the pid the
         first one registered. Sending is honest, because the flag means the
         client has not listed; a guard against it would add a branch for no
         correctness gain.
         """
    test "re-registering the already-registered stream pid sends again" do
      {:ok, pid, _id} = start_session()
      Session.register_tool(pid, RuntimeTool)

      stream_pid = spawn_fake_stream(pid)
      assert_receive {:fake_stream_push, _}, 1000

      assert :ok = Session.register_stream(pid, stream_pid)

      assert_receive {:fake_stream_push, %{"method" => "notifications/tools/list_changed"}},
                     1000

      Process.exit(stream_pid, :normal)
    end

    @tag doc: """
         The dead-pid guard branch must not send: that pid runs no loop, so
         the push would queue in a mailbox nobody drains and the flag would
         be spent on nothing. Leaving it set is what lets the real stream's
         attach discharge it — which is what this test actually asserts,
         since a send into a dead process is otherwise unobservable.
         """
    test "register_stream/2 with a dead pid leaves the notification owed" do
      {:ok, pid, _id} = start_session()
      Session.register_tool(pid, RuntimeTool)

      dead_pid = spawn(fn -> :ok end)
      ref = Process.monitor(dead_pid)
      # :normal when the monitor won the race, :noproc when the pid was
      # already gone — either way the pid is now provably dead.
      assert_receive {:DOWN, ^ref, :process, ^dead_pid, _reason}

      assert :ok = Session.register_stream(pid, dead_pid)
      assert Session.get_state(pid).tool_list_dirty

      stream_pid = spawn_fake_stream(pid)

      assert_receive {:fake_stream_push, %{"method" => "notifications/tools/list_changed"}},
                     1000

      Process.exit(stream_pid, :normal)
    end

    @tag doc: """
         The disconnect path's cleanup, and the reason the nil-clearing
         branch's body survived its clause: a stream whose write failed
         has to say so, because its process — the adapter's connection
         process — can outlive the stream and never fire the monitor.
         Clearing must demonitor too: handle_info/2 has no catch-all, so
         a DOWN arriving later with a ref this state no longer knows
         would crash the session.
         """
    test "unregister_stream/2 clears the registration for the current stream pid" do
      {:ok, pid, _id} = start_session()
      stream_pid = spawn(fn -> Process.sleep(:infinity) end)

      :ok = Session.register_stream(pid, stream_pid)
      :ok = Session.unregister_stream(pid, stream_pid)

      assert Session.get_state(pid).stream_pid == nil
      assert Session.get_state(pid).stream_monitor_ref == nil
    end

    @tag doc: """
         The identity guard: a late close from a stream that has already
         been replaced must not clear the successor's registration. The
         cast is fire-and-forget, so nothing orders it against the
         replacement — the guard is the whole protection.
         """
    test "unregister_stream/2 ignores a pid that is no longer registered" do
      {:ok, pid, _id} = start_session()
      old_stream = spawn(fn -> Process.sleep(:infinity) end)
      new_stream = spawn(fn -> Process.sleep(:infinity) end)

      :ok = Session.register_stream(pid, old_stream)
      :ok = Session.register_stream(pid, new_stream)
      :ok = Session.unregister_stream(pid, old_stream)

      assert Session.get_state(pid).stream_pid == new_stream
    end

    @tag doc: """
         The nil-clearing form died with the deleted design; the guard
         keeps the removal a clean caller-side FunctionClauseError instead
         of a function_clause crash inside the session process, which
         would take the whole session — assigns, pending requests, runtime
         tools — down with it.
         """
    test "register_stream/2 rejects nil at the boundary" do
      {:ok, pid, _id} = start_session()

      assert_raise FunctionClauseError, fn -> Session.register_stream(pid, nil) end
      assert Process.alive?(pid)
    end

    @tag doc: """
         A disconnected answer reaches the pusher directly (the loop
         answers the forwarded reply reference), and the registration
         clears through the loop's unregister_stream cast — the session
         never routes push acks anymore, so in-band clearing is gone
         with the blocking push. A failure means one of the two halves of
         the disconnect contract broke.
         """
    test "a disconnected push answers the pusher and the loop's cast clears the registration" do
      {:ok, pid, _id} = start_session()
      test_pid = self()

      stream_pid =
        spawn(fn ->
          receive do
            {:push, reply_to, _json} ->
              send(test_pid, {:got_push, self()})
              answer_fake_push(reply_to, {:error, :disconnected})
          end

          Process.sleep(:infinity)
        end)

      :ok = Session.register_stream(pid, stream_pid)
      assert {:error, :disconnected} = Session.push(pid, %{"jsonrpc" => "2.0"})
      assert_received {:got_push, ^stream_pid}

      # The real loop casts unregister_stream from its disconnect funnel;
      # the fake does it here, after the answer, like the real ordering.
      :ok = Session.unregister_stream(pid, stream_pid)
      assert Session.get_state(pid).stream_pid == nil
      assert Session.get_state(pid).stream_monitor_ref == nil
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

    test "push/3 returns {:error, :no_stream} when no stream registered" do
      {:ok, pid, _id} = start_session()
      assert {:error, :no_stream} = Session.push(pid, %{"test" => true})
    end

    @tag doc: """
         push/3 hands the pre-encoded payload and the caller's reply
         reference to the stream (a stream-answered push); the fake stream
         answers the reference the way the real loop does. A failure here
         means the session is no longer forwarding to the stream pid, or
         the reply reference no longer reaches it.
         """
    test "push/3 sends the message to the stream process" do
      {:ok, pid, _id} = start_session()

      test_pid = self()

      stream_pid =
        spawn(fn ->
          receive do
            {:push, reply_to, json} ->
              answer_fake_push(reply_to, :ok)
              send(test_pid, {:pushed, JSON.decode!(json)})
          end

          Process.sleep(:infinity)
        end)

      Session.register_stream(pid, stream_pid)
      assert :ok = Session.push(pid, %{"jsonrpc" => "2.0", "method" => "test"})
      assert_receive {:pushed, %{"jsonrpc" => "2.0", "method" => "test"}}, 1000
    end

    @tag doc: """
         The encode boundary: a payload JSON cannot encode must be refused
         in the pusher's own process, before any session state changes —
         previously the raise happened inside the stream loop and killed a
         healthy stream. A failure means encoding drifted back past the
         public entry.
         """
    test "push/3 answers {:error, :unencodable} for a payload JSON cannot encode" do
      {:ok, pid, _id} = start_session()
      stream_pid = spawn_fake_stream(pid)

      assert {:error, :unencodable} = Session.push(pid, %{"data" => {:tuple, :val}})

      Process.exit(stream_pid, :normal)
    end

    @tag doc: """
         The I2 degradation, pinned: a stream that never acks (wedged, or
         crashed without draining) costs the pusher its own call timeout,
         answered as a tuple by the entry's exit catch — never an exit.
         The timeout is shortened through push/3's third argument, the
         only place it is ever overridden.
         """
    test "push/3 answers {:error, :timeout} when the stream never acks" do
      {:ok, pid, _id} = start_session()
      wedged = spawn(fn -> Process.sleep(:infinity) end)
      :ok = Session.register_stream(pid, wedged)

      assert {:error, :timeout} = Session.push(pid, %{"jsonrpc" => "2.0"}, 50)
    end

    test "push/3 answers {:error, :no_session} on a dead session" do
      {:ok, pid, session_id} = Session.start_session(Testing.build_session_opts())
      :ok = Session.terminate_session(session_id)
      refute Process.alive?(pid)

      assert {:error, :no_session} = Session.push(pid, %{"jsonrpc" => "2.0"})
    end
  end

  describe "await_client_response/4 and deliver_response/3" do
    @tag doc: """
         The core server-request round trip: await_client_response pushes a
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

  describe "await_client_response/4 ack state machine" do
    @tag doc: """
         D3's two clocks, the fast one: a stream that never acks answers
         {:error, :timeout} within the ack window (~50 ms here via the
         :ack_window test opt), not after the transport clock or the
         client clock. A failure on the elapsed assertion means the ack
         window stopped bounding the push leg.
         """
    test "answers {:error, :timeout} from the ack window when the stream never acks" do
      {:ok, pid, _id} =
        Session.start_session(
          Testing.build_session_opts(client_capabilities: %{"sampling" => %{}}, ack_window: 50)
        )

      Session.mark_ready(pid)
      swallowing = spawn(fn -> Process.sleep(:infinity) end)
      :ok = Session.register_stream(pid, swallowing)
      message = %{"jsonrpc" => "2.0", "id" => "srv-ack-1", "method" => "sampling/createMessage"}

      {elapsed_us, result} =
        :timer.tc(fn -> Session.await_client_response(pid, "srv-ack-1", message, 30_000) end)

      assert {:error, :timeout} = result
      assert elapsed_us < 1_000_000
      assert Session.get_state(pid).pending_server_requests == %{}
    end

    test "an error ack answers the caller immediately" do
      {:ok, pid, _id} = start_ready_session()
      test_pid = self()

      stream_pid =
        spawn(fn ->
          receive do
            {:push, reply_to, _json} ->
              answer_fake_push(reply_to, {:error, :disconnected})
              send(test_pid, :acked_error)
          end

          Process.sleep(:infinity)
        end)

      :ok = Session.register_stream(pid, stream_pid)
      message = %{"jsonrpc" => "2.0", "id" => "srv-ack-2", "method" => "sampling/createMessage"}

      assert {:error, :disconnected} =
               Session.await_client_response(pid, "srv-ack-2", message, 30_000)

      assert_received :acked_error
      assert Session.get_state(pid).pending_server_requests == %{}
    end

    @tag doc: """
         Early deliver_response while ack-pending proves delivery: the
         caller gets the result immediately, and the late ack must drop
         in the stale clause instead of crashing the strict handle_info
         (D5). The fake holds the ack until told, so the orderings are
         deterministic, not sleep-raced.
         """
    test "an early deliver_response answers the caller; the late ack is dropped" do
      {:ok, pid, _id} = start_ready_session()
      test_pid = self()

      holding_stream =
        spawn(fn ->
          receive do
            {:push, reply_to, _json} ->
              send(test_pid, {:held, reply_to})

              receive do
                :release -> answer_fake_push(reply_to, :ok)
              end
          end

          Process.sleep(:infinity)
        end)

      :ok = Session.register_stream(pid, holding_stream)
      request_id = "srv-early"
      message = %{"jsonrpc" => "2.0", "id" => request_id, "method" => "sampling/createMessage"}

      task = Task.async(fn -> Session.await_client_response(pid, request_id, message, 5_000) end)

      assert_receive {:held, _reply_to}, 1000
      result = %{"role" => "assistant", "content" => %{"type" => "text", "text" => "hi"}}
      :ok = Session.deliver_response(pid, request_id, {:ok, result})
      assert {:ok, ^result} = Task.await(task, 1000)

      # Release the held ack: it now targets a gone entry and must be
      # dropped by the stale clause, leaving the session alive.
      send(holding_stream, :release)
      Process.sleep(50)
      assert Session.ready?(pid)
      assert Session.get_state(pid).pending_server_requests == %{}
    end

    @tag doc: """
         The cast half of the same rule (code-review finding, 2026-08-03):
         a stream that reports its own close via the unregister_stream
         cast can never ack either — the loop has exited and its drain
         has already run, so an entry still ack-pending when the cast
         arrives was forwarded into a mailbox nobody reads. It must be
         answered {:error, :disconnected} now, not relabelled
         {:error, :timeout} a full ack window later.
         """
    test "an unregister_stream cast answers ack-pending entries {:error, :disconnected}" do
      {:ok, pid, _id} = start_ready_session()
      swallowing = spawn(fn -> Process.sleep(:infinity) end)
      :ok = Session.register_stream(pid, swallowing)

      request_id = "srv-unreg"
      message = %{"jsonrpc" => "2.0", "id" => request_id, "method" => "sampling/createMessage"}

      task = Task.async(fn -> Session.await_client_response(pid, request_id, message, 30_000) end)

      # Settle until the entry is armed (the push is swallowed, never acked).
      Process.sleep(50)
      assert map_size(Session.get_state(pid).pending_server_requests) == 1

      :ok = Session.unregister_stream(pid, swallowing)
      assert {:error, :disconnected} = Task.await(task, 1000)
      assert Session.get_state(pid).pending_server_requests == %{}
    end

    @tag doc: """
         Stream death answers the pending push leg: an ack-pending entry
         becomes {:error, :stream_down} on the session's stream :DOWN —
         the dead loop can never ack, and waiting out the ack window
         would just relabel the same failure {:error, :timeout} later.
         """
    test "a stream :DOWN answers ack-pending entries {:error, :stream_down}" do
      {:ok, pid, _id} = start_ready_session()
      test_pid = self()

      dying_stream =
        spawn(fn ->
          receive do
            {:push, _reply_to, _json} -> send(test_pid, :swallowed)
          end
        end)

      :ok = Session.register_stream(pid, dying_stream)
      request_id = "srv-down"
      message = %{"jsonrpc" => "2.0", "id" => request_id, "method" => "sampling/createMessage"}

      task = Task.async(fn -> Session.await_client_response(pid, request_id, message, 30_000) end)

      # The fake exits right after swallowing the push (its receive body
      # ends), so the session's monitor fires while the ack is pending.
      assert_receive :swallowed, 1000
      assert {:error, :stream_down} = Task.await(task, 1000)
      assert Session.get_state(pid).pending_server_requests == %{}
    end

    @tag doc: """
         The other half of the :DOWN split (D3): an entry whose client
         timer is already armed survives stream death — the push was
         written, the client can still POST its response through a new
         stream. Only the never-acked leg dies with the stream.
         """
    test "a stream :DOWN leaves an acked, awaiting-response entry alive" do
      {:ok, pid, _id} = start_ready_session()
      stream_pid = spawn_fake_stream(pid)

      request_id = "srv-survives"
      message = %{"jsonrpc" => "2.0", "id" => request_id, "method" => "sampling/createMessage"}

      task = Task.async(fn -> Session.await_client_response(pid, request_id, message, 5_000) end)

      # The fake acks :ok immediately; wait until the entry is armed.
      assert_receive {:fake_stream_push, _}, 1000
      Process.sleep(50)

      Process.exit(stream_pid, :kill)
      Process.sleep(50)
      assert map_size(Session.get_state(pid).pending_server_requests) == 1

      result = %{"role" => "assistant", "content" => %{"type" => "text", "text" => "late"}}
      :ok = Session.deliver_response(pid, request_id, {:ok, result})
      assert {:ok, ^result} = Task.await(task, 1000)
    end

    @tag doc: """
         A reused request_id must not crash the session. The second call
         supersedes the first entry; the superseded attempt's client timer
         carries the FIRST attempt's ack_ref, so it matches nothing and
         drops. Before the ack_ref pin it popped a differently-shaped
         :ack_pending tuple instead — CaseClauseError inside handle_info,
         which under restart: :temporary takes the session and every other
         in-flight request with it — which is why Task.await(second) is the
         load-bearing assertion here: a crashed session would answer it
         {:error, :no_session}. The superseded caller is not awaited at
         all: it falls back to its own outer safety net (client timeout +
         ack window + 1 s), and waiting that out would add ~6 s to the
         suite for no extra discrimination.
         """
    test "a reused request_id supersedes the first entry without crashing the session" do
      {:ok, pid, _id} = start_ready_session()
      _stream_pid = spawn_fake_stream(pid)

      request_id = "srv-dup"
      message = %{"jsonrpc" => "2.0", "id" => request_id, "method" => "sampling/createMessage"}

      first = Task.async(fn -> Session.await_client_response(pid, request_id, message, 100) end)
      assert_receive {:fake_stream_push, _}, 1000

      # The fake signals the test BEFORE it acks, so settle: the first
      # attempt must reach :awaiting_response (client timer armed) before
      # the second supersedes it — that armed timer is what this test is
      # about.
      Process.sleep(50)

      second =
        Task.async(fn -> Session.await_client_response(pid, request_id, message, 5_000) end)

      assert_receive {:fake_stream_push, _}, 1000

      # Outlive the first attempt's 100 ms client timer: it fires against
      # the superseded entry and must drop on the ack_ref pin.
      Process.sleep(200)
      assert Session.ready?(pid)

      result = %{"role" => "assistant", "content" => %{"type" => "text", "text" => "second"}}
      :ok = Session.deliver_response(pid, request_id, {:ok, result})
      assert {:ok, ^result} = Task.await(second, 1000)

      Task.shutdown(first, :brutal_kill)
    end

    @tag doc: """
         The ack window may only be shrunk. await_client_response/4 sizes
         its outer GenServer.call safety net from the compile-time default,
         in the caller's process where session state is unreachable — so a
         larger window would let the caller's own call expire first and
         answer {:error, :timeout} for a reason the vocabulary reserves for
         a wedged stream. A failure means init/1 stopped enforcing the
         ceiling and the two clocks are no longer orderable.
         """
    test "an :ack_window above the compile-time default is refused at init" do
      opts = Testing.build_session_opts(ack_window: :timer.seconds(30))

      assert {:error, {%ArgumentError{} = exception, _stacktrace}} = Session.start_session(opts)
      assert Exception.message(exception) =~ ":ack_window"
    end

    test "await_client_response answers {:error, :no_session} on a dead session" do
      {:ok, pid, session_id} = Session.start_session(Testing.build_session_opts())
      :ok = Session.terminate_session(session_id)
      refute Process.alive?(pid)

      message = %{"jsonrpc" => "2.0", "id" => "srv-dead", "method" => "sampling/createMessage"}
      assert {:error, :no_session} = Session.await_client_response(pid, "srv-dead", message, 100)
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

  # Stands in for a stream the way it really runs: linked to the process
  # the response belongs to (spawn_link here; in production the stream IS
  # the GET request process), so a replacement that kills instead of
  # asking takes this test process down with it. Forwards the :replaced
  # message instead of handling it, then returns — ending like a replaced
  # loop does.
  defp spawn_linked_stream(test_pid) do
    spawn_link(fn ->
      receive do
        :replaced -> send(test_pid, {:stream_replaced, self()})
      end
    end)
  end

  defp receive_loop(test_pid) do
    receive do
      {:push, reply_to, json} ->
        send(test_pid, {:fake_stream_push, JSON.decode!(json)})
        answer_fake_push(reply_to, :ok)
        receive_loop(test_pid)
    end
  end

  # The loop side of the push protocol, as Transport.Stream's answer_push/2
  # does it — fakes must speak the same three reply_to shapes.
  defp answer_fake_push({:caller, from}, result), do: GenServer.reply(from, result)

  defp answer_fake_push({:ack, session_pid, tag}, result),
    do: send(session_pid, {:push_ack, tag, result})

  defp answer_fake_push(:none, _result), do: :ok

  # A fake stream that names itself in what it forwards. Two of these can
  # be told apart in one test mailbox, which is what pins the pid the
  # attach send addresses; spawn_fake_stream/1's payload cannot. No
  # answer_fake_push/2 here: the notification pushes with :none, so there
  # is no reply to give.
  defp spawn_tagged_stream(session_pid) do
    test_pid = self()
    stream_pid = spawn(fn -> tagged_receive_loop(test_pid) end)
    Session.register_stream(session_pid, stream_pid)
    stream_pid
  end

  defp tagged_receive_loop(test_pid) do
    receive do
      {:push, _reply_to, json} ->
        send(test_pid, {:tagged_stream_push, self(), JSON.decode!(json)})
        tagged_receive_loop(test_pid)
    end
  end

  defp start_session do
    Session.start_session(Testing.build_session_opts(tools: start_session_tools()))
  end

  defp start_session_tools, do: []
end
