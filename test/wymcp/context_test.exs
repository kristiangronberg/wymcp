defmodule Wymcp.ContextTest do
  use ExUnit.Case, async: true

  @moduledoc """
  Tests for the Wymcp.Context struct and result builders.

  Context is the tool's interface to the MCP server. It carries session
  information, per-session assigns, and provides pure functions for
  building MCP-compliant content arrays. Tools receive a Context and
  return result tuples — they never interact with HTTP directly.

  Result builders are pure functions: they take data and return content
  arrays. No side effects, no process communication.
  """

  alias Wymcp.{Context, Session}

  describe "text/1" do
    test "builds a text content array" do
      assert Context.text("hello") == [%{"type" => "text", "text" => "hello"}]
    end
  end

  describe "json/1" do
    test "encodes data as JSON text content" do
      result = Context.json(%{"key" => "value"})

      assert [%{"type" => "text", "text" => text}] = result
      assert JSON.decode!(text) == %{"key" => "value"}
    end
  end

  describe "image/2" do
    test "builds an image content array" do
      assert Context.image("base64data", "image/png") == [
               %{"type" => "image", "data" => "base64data", "mimeType" => "image/png"}
             ]
    end
  end

  describe "audio/2" do
    test "builds an audio content array" do
      assert Context.audio("base64data", "audio/wav") == [
               %{"type" => "audio", "data" => "base64data", "mimeType" => "audio/wav"}
             ]
    end
  end

  describe "progress_token" do
    test "progress_token is extracted from meta" do
      ctx = %Context{
        session_pid: nil,
        session_id: nil,
        request_id: 1,
        meta: %{"progressToken" => "abc123"},
        assigns: %{}
      }

      assert Context.progress_token(ctx) == "abc123"
    end

    test "progress_token is nil when not present" do
      ctx = %Context{
        session_pid: nil,
        session_id: nil,
        request_id: 1,
        meta: %{},
        assigns: %{}
      }

      assert Context.progress_token(ctx) == nil
    end

    test "progress_token is nil when meta is nil" do
      ctx = %Context{
        session_pid: nil,
        session_id: nil,
        request_id: 1,
        meta: nil,
        assigns: %{}
      }

      assert Context.progress_token(ctx) == nil
    end
  end

  describe "report_progress/4" do
    @tag doc: """
         report_progress/4 pushes a notifications/progress message via
         the session's SSE stream. The progress token must come from the
         request's _meta. Without a progress token, the call is a no-op.
         """
    test "pushes progress notification via SSE" do
      {ctx, stream_pid} = build_session_context(%{})

      ctx = %{ctx | meta: %{"progressToken" => "tok-1"}}

      assert :ok = Context.report_progress(ctx, 50, 100, "Halfway there")

      assert_receive {:fake_stream_push, message}, 1000
      assert message["method"] == "notifications/progress"
      assert message["params"]["progressToken"] == "tok-1"
      assert message["params"]["progress"] == 50
      assert message["params"]["total"] == 100
      assert message["params"]["message"] == "Halfway there"

      Process.exit(stream_pid, :normal)
    end

    test "omits total and message when nil" do
      {ctx, stream_pid} = build_session_context(%{})

      ctx = %{ctx | meta: %{"progressToken" => "tok-2"}}

      assert :ok = Context.report_progress(ctx, 10)

      assert_receive {:fake_stream_push, message}, 1000
      assert message["params"]["progress"] == 10
      refute Map.has_key?(message["params"], "total")
      refute Map.has_key?(message["params"], "message")

      Process.exit(stream_pid, :normal)
    end

    test "returns :ok without pushing when no progress token" do
      {ctx, stream_pid} = build_session_context(%{})

      ctx = %{ctx | meta: %{}}

      assert :ok = Context.report_progress(ctx, 10, 100, "test")

      refute_receive {:fake_stream_push, _}, 100

      Process.exit(stream_pid, :normal)
    end

    test "returns :ok when session_pid is nil" do
      ctx = %Context{
        session_pid: nil,
        session_id: nil,
        request_id: 1,
        meta: %{"progressToken" => "t"},
        assigns: %{}
      }

      assert :ok = Context.report_progress(ctx, 1)
    end
  end

  describe "log/3" do
    @tag doc: """
         Context.log/3 pushes a notifications/message to the client.
         The session's log_level acts as a filter — messages below the
         threshold are silently dropped. This prevents flooding the
         client with debug noise when they only want errors.
         """
    test "pushes log notification via SSE" do
      {ctx, stream_pid} = build_session_context(%{})

      assert :ok = Context.log(ctx, "info", "Processing started")

      assert_receive {:fake_stream_push, message}, 1000
      assert message["method"] == "notifications/message"
      assert message["params"]["level"] == "info"
      assert message["params"]["data"] == "Processing started"

      Process.exit(stream_pid, :normal)
    end

    test "includes logger name when provided" do
      {ctx, stream_pid} = build_session_context(%{})

      assert :ok = Context.log(ctx, "warning", %{"msg" => "slow query"}, logger: "database")

      assert_receive {:fake_stream_push, message}, 1000
      assert message["params"]["logger"] == "database"
      assert message["params"]["data"]["msg"] == "slow query"

      Process.exit(stream_pid, :normal)
    end

    test "filters messages below session log level" do
      {ctx, stream_pid} = build_session_context(%{})
      Wymcp.Session.set_log_level(ctx.session_pid, "warning")

      assert :ok = Context.log(ctx, "info", "should be filtered")

      refute_receive {:fake_stream_push, _}, 100

      Process.exit(stream_pid, :normal)
    end

    test "sends messages at or above session log level" do
      {ctx, stream_pid} = build_session_context(%{})
      Wymcp.Session.set_log_level(ctx.session_pid, "warning")

      assert :ok = Context.log(ctx, "error", "should pass filter")

      assert_receive {:fake_stream_push, message}, 1000
      assert message["params"]["level"] == "error"

      Process.exit(stream_pid, :normal)
    end

    test "sends all levels when no log level is set" do
      {ctx, stream_pid} = build_session_context(%{})

      assert :ok = Context.log(ctx, "debug", "should pass")

      assert_receive {:fake_stream_push, _}, 1000

      Process.exit(stream_pid, :normal)
    end

    test "returns :ok when session_pid is nil" do
      ctx = %Context{session_pid: nil, session_id: nil, request_id: 1, assigns: %{}}
      assert :ok = Context.log(ctx, "info", "test")
    end
  end

  describe "sample/3" do
    @tag doc: """
         Context.sample/3 pushes a sampling/createMessage request via the
         session's SSE stream and blocks until the client responds. This
         test uses a real session + fake stream to verify the full cycle.
         A failure means tools cannot request LLM completions mid-execution.
         """
    test "pushes sampling request and returns client response" do
      {ctx, stream_pid} = build_session_context(%{"sampling" => %{}})

      # sample/3 blocks, so run it in a task
      sample_task =
        Task.async(fn ->
          Context.sample(ctx, "Summarize this", %{"maxTokens" => 500})
        end)

      # The test process receives the push from the fake stream
      assert_receive {:fake_stream_push, pushed_message}, 1000
      assert pushed_message["method"] == "sampling/createMessage"

      assert pushed_message["params"]["messages"] == [
               %{
                 "role" => "user",
                 "content" => %{"type" => "text", "text" => "Summarize this"}
               }
             ]

      assert pushed_message["params"]["maxTokens"] == 500

      request_id = pushed_message["id"]

      result = %{
        "role" => "assistant",
        "content" => %{"type" => "text", "text" => "Summary here"},
        "model" => "claude-3"
      }

      Session.deliver_response(ctx.session_pid, request_id, {:ok, result})

      assert {:ok, ^result} = Task.await(sample_task, 2000)
      Process.exit(stream_pid, :normal)
    end

    @tag doc: """
         When the client doesn't support sampling (no "sampling" in
         client_capabilities), sample/3 must return {:error, :not_supported}
         immediately without pushing anything to the SSE stream.
         """
    test "returns {:error, :not_supported} when client lacks sampling capability" do
      {ctx, stream_pid} = build_session_context(%{})

      assert {:error, :not_supported} = Context.sample(ctx, "test", %{})

      Process.exit(stream_pid, :normal)
    end

    test "returns {:error, :no_session} when session_pid is nil" do
      ctx = %Context{session_pid: nil, session_id: nil, request_id: 1, assigns: %{}}
      assert {:error, :no_session} = Context.sample(ctx, "test", %{})
    end
  end

  describe "elicit/3" do
    @tag doc: """
         Context.elicit/3 pushes an elicitation/create request (form mode)
         via SSE and blocks until the user responds. The schema defines
         what form fields the client should render.
         """
    test "pushes elicitation request and returns client response" do
      {ctx, stream_pid} = build_session_context(%{"elicitation" => %{}})

      schema = %{
        "type" => "object",
        "properties" => %{
          "branch" => %{"type" => "string"}
        },
        "required" => ["branch"]
      }

      # elicit/3 blocks, so run it in a task
      elicit_task =
        Task.async(fn ->
          Context.elicit(ctx, "Which branch?", schema)
        end)

      # The test process receives the push from the fake stream
      assert_receive {:fake_stream_push, pushed_message}, 1000
      assert pushed_message["method"] == "elicitation/create"
      assert pushed_message["params"]["message"] == "Which branch?"
      assert pushed_message["params"]["requestedSchema"] == schema

      request_id = pushed_message["id"]
      result = %{"action" => "accept", "content" => %{"branch" => "main"}}
      Session.deliver_response(ctx.session_pid, request_id, {:ok, result})

      assert {:ok, ^result} = Task.await(elicit_task, 2000)
      Process.exit(stream_pid, :normal)
    end

    test "returns {:error, :not_supported} when client lacks elicitation capability" do
      {ctx, stream_pid} = build_session_context(%{})

      assert {:error, :not_supported} = Context.elicit(ctx, "test", %{})

      Process.exit(stream_pid, :normal)
    end

    test "returns {:error, :no_session} when session_pid is nil" do
      ctx = %Context{session_pid: nil, session_id: nil, request_id: 1, assigns: %{}}
      assert {:error, :no_session} = Context.elicit(ctx, "test", %{})
    end
  end

  describe "struct" do
    test "holds session reference, request metadata, and assigns" do
      ctx = %Context{
        session_pid: self(),
        session_id: "abc",
        request_id: 1,
        assigns: %{user: "alice"}
      }

      assert ctx.session_pid == self()
      assert ctx.session_id == "abc"
      assert ctx.request_id == 1
      assert ctx.assigns.user == "alice"
    end
  end

  describe "elicit/4 negotiated-version gate" do
    @tag doc: """
         elicitation/create was introduced in 2025-06-18. A session
         pinned to 2025-03-26 must reject elicit calls with
         :not_supported, even if the client wrongly declared the
         capability — the method itself does not exist in that revision.
         """
    test "returns :not_supported when session is pinned to 2025-03-26" do
      {:ok, _pid, session_id} =
        Wymcp.Session.start_session(%{
          client_capabilities: %{"elicitation" => %{}},
          client_info: %{},
          protocol_version: "2025-03-26",
          tools: [],
          auth: nil,
          server: nil
        })

      {:ok, pid} = Wymcp.Session.lookup(session_id)

      ctx = %Wymcp.Context{session_pid: pid, request_id: 1}

      assert {:error, :not_supported} =
               Wymcp.Context.elicit(ctx, "Pick one", %{"type" => "object"})
    end
  end

  @spec build_session_context(map()) :: {Context.t(), pid()}
  defp build_session_context(client_capabilities) do
    {:ok, session_pid, session_id} =
      Session.start_session(%{
        client_capabilities: client_capabilities,
        client_info: %{"name" => "test", "version" => "1.0"},
        protocol_version: "2025-11-25",
        tools: [],
        auth: nil
      })

    Session.mark_ready(session_pid)

    # Spawn a fake stream that captures pushed messages
    test_pid = self()

    stream_pid =
      spawn(fn ->
        fake_stream_loop(test_pid)
      end)

    Session.register_stream(session_pid, stream_pid)

    ctx = %Context{
      session_pid: session_pid,
      session_id: session_id,
      request_id: 1,
      assigns: %{}
    }

    {ctx, stream_pid}
  end

  @spec fake_stream_loop(pid()) :: no_return()
  defp fake_stream_loop(test_pid) do
    receive do
      {:"$gen_call", from, {:push, message}} ->
        send(test_pid, {:fake_stream_push, message})
        GenServer.reply(from, :ok)
        fake_stream_loop(test_pid)
    end
  end
end
