defmodule Wymcp.Methods.ToolsCallTest do
  use ExUnit.Case, async: true

  import Plug.Test
  import Plug.Conn

  alias Wymcp.Methods.ToolsCall
  alias Wymcp.Session
  alias Wymcp.Testing

  defmodule EchoTool do
    use Wymcp.Tool

    def name, do: "echo"
    def description, do: "Echoes input"

    def actions do
      %{
        echo: %{
          description: "Echo text back",
          properties: %{"text" => %{"type" => "string"}},
          required: ["text"],
          defaults: %{}
        }
      }
    end

    def run_action(:echo, %{"text" => text}, _ctx), do: {:ok, %{echoed: text}}
  end

  defmodule AssignsTool do
    @moduledoc false
    use Wymcp.Tool

    def name, do: "assigns_reader"
    def description, do: "Reads from ctx.assigns"

    def actions do
      %{
        read: %{
          description: "Returns assigns",
          properties: %{},
          required: [],
          defaults: %{}
        }
      }
    end

    def run_action(:read, _data, ctx) do
      {:ok, %{scope: ctx.assigns[:current_scope], internal: ctx.assigns[:wymcp_internal_flag]}}
    end
  end

  defmodule CrashingTool do
    use Wymcp.Tool

    def name, do: "crasher"
    def description, do: "Always raises"

    def actions do
      %{
        crash: %{
          description: "Raises an error",
          properties: %{},
          required: [],
          defaults: %{}
        }
      }
    end

    def run_action(:crash, _data, _ctx), do: raise("boom")
  end

  defmodule ErroringTool do
    @moduledoc false
    use Wymcp.Tool

    def name, do: "erroring"
    def description, do: "Always returns a tool-level error"

    def actions do
      %{
        fail: %{
          description: "Returns an error tuple",
          properties: %{},
          required: [],
          defaults: %{}
        }
      }
    end

    def run_action(:fail, _data, _ctx), do: {:error, "nope"}
  end

  defmodule GateRejectingTool do
    @moduledoc false
    @behaviour Wymcp.Tool

    @impl true
    def name, do: "gate_rejecting"

    @impl true
    def description, do: "Hand-rolled run/2 that classifies its own gate rejection"

    @impl true
    def actions, do: %{}

    @impl true
    def run_action(_action, _data, _ctx), do: {:error, "unreachable"}

    @impl true
    def output_schema, do: nil

    def input_schema, do: %{"type" => "object"}

    # Hand-written run/2 exercising the documented contract: a tool may
    # classify its own gate rejections with the three-element error form.
    def run(_ctx, _arguments), do: {:error, "rejected by the tool's own gate", :dispatch}
  end

  defmodule ToolClassifyingItsOwnError do
    @moduledoc false
    @behaviour Wymcp.Tool

    @impl true
    def name, do: "self_classifying"

    @impl true
    def description, do: "Hand-rolled run/2 that classifies its own error :tool"

    @impl true
    def actions, do: %{}

    @impl true
    def run_action(_action, _data, _ctx), do: {:error, "unreachable"}

    @impl true
    def output_schema, do: nil

    def input_schema, do: %{"type" => "object"}

    # The redundant-but-documented form: the three-element error tuple with
    # the classification the two-element form would have implied.
    def run(_ctx, _arguments), do: {:error, "tool answered with its own :tool kind", :tool}
  end

  defmodule OffContractKindTool do
    @moduledoc false
    @behaviour Wymcp.Tool

    @impl true
    def name, do: "off_contract_kind"

    @impl true
    def description, do: "Hand-rolled run/2 returning an off-contract third element"

    @impl true
    def actions, do: %{}

    @impl true
    def run_action(_action, _data, _ctx), do: {:error, "unreachable"}

    @impl true
    def output_schema, do: nil

    def input_schema, do: %{"type" => "object"}

    def run(_ctx, _arguments), do: {:error, "bogus classification", :bogus}
  end

  defp build_conn(method, params, tools \\ []) do
    body = %{"jsonrpc" => "2.0", "id" => 1, "method" => method, "params" => params}

    {:ok, pid, session_id} = Session.start_session(Testing.build_session_opts(tools: tools))

    Session.mark_ready(pid)

    conn(:post, "/")
    |> put_req_header("content-type", "application/json")
    |> Map.put(:body_params, body)
    |> assign(:wymcp_session_pid, pid)
    |> assign(:wymcp_session_id, session_id)
  end

  test "calls the matching tool and returns its response" do
    conn =
      build_conn(
        "tools/call",
        %{
          "name" => "echo",
          "arguments" => %{"action" => "echo", "data" => %{"text" => "hello"}}
        },
        [EchoTool]
      )

    result = ToolsCall.run(conn, [EchoTool])
    body = JSON.decode!(result.resp_body)

    assert body["result"]["isError"] == false
    content = body["result"]["content"] |> hd() |> Map.get("text") |> JSON.decode!()
    assert content["echoed"] == "hello"
  end

  test "returns method_not_found for unknown tool" do
    conn = build_conn("tools/call", %{"name" => "nope", "arguments" => %{}}, [EchoTool])
    result = ToolsCall.run(conn, [EchoTool])
    body = JSON.decode!(result.resp_body)

    assert body["error"]["code"] == -32601
  end

  test "returns invalid_params for schema-violating arguments" do
    conn =
      build_conn(
        "tools/call",
        %{
          "name" => "echo",
          "arguments" => %{"not_action" => "bad"}
        },
        [EchoTool]
      )

    result = ToolsCall.run(conn, [EchoTool])
    body = JSON.decode!(result.resp_body)

    assert body["error"]["code"] == -32602
  end

  @tag capture_log: true
  @tag doc: """
       Per MCP 2025-11-25 schema (priv/schema.json:200-201), errors that
       originate from the tool — including raises inside `run_action/3` —
       must be reported as a successful JSON-RPC response with `isError:
       true` in the result. Reporting them as protocol-level -32603 hides
       the error from the LLM, which the spec calls out by name as the
       reason for the rule. Failure here means a regression to the old
       opaque behaviour; check the rescue clause in `tools_call.ex`.
       """
  test "tool raises produce isError content, not a protocol error" do
    conn =
      build_conn(
        "tools/call",
        %{
          "name" => "crasher",
          "arguments" => %{"action" => "crash"}
        },
        [CrashingTool]
      )

    result = ToolsCall.run(conn, [CrashingTool])
    body = JSON.decode!(result.resp_body)

    refute Map.has_key?(body, "error")
    assert body["result"]["isError"] == true

    diagnostic =
      body["result"]["content"]
      |> hd()
      |> Map.get("text")
      |> JSON.decode!()

    assert diagnostic["errorType"] == "tool_raised"
    assert diagnostic["tool"] == "crasher"
    assert diagnostic["exception"] == "RuntimeError"
    assert diagnostic["message"] == "boom"
  end

  test "returns invalid_params when name is missing" do
    conn =
      build_conn("tools/call", %{"arguments" => %{}}, [EchoTool])

    result = ToolsCall.run(conn, [EchoTool])
    body = JSON.decode!(result.resp_body)

    assert body["error"]["code"] == -32602
  end

  @tag doc: """
       The MCP schema requires only "name" in CallToolRequestParams, so an
       omitted "arguments" must not be rejected at the container level —
       it reads as the empty object. For a generated (action-dispatched)
       tool, %{} still fails the tool's own inputSchema, but the -32602
       now names the missing "action" instead of the container-level text.
       """
  test "accepts a tools/call without arguments and validates %{} against the tool schema" do
    conn = build_conn("tools/call", %{"name" => "echo"}, [EchoTool])

    result = ToolsCall.run(conn, [EchoTool])
    body = JSON.decode!(result.resp_body)

    assert body["error"]["code"] == -32602
    assert body["error"]["data"]["error"] =~ "property 'action' is required"
  end

  test "treats JSON-null arguments as absent" do
    conn = build_conn("tools/call", %{"name" => "echo", "arguments" => nil}, [EchoTool])

    result = ToolsCall.run(conn, [EchoTool])
    body = JSON.decode!(result.resp_body)

    assert body["error"]["code"] == -32602
    assert body["error"]["data"]["error"] =~ "property 'action' is required"
  end

  test "returns invalid_params when arguments is not an object" do
    conn = build_conn("tools/call", %{"name" => "echo", "arguments" => 5}, [EchoTool])

    result = ToolsCall.run(conn, [EchoTool])
    body = JSON.decode!(result.resp_body)

    assert body["error"]["code"] == -32602
    assert body["error"]["data"]["reason"] =~ "expected an object"
  end

  @tag doc: """
       The action enum stays published in tools/list for upfront guidance,
       but membership is checked in dispatch, not JSV — a wrong action gets
       a structured isError answer naming the valid actions instead of a
       -32602 with an inspected JSV term. A -32602 here means the enum
       leaked back into the validation schema.
       """
  test "wrong action name returns structured isError content, not a protocol error" do
    conn =
      build_conn(
        "tools/call",
        %{"name" => "echo", "arguments" => %{"action" => "nope"}},
        [EchoTool]
      )

    result = ToolsCall.run(conn, [EchoTool])
    body = JSON.decode!(result.resp_body)

    refute Map.has_key?(body, "error")
    assert body["result"]["isError"] == true

    payload = body["result"]["content"] |> hd() |> Map.get("text") |> JSON.decode!()
    assert payload["error"] == "unknown_action"
    assert payload["valid_actions"] == ["echo"]
    assert payload["help"] == ~s|help {tool: "echo"}|
  end

  test "dispatch validation errors carry isError: true" do
    conn =
      build_conn(
        "tools/call",
        %{"name" => "echo", "arguments" => %{"action" => "echo", "data" => %{}}},
        [EchoTool]
      )

    result = ToolsCall.run(conn, [EchoTool])
    body = JSON.decode!(result.resp_body)

    assert body["result"]["isError"] == true
    payload = body["result"]["content"] |> hd() |> Map.get("text") |> JSON.decode!()
    assert payload["error"] == "missing_required_fields"
    assert payload["missing"] == ["text"]
  end

  test "a misspelled help parameter is rejected by schema validation" do
    conn =
      build_conn(
        "tools/call",
        %{"name" => "help", "arguments" => %{"tol" => "echo"}},
        [EchoTool, Wymcp.Help]
      )

    result = ToolsCall.run(conn, [EchoTool, Wymcp.Help])
    body = JSON.decode!(result.resp_body)

    assert body["error"]["code"] == -32602
  end

  test "returns invalid_params when params is empty" do
    conn =
      build_conn("tools/call", %{}, [EchoTool])

    result = ToolsCall.run(conn, [EchoTool])
    body = JSON.decode!(result.resp_body)

    assert body["error"]["code"] == -32602
  end

  describe "conn.assigns bridge" do
    @tag doc: """
         Per-request conn.assigns set by upstream plugs (like auth) must be
         visible in ctx.assigns so tools can read them without process dictionary
         hacks. Internal wymcp keys must be filtered out to avoid leaking
         framework plumbing.
         """
    test "conn.assigns are visible in ctx.assigns" do
      conn =
        build_conn(
          "tools/call",
          %{
            "name" => "assigns_reader",
            "arguments" => %{"action" => "read"}
          },
          [AssignsTool]
        )

      conn = Plug.Conn.assign(conn, :current_scope, %{user: "alice"})
      conn = ToolsCall.run(conn, [AssignsTool])

      body = JSON.decode!(conn.resp_body)
      content = hd(body["result"]["content"])["text"] |> JSON.decode!()
      assert content["scope"] == %{"user" => "alice"}
    end

    test "wymcp internal assigns are filtered out" do
      conn =
        build_conn(
          "tools/call",
          %{
            "name" => "assigns_reader",
            "arguments" => %{"action" => "read"}
          },
          [AssignsTool]
        )

      conn = Plug.Conn.assign(conn, :current_scope, %{user: "alice"})
      conn = Plug.Conn.assign(conn, :wymcp_internal_flag, true)
      conn = ToolsCall.run(conn, [AssignsTool])

      body = JSON.decode!(conn.resp_body)
      content = hd(body["result"]["content"])["text"] |> JSON.decode!()
      assert content["internal"] == nil
    end

    @tag doc: """
         Session assigns take precedence over conn.assigns. This ensures that
         accumulated tool state (counters, cached lookups) is not overwritten
         by plug defaults. conn.assigns provide the base layer.
         """
    test "session assigns take precedence over conn.assigns" do
      {:ok, pid, _id} =
        Wymcp.Session.start_session(Testing.build_session_opts(tools: [AssignsTool]))

      Wymcp.Session.mark_ready(pid)
      Wymcp.Session.put_assigns(pid, %{current_scope: %{user: "from_session"}})
      session_id = Wymcp.Session.get_state(pid).session_id

      conn =
        build_conn("tools/call", %{
          "name" => "assigns_reader",
          "arguments" => %{"action" => "read"}
        })

      conn = Plug.Conn.assign(conn, :current_scope, %{user: "from_conn"})
      conn = Plug.Conn.assign(conn, :wymcp_session_pid, pid)
      conn = Plug.Conn.assign(conn, :wymcp_session_id, session_id)
      conn = ToolsCall.run(conn, [AssignsTool])

      body = JSON.decode!(conn.resp_body)
      content = hd(body["result"]["content"])["text"] |> JSON.decode!()
      # Session value wins over conn value
      assert content["scope"] == %{"user" => "from_session"}
    end
  end

  describe "tool telemetry" do
    test "stop event carries action, session_id, and is_error: false on success" do
      ref = make_ref()
      handler_id = "tool-stop-#{inspect(ref)}"

      :telemetry.attach(
        handler_id,
        [:wymcp, :tool, :stop],
        fn _event, _measurements, metadata, _config ->
          send(self(), {:telemetry, ref, metadata})
        end,
        nil
      )

      try do
        conn =
          build_conn(
            "tools/call",
            %{
              "name" => "echo",
              "arguments" => %{"action" => "echo", "data" => %{"text" => "hi"}}
            },
            [EchoTool]
          )

        session_id = conn.assigns[:wymcp_session_id]
        ToolsCall.run(conn, [EchoTool])

        assert_received {:telemetry, ^ref, metadata}
        assert metadata.tool_name == "echo"
        assert metadata.action == "echo"
        assert metadata.session_id == session_id
        assert metadata.is_error == false
        assert metadata.error_kind == nil
      after
        :telemetry.detach(handler_id)
      end
    end

    test "stop event carries is_error: true when the tool returns an error result" do
      ref = make_ref()
      handler_id = "tool-stop-error-#{inspect(ref)}"

      :telemetry.attach(
        handler_id,
        [:wymcp, :tool, :stop],
        fn _event, _measurements, metadata, _config ->
          send(self(), {:telemetry, ref, metadata})
        end,
        nil
      )

      try do
        conn =
          build_conn(
            "tools/call",
            %{"name" => "erroring", "arguments" => %{"action" => "fail"}},
            [ErroringTool]
          )

        ToolsCall.run(conn, [ErroringTool])

        assert_received {:telemetry, ^ref, metadata}
        assert metadata.action == "fail"
        assert metadata.is_error == true
        assert metadata.error_kind == :tool
      after
        :telemetry.detach(handler_id)
      end
    end

    test "stop event carries the error_kind a hand-rolled run/2 classifies itself" do
      ref = make_ref()
      handler_id = "tool-stop-kind-#{inspect(ref)}"

      :telemetry.attach(
        handler_id,
        [:wymcp, :tool, :stop],
        fn _event, _measurements, metadata, _config ->
          send(self(), {:telemetry, ref, metadata})
        end,
        nil
      )

      try do
        conn =
          build_conn(
            "tools/call",
            %{"name" => "gate_rejecting", "arguments" => %{}},
            [GateRejectingTool]
          )

        result = ToolsCall.run(conn, [GateRejectingTool])
        body = JSON.decode!(result.resp_body)

        assert body["result"]["isError"] == true

        assert_received {:telemetry, ^ref, metadata}
        assert metadata.is_error == true
        assert metadata.error_kind == :dispatch
      after
        :telemetry.detach(handler_id)
      end
    end

    test "stop event carries :tool when a hand-rolled run/2 classifies its own error" do
      ref = make_ref()
      handler_id = "tool-stop-self-kind-#{inspect(ref)}"

      :telemetry.attach(
        handler_id,
        [:wymcp, :tool, :stop],
        fn _event, _measurements, metadata, _config ->
          send(self(), {:telemetry, ref, metadata})
        end,
        nil
      )

      try do
        conn =
          build_conn(
            "tools/call",
            %{"name" => "self_classifying", "arguments" => %{}},
            [ToolClassifyingItsOwnError]
          )

        result = ToolsCall.run(conn, [ToolClassifyingItsOwnError])
        body = JSON.decode!(result.resp_body)

        assert body["result"]["isError"] == true

        assert_received {:telemetry, ^ref, metadata}
        assert metadata.is_error == true
        assert metadata.error_kind == :tool
      after
        :telemetry.detach(handler_id)
      end
    end

    @tag :capture_log
    @tag doc: """
         Characterizes the closed-vocabulary guard on error_kind (topic
         2026-07-31-telemetry-call-outcomes): an off-contract third element
         must crash into the rescue clause and surface as tool_raised, never
         reach telemetry as a classified :stop. This test passes both before
         and after the emitter widening — the pre-change case has no 3-tuple
         clause at all, so the value already falls through the same way. It
         exists to catch a *future* change: the guard widened to
         is_atom(kind), or a new kind value added to the contract without
         updating the `when` clause.
         """
    test "an off-contract error_kind crashes into the rescue instead of leaking into telemetry" do
      ref = make_ref()
      handler_id = "tool-stop-bogus-#{inspect(ref)}"

      :telemetry.attach_many(
        handler_id,
        [[:wymcp, :tool, :stop], [:wymcp, :tool, :error]],
        fn event, _measurements, metadata, _config ->
          send(self(), {:telemetry, ref, event, metadata})
        end,
        nil
      )

      try do
        conn =
          build_conn(
            "tools/call",
            %{"name" => "off_contract_kind", "arguments" => %{}},
            [OffContractKindTool]
          )

        result = ToolsCall.run(conn, [OffContractKindTool])
        body = JSON.decode!(result.resp_body)

        assert body["result"]["isError"] == true

        diagnostic = body["result"]["content"] |> hd() |> Map.get("text") |> JSON.decode!()
        assert diagnostic["errorType"] == "tool_raised"
        assert diagnostic["exception"] == "CaseClauseError"

        assert_received {:telemetry, ^ref, [:wymcp, :tool, :error], _error_meta}
        refute_received {:telemetry, ^ref, [:wymcp, :tool, :stop], _stop_meta}
      after
        :telemetry.detach(handler_id)
      end
    end

    @tag doc: """
         Pins why error_kind exists (topic
         2026-07-31-telemetry-call-outcomes): since 0.8.0 a dispatch-gate
         rejection and a tool-returned error both record is_error: true,
         so "which actions do callers get wrong" was inseparable from
         "which actions fail". A failure here means the classification
         died between Wymcp.Tool.dispatch/4 and the stop emitter — check
         the gate branches' third tuple element first.
         """
    test "a generated tool's dispatch-gate rejection classifies error_kind :dispatch" do
      ref = make_ref()
      handler_id = "tool-stop-dispatch-#{inspect(ref)}"

      :telemetry.attach(
        handler_id,
        [:wymcp, :tool, :stop],
        fn _event, _measurements, metadata, _config ->
          send(self(), {:telemetry, ref, metadata})
        end,
        nil
      )

      try do
        conn =
          build_conn(
            "tools/call",
            %{"name" => "echo", "arguments" => %{"action" => "nope"}},
            [EchoTool]
          )

        result = ToolsCall.run(conn, [EchoTool])
        body = JSON.decode!(result.resp_body)

        payload = body["result"]["content"] |> hd() |> Map.get("text") |> JSON.decode!()
        assert payload["error"] == "unknown_action"

        assert_received {:telemetry, ^ref, metadata}
        assert metadata.is_error == true
        assert metadata.error_kind == :dispatch
      after
        :telemetry.detach(handler_id)
      end
    end

    @tag :capture_log
    test "start and error events carry the action" do
      ref = make_ref()
      handler_id = "tool-start-error-#{inspect(ref)}"

      :telemetry.attach_many(
        handler_id,
        [[:wymcp, :tool, :start], [:wymcp, :tool, :error]],
        fn event, _measurements, metadata, _config ->
          send(self(), {:telemetry, ref, event, metadata})
        end,
        nil
      )

      try do
        conn =
          build_conn(
            "tools/call",
            %{"name" => "crasher", "arguments" => %{"action" => "crash"}},
            [CrashingTool]
          )

        ToolsCall.run(conn, [CrashingTool])

        assert_received {:telemetry, ^ref, [:wymcp, :tool, :start], start_meta}
        assert start_meta.action == "crash"

        assert_received {:telemetry, ^ref, [:wymcp, :tool, :error], error_meta}
        assert error_meta.action == "crash"
        assert error_meta.tool_name == "crasher"
      after
        :telemetry.detach(handler_id)
      end
    end
  end
end
