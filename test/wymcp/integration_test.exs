defmodule Wymcp.IntegrationTest do
  use ExUnit.Case

  @moduledoc """
  End-to-end test of the complete MCP lifecycle.

  Exercises: initialize → notifications/initialized → tools/list →
  tools/call → tools/call (verifying assigns persist) → DELETE session.
  Verifies session ID propagation, proper response structure, assigns
  persistence, and clean session termination.
  """

  import Plug.Test
  import Plug.Conn

  alias Wymcp.Session

  defmodule InitTrackingServer do
    @moduledoc false
    use Wymcp.Server

    @impl Wymcp.Server
    def init(client_info, assigns) do
      {:ok, Map.put(assigns, :initialized_by, client_info["name"])}
    end
  end

  defmodule IntegrationRejectingServer do
    @moduledoc false
    use Wymcp.Server

    @impl Wymcp.Server
    def init(_client_info, _assigns) do
      {:error, "access denied"}
    end
  end

  defmodule IntegrationRuntimeTool do
    @moduledoc false
    use Wymcp.Tool

    @impl true
    def name, do: "integration_runtime"

    @impl true
    def description, do: "A runtime tool for integration testing"

    @impl true
    def actions do
      %{
        greet: %{
          description: "Greet",
          properties: %{},
          required: [],
          defaults: %{}
        }
      }
    end

    @impl Wymcp.Tool
    def run_action(:greet, _data, _ctx) do
      {:ok, %{greeting: "hello from runtime"}}
    end
  end

  defmodule ToolRegistrationServer do
    @moduledoc false
    use Wymcp.Server

    @impl Wymcp.Server
    def init(_client_info, assigns) do
      Session.register_tool(assigns.session_pid, IntegrationRuntimeTool)
      {:ok, Map.put(assigns, :server_initialized, true)}
    end
  end

  defmodule CounterTool do
    @moduledoc false

    @behaviour Wymcp.Tool

    def name, do: "counter"
    def title, do: nil
    def description, do: "Counts calls per session"
    def annotations, do: nil
    def actions, do: %{}
    def run_action(_action, _data, _ctx), do: {:error, "not used"}
    def hints(_action, _hint_context), do: []
    def handle_error(reason), do: "Error: #{inspect(reason)}"
    def schema_mode, do: :full
    def action_context(_action, _ctx), do: nil
    def output_schema, do: nil

    def input_schema, do: %{"type" => "object", "properties" => %{}}

    def definition do
      %{
        "name" => name(),
        "description" => description(),
        "inputSchema" => input_schema()
      }
    end

    @spec run(Wymcp.Context.t(), map()) ::
            {:ok, Wymcp.Context.content()}
            | {:ok, Wymcp.Context.content(), map()}
            | {:error, String.t()}
    def run(ctx, _params) do
      count = Map.get(ctx.assigns, :count, 0) + 1
      {:ok, Wymcp.Context.text("#{count}"), %{count: count}}
    end
  end

  @router_opts Wymcp.Router.init(tools: [CounterTool])

  defp post_request(body, headers \\ []) do
    post_request(@router_opts, body, headers)
  end

  defp post_request(router_opts, body, headers) do
    conn =
      conn(:post, "/", JSON.encode!(body))
      |> put_req_header("content-type", "application/json")

    conn =
      Enum.reduce(headers, conn, fn {k, v}, c ->
        put_req_header(c, k, v)
      end)

    Wymcp.Router.call(conn, router_opts)
  end

  @tag capture_log: true
  test "complete MCP lifecycle with stateful tool" do
    # 1. Initialize
    init_conn =
      post_request(%{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "initialize",
        "params" => %{
          "protocolVersion" => "2025-11-25",
          "capabilities" => %{},
          "clientInfo" => %{"name" => "integration-test", "version" => "1.0"}
        }
      })

    assert init_conn.status == 200
    [session_id] = get_resp_header(init_conn, "mcp-session-id")
    headers = [{"mcp-session-id", session_id}, {"mcp-protocol-version", "2025-11-25"}]

    # 1b. tools/list before notifications/initialized is allowed (lifecycle-exempt)
    # because clients like mcp-remote send them concurrently.
    premature_conn =
      post_request(
        %{"jsonrpc" => "2.0", "id" => 99, "method" => "tools/list"},
        headers
      )

    assert premature_conn.status == 200

    # 2. Send notifications/initialized
    init_notify_conn =
      post_request(
        %{"jsonrpc" => "2.0", "method" => "notifications/initialized"},
        headers
      )

    assert init_notify_conn.status == 200

    # Verify session is ready
    {:ok, pid} = Wymcp.Session.lookup(session_id)
    assert Wymcp.Session.get_state(pid).status == :ready

    # 3. List tools
    list_conn =
      post_request(
        %{"jsonrpc" => "2.0", "id" => 2, "method" => "tools/list"},
        headers
      )

    list_resp = JSON.decode!(list_conn.resp_body)
    assert [%{"name" => "counter"}] = list_resp["result"]["tools"]

    # 4. First tool call — count starts at 0, returns 1
    call1 =
      post_request(
        %{
          "jsonrpc" => "2.0",
          "id" => 3,
          "method" => "tools/call",
          "params" => %{"name" => "counter", "arguments" => %{}}
        },
        headers
      )

    resp1 = JSON.decode!(call1.resp_body)
    assert resp1["result"]["content"] == [%{"type" => "text", "text" => "1"}]

    # 5. Second tool call — count persisted, returns 2
    call2 =
      post_request(
        %{
          "jsonrpc" => "2.0",
          "id" => 4,
          "method" => "tools/call",
          "params" => %{"name" => "counter", "arguments" => %{}}
        },
        headers
      )

    resp2 = JSON.decode!(call2.resp_body)
    assert resp2["result"]["content"] == [%{"type" => "text", "text" => "2"}]

    # 6. Terminate session
    del_conn =
      conn(:delete, "/")
      |> put_req_header("mcp-session-id", session_id)
      |> Wymcp.Router.call(@router_opts)

    assert del_conn.status == 200

    # 7. Give Registry time to clean up, then verify session is gone
    Process.sleep(10)

    gone_conn =
      post_request(
        %{"jsonrpc" => "2.0", "id" => 5, "method" => "tools/list"},
        headers
      )

    # Session was terminated — per MCP 2025-11-25 spec the server MUST
    # respond with HTTP 404 and the client MUST start a new session.
    assert gone_conn.status == 404
    gone_body = JSON.decode!(gone_conn.resp_body)
    assert gone_body["id"] == 5
    assert gone_body["error"]["code"] == -32001
    assert gone_body["error"]["message"] == "Session terminated"
  end

  describe "server init/2 callback" do
    @tag doc: """
         After notifications/initialized, the server module's init/2 callback
         must fire with the client_info from the initialize request and the
         current (empty) assigns. The returned assigns are stored on the
         session. A subsequent tool call should see the assigns in ctx.assigns.
         """
    test "server init/2 seeds session assigns" do
      router_opts = Wymcp.Router.init(tools: [], server: InitTrackingServer)

      # Step 1: Initialize
      init_conn =
        post_request(
          router_opts,
          %{
            "jsonrpc" => "2.0",
            "id" => 1,
            "method" => "initialize",
            "params" => %{
              "protocolVersion" => "2025-11-25",
              "capabilities" => %{},
              "clientInfo" => %{"name" => "test-client", "version" => "1.0"}
            }
          },
          []
        )

      assert init_conn.status == 200
      [session_id] = get_resp_header(init_conn, "mcp-session-id")
      headers = [{"mcp-session-id", session_id}, {"mcp-protocol-version", "2025-11-25"}]

      # Step 2: Send notifications/initialized
      notif_conn =
        post_request(
          router_opts,
          %{
            "jsonrpc" => "2.0",
            "method" => "notifications/initialized"
          },
          headers
        )

      assert notif_conn.status == 200

      # Step 3: Verify assigns were seeded by init/2
      state = Session.get_state(session_id)
      assert state.assigns[:initialized_by] == "test-client"

      # session_pid should be pre-seeded into assigns (Phoenix pattern)
      assert is_pid(state.assigns[:session_pid])
    end

    @tag doc: """
         When server init/2 returns {:error, reason}, the session must be
         terminated and the notifications/initialized response must carry
         a JSON-RPC error. The client should re-initialize from scratch.
         """
    @tag capture_log: true
    test "server init/2 rejection terminates session" do
      router_opts = Wymcp.Router.init(tools: [], server: IntegrationRejectingServer)

      # Step 1: Initialize
      init_conn =
        post_request(
          router_opts,
          %{
            "jsonrpc" => "2.0",
            "id" => 1,
            "method" => "initialize",
            "params" => %{
              "protocolVersion" => "2025-11-25",
              "capabilities" => %{},
              "clientInfo" => %{"name" => "rejected", "version" => "1.0"}
            }
          },
          []
        )

      assert init_conn.status == 200
      [session_id] = get_resp_header(init_conn, "mcp-session-id")
      headers = [{"mcp-session-id", session_id}, {"mcp-protocol-version", "2025-11-25"}]

      # Step 2: Send notifications/initialized — should fail
      notif_conn =
        post_request(
          router_opts,
          %{
            "jsonrpc" => "2.0",
            "id" => 2,
            "method" => "notifications/initialized"
          },
          headers
        )

      assert notif_conn.status == 200
      body = JSON.decode!(notif_conn.resp_body)
      assert body["error"]["code"] == -32603
      assert body["error"]["data"]["reason"] =~ "access denied"

      # Session should be terminated
      Process.sleep(10)
      assert {:error, :not_found} = Session.lookup(session_id)
    end
  end

  describe "SSE stream lifecycle" do
    @tag doc: """
         Full SSE lifecycle: initialize session, open SSE stream via GET,
         verify the stream registers with the session, terminate the session,
         verify the stream cleans up. This exercises the bidirectional
         channel that sampling/elicitation will depend on.

         Note: Plug.Test does not support reading chunked response bodies,
         so we verify behavior through session state inspection rather than
         parsing SSE events from the wire.
         """
    test "GET opens SSE stream, session termination closes it" do
      # 1. Initialize
      init_conn =
        post_request(%{
          "jsonrpc" => "2.0",
          "id" => 1,
          "method" => "initialize",
          "params" => %{
            "protocolVersion" => "2025-11-25",
            "capabilities" => %{},
            "clientInfo" => %{"name" => "sse-test", "version" => "1.0"}
          }
        })

      assert init_conn.status == 200
      [session_id] = get_resp_header(init_conn, "mcp-session-id")
      headers = [{"mcp-session-id", session_id}, {"mcp-protocol-version", "2025-11-25"}]

      # 2. Complete handshake
      notif_conn =
        post_request(
          %{"jsonrpc" => "2.0", "method" => "notifications/initialized"},
          headers
        )

      assert notif_conn.status == 200

      # 3. Open SSE stream in a separate process (it blocks)
      test_pid = self()
      {:ok, session_pid} = Session.lookup(session_id)

      stream_task =
        Task.async(fn ->
          result_conn =
            conn(:get, "/")
            |> put_req_header("mcp-session-id", session_id)
            |> Wymcp.Router.call(@router_opts)

          send(test_pid, {:stream_done, result_conn})
          result_conn
        end)

      # Give the stream time to start and register
      Process.sleep(100)

      # 4. Verify stream is registered with session
      state = Session.get_state(session_pid)
      assert is_pid(state.stream_pid)

      # 5. Terminate session — should close the stream
      Session.terminate_session(session_id)

      # 6. Stream task should complete
      assert_receive {:stream_done, stream_conn}, 2000
      assert stream_conn.status == 200
      assert stream_conn.state == :chunked

      # Clean up the task
      Task.await(stream_task, 1000)
    end
  end

  defmodule SamplingTool do
    @moduledoc false

    @behaviour Wymcp.Tool

    def name, do: "sampler"
    def title, do: nil
    def description, do: "Calls sampling mid-execution"
    def annotations, do: nil
    def actions, do: %{}
    def run_action(_action, _data, _ctx), do: {:error, "not used"}
    def hints(_action, _hint_context), do: []
    def handle_error(reason), do: "Error: #{inspect(reason)}"
    def schema_mode, do: :full
    def action_context(_action, _ctx), do: nil
    def output_schema, do: nil

    def input_schema, do: %{"type" => "object", "properties" => %{}}

    def definition do
      %{
        "name" => name(),
        "description" => description(),
        "inputSchema" => input_schema()
      }
    end

    @spec run(Wymcp.Context.t(), map()) ::
            {:ok, Wymcp.Context.content()}
            | {:ok, Wymcp.Context.content(), map()}
            | {:error, String.t()}
    def run(ctx, _params) do
      case Wymcp.Context.sample(ctx, "Summarize the data", %{"maxTokens" => 100}) do
        {:ok, result} ->
          {:ok, Wymcp.Context.text("LLM said: #{result["content"]["text"]}")}

        {:error, reason} ->
          {:error, "Sampling failed: #{inspect(reason)}"}
      end
    end
  end

  describe "sampling integration" do
    @sampling_router_opts Wymcp.Router.init(tools: [SamplingTool])

    @tag doc: """
         Full sampling lifecycle: initialize with sampling capability →
         open SSE stream → tools/call triggers Context.sample/3 → server
         pushes sampling/createMessage via SSE → client POSTs response →
         tool completes with the LLM's answer. This exercises the entire
         bidirectional channel.

         The SSE stream is opened in a Task because it blocks. The tool
         call is also in a Task because it blocks waiting for the sampling
         response. The test process reads the SSE push from the stream,
         then POSTs the response.

         Note: Plug.Test does not support reading chunked response bodies,
         so we intercept the sampling request by monitoring the session's
         pending_server_requests state rather than parsing SSE events.
         """
    test "tool calls Context.sample/3 and receives client response" do
      # 1. Initialize with sampling capability
      init_conn =
        post_request(
          @sampling_router_opts,
          %{
            "jsonrpc" => "2.0",
            "id" => 1,
            "method" => "initialize",
            "params" => %{
              "protocolVersion" => "2025-11-25",
              "capabilities" => %{"sampling" => %{}},
              "clientInfo" => %{"name" => "sampling-test", "version" => "1.0"}
            }
          },
          []
        )

      assert init_conn.status == 200
      resp = JSON.decode!(init_conn.resp_body)
      assert resp["result"]["capabilities"]["sampling"] == %{}
      [session_id] = get_resp_header(init_conn, "mcp-session-id")
      headers = [{"mcp-session-id", session_id}, {"mcp-protocol-version", "2025-11-25"}]

      # 2. Complete handshake
      notif_conn =
        post_request(
          @sampling_router_opts,
          %{"jsonrpc" => "2.0", "method" => "notifications/initialized"},
          headers
        )

      assert notif_conn.status == 200

      # 3. Open SSE stream in background (it blocks)
      {:ok, session_pid} = Session.lookup(session_id)
      test_pid = self()

      stream_task =
        Task.async(fn ->
          result_conn =
            conn(:get, "/")
            |> put_req_header("mcp-session-id", session_id)
            |> Wymcp.Router.call(@sampling_router_opts)

          send(test_pid, {:stream_done, result_conn})
          result_conn
        end)

      Process.sleep(100)

      # 4. Call the sampling tool in a Task (it will block on sample/3)
      tool_task =
        Task.async(fn ->
          post_request(
            @sampling_router_opts,
            %{
              "jsonrpc" => "2.0",
              "id" => 10,
              "method" => "tools/call",
              "params" => %{"name" => "sampler", "arguments" => %{}}
            },
            headers
          )
        end)

      # 5. Wait for the sampling request to appear in pending_server_requests
      sampling_request_id = wait_for_pending_request(session_pid, 2000)
      assert sampling_request_id != nil

      # 6. POST the sampling response (as the client would)
      sampling_response_conn =
        post_request(
          @sampling_router_opts,
          %{
            "jsonrpc" => "2.0",
            "id" => sampling_request_id,
            "result" => %{
              "role" => "assistant",
              "content" => %{"type" => "text", "text" => "The data shows growth"},
              "model" => "claude-3-sonnet",
              "stopReason" => "endTurn"
            }
          },
          headers
        )

      assert sampling_response_conn.status == 202

      # 7. Tool call should now complete
      tool_conn = Task.await(tool_task, 5000)
      assert tool_conn.status == 200
      tool_body = JSON.decode!(tool_conn.resp_body)
      content_text = hd(tool_body["result"]["content"])["text"]
      assert content_text =~ "LLM said: The data shows growth"

      # 8. Cleanup: terminate session to close the SSE stream
      Session.terminate_session(session_id)
      assert_receive {:stream_done, _}, 2000
      Task.await(stream_task, 1000)
    end
  end

  describe "server callbacks with runtime tools (end-to-end)" do
    @tag doc: """
         Full lifecycle: initialize with server module → init/2 registers
         a runtime tool via session_pid in assigns → client can list and
         call the tool. This exercises the complete Plan 2 feature set,
         including the Phoenix-style pattern of passing process references
         through assigns.
         """
    test "complete flow: server init registers tool, client calls it" do
      router_opts = Wymcp.Router.init(tools: [], server: ToolRegistrationServer)

      # 1. Initialize
      init_conn =
        post_request(
          router_opts,
          %{
            "jsonrpc" => "2.0",
            "id" => 1,
            "method" => "initialize",
            "params" => %{
              "protocolVersion" => "2025-11-25",
              "capabilities" => %{},
              "clientInfo" => %{"name" => "integration-client", "version" => "1.0"}
            }
          },
          []
        )

      assert init_conn.status == 200
      [session_id] = get_resp_header(init_conn, "mcp-session-id")
      headers = [{"mcp-session-id", session_id}, {"mcp-protocol-version", "2025-11-25"}]

      # 2. Send notifications/initialized (triggers Server.init/2 which
      #    registers IntegrationRuntimeTool via session_pid in assigns)
      notif_conn =
        post_request(
          router_opts,
          %{"jsonrpc" => "2.0", "method" => "notifications/initialized"},
          headers
        )

      assert notif_conn.status == 200

      # 3. Verify server init/2 seeded assigns and registered tool
      state = Session.get_state(session_id)
      assert state.assigns[:server_initialized] == true

      # 4. tools/list should show the runtime tool
      list_conn =
        post_request(
          router_opts,
          %{"jsonrpc" => "2.0", "id" => 2, "method" => "tools/list"},
          headers
        )

      assert list_conn.status == 200
      body = JSON.decode!(list_conn.resp_body)
      tool_names = Enum.map(body["result"]["tools"], & &1["name"])
      assert "integration_runtime" in tool_names

      # 5. tools/call should be able to call the runtime tool
      call_conn =
        post_request(
          router_opts,
          %{
            "jsonrpc" => "2.0",
            "id" => 3,
            "method" => "tools/call",
            "params" => %{
              "name" => "integration_runtime",
              "arguments" => %{"action" => "greet"}
            }
          },
          headers
        )

      assert call_conn.status == 200
      call_body = JSON.decode!(call_conn.resp_body)
      refute call_body["result"]["isError"]
    end
  end

  @spec wait_for_pending_request(pid(), pos_integer()) :: String.t() | nil
  defp wait_for_pending_request(session_pid, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    wait_loop(session_pid, deadline)
  end

  @spec wait_loop(pid(), integer()) :: String.t() | nil
  defp wait_loop(session_pid, deadline) do
    if System.monotonic_time(:millisecond) > deadline do
      nil
    else
      state = Session.get_state(session_pid)

      case Map.keys(state.pending_server_requests) do
        [request_id | _] ->
          request_id

        [] ->
          Process.sleep(20)
          wait_loop(session_pid, deadline)
      end
    end
  end
end
