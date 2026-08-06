defmodule Wymcp.RouterTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog
  import Plug.Test
  import Plug.Conn

  @schema_json File.read!("priv/schema.json") |> JSON.decode!()
  @defs Map.get(@schema_json, "$defs", %{})

  # Strict copy of the canonical Icon definition: forbids unknown
  # properties so a missed key rename in `encode_icon/1` is caught
  # by JSV instead of silently passing.
  @strict_icon_schema %{
    "$schema" => "https://json-schema.org/draft/2020-12/schema",
    "$ref" => "#/$defs/Icon",
    "$defs" =>
      Map.update!(@defs, "Icon", fn icon ->
        Map.put(icon, "additionalProperties", false)
      end)
  }

  defmodule TestTool do
    use Wymcp.Tool

    def name, do: "test_tool"
    def description, do: "A test tool"

    def actions do
      %{
        ping: %{
          description: "Returns ok",
          properties: %{},
          required: [],
          defaults: %{}
        }
      }
    end

    def run_action(:ping, _data, _ctx), do: {:ok, %{status: "ok"}}
  end

  defmodule AnnotatedTestTool do
    use Wymcp.Tool

    def name, do: "annotated_test"
    def title, do: "Annotated Test"
    def description, do: "Tool with annotations"

    def annotations do
      %{"readOnlyHint" => true, "openWorldHint" => false}
    end

    def actions do
      %{
        ping: %{description: "Ping", properties: %{}, required: [], defaults: %{}}
      }
    end

    def run_action(:ping, _data, _ctx), do: {:ok, %{ok: true}}
  end

  defmodule DuplicateTool do
    use Wymcp.Tool

    def name, do: "test_tool"
    def description, do: "Has same name as TestTool"

    def actions do
      %{
        noop: %{
          description: "Does nothing",
          properties: %{},
          required: [],
          defaults: %{}
        }
      }
    end

    def run_action(:noop, _data, _ctx), do: {:ok, %{}}
  end

  defmodule ReservedNameTool do
    use Wymcp.Tool

    def name, do: "help"
    def description, do: "Illegally claims the reserved name"

    def actions do
      %{noop: %{description: "Does nothing", properties: %{}, required: [], defaults: %{}}}
    end

    def run_action(:noop, _data, _ctx), do: {:ok, %{}}
  end

  defmodule FailAuth do
    @behaviour Wymcp.Auth

    @impl Wymcp.Auth
    def authenticate(_conn), do: {:error, "Unauthorized"}
  end

  defmodule CrashAuth do
    @behaviour Wymcp.Auth

    @impl true
    def authenticate(_conn), do: raise("auth exploded")
  end

  defmodule PassAuth do
    @behaviour Wymcp.Auth

    @impl Wymcp.Auth
    def authenticate(conn), do: {:ok, conn}
  end

  defmodule BadShapeRequiredTool do
    @behaviour Wymcp.Tool

    def name, do: "bad_required"
    def description, do: "Required is not a list of binaries"

    def actions do
      %{
        op: %{
          description: "Bad",
          properties: %{"x" => %{"type" => "string"}},
          required: [:x]
        }
      }
    end

    def run_action(_, _, _), do: {:ok, %{}}
    def hints(_, _), do: []
    def handle_error(_), do: ""
    def action_context(_, _), do: nil
    def title, do: nil
    def annotations, do: nil
    def output_schema, do: nil
  end

  defmodule UnknownFieldRequiredTool do
    @behaviour Wymcp.Tool

    def name, do: "unknown_required"
    def description, do: "Required references a field not in properties"

    def actions do
      %{
        op: %{
          description: "Bad",
          properties: %{"x" => %{"type" => "string"}},
          required: ["y"]
        }
      }
    end

    def run_action(_, _, _), do: {:ok, %{}}
    def hints(_, _), do: []
    def handle_error(_), do: ""
    def action_context(_, _), do: nil
    def title, do: nil
    def annotations, do: nil
    def output_schema, do: nil
  end

  defmodule BadShapeRequiredOneOfTool do
    @behaviour Wymcp.Tool

    def name, do: "bad_one_of"
    def description, do: "required_one_of group is a string"

    def actions do
      %{
        op: %{
          description: "Bad",
          properties: %{"x" => %{"type" => "string"}},
          required_one_of: [["x"], "y"]
        }
      }
    end

    def run_action(_, _, _), do: {:ok, %{}}
    def hints(_, _), do: []
    def handle_error(_), do: ""
    def action_context(_, _), do: nil
    def title, do: nil
    def annotations, do: nil
    def output_schema, do: nil
  end

  defmodule UnknownFieldRequiredOneOfTool do
    @behaviour Wymcp.Tool

    def name, do: "unknown_one_of"
    def description, do: "required_one_of references field not in properties"

    def actions do
      %{
        op: %{
          description: "Bad",
          properties: %{"x" => %{"type" => "string"}},
          required_one_of: [["x"], ["y"]]
        }
      }
    end

    def run_action(_, _, _), do: {:ok, %{}}
    def hints(_, _), do: []
    def handle_error(_), do: ""
    def action_context(_, _), do: nil
    def title, do: nil
    def annotations, do: nil
    def output_schema, do: nil
  end

  defmodule EmptyGroupTool do
    @behaviour Wymcp.Tool

    def name, do: "empty_group"
    def description, do: "required_one_of has an empty group"

    def actions do
      %{
        op: %{
          description: "Bad",
          properties: %{"x" => %{"type" => "string"}},
          required_one_of: [["x"], []]
        }
      }
    end

    def run_action(_, _, _), do: {:ok, %{}}
    def hints(_, _), do: []
    def handle_error(_), do: ""
    def action_context(_, _), do: nil
    def title, do: nil
    def annotations, do: nil
    def output_schema, do: nil
  end

  defmodule SupersetGroupTool do
    @behaviour Wymcp.Tool

    def name, do: "superset"
    def description, do: "required_one_of has a strict-superset group (dead code)"

    def actions do
      %{
        op: %{
          description: "Bad",
          properties: %{
            "a" => %{"type" => "string"},
            "b" => %{"type" => "string"}
          },
          required_one_of: [["a"], ["a", "b"]]
        }
      }
    end

    def run_action(_, _, _), do: {:ok, %{}}
    def hints(_, _), do: []
    def handle_error(_), do: ""
    def action_context(_, _), do: nil
    def title, do: nil
    def annotations, do: nil
    def output_schema, do: nil
  end

  defmodule BadNotesTool do
    @behaviour Wymcp.Tool

    def name, do: "bad_notes"
    def description, do: ":notes is not a binary"

    def actions do
      %{
        op: %{
          description: "Bad",
          properties: %{"x" => %{"type" => "string"}},
          notes: 123
        }
      }
    end

    def run_action(_, _, _), do: {:ok, %{}}
    def hints(_, _), do: []
    def handle_error(_), do: ""
    def action_context(_, _), do: nil
    def title, do: nil
    def annotations, do: nil
    def output_schema, do: nil
  end

  defmodule BadRelatedTool do
    @behaviour Wymcp.Tool

    def name, do: "bad_related"
    def description, do: ":related is not a list of binaries"

    def actions do
      %{
        op: %{
          description: "Bad",
          properties: %{"x" => %{"type" => "string"}},
          related: [:identify]
        }
      }
    end

    def run_action(_, _, _), do: {:ok, %{}}
    def hints(_, _), do: []
    def handle_error(_), do: ""
    def action_context(_, _), do: nil
    def title, do: nil
    def annotations, do: nil
    def output_schema, do: nil
  end

  defmodule BadExamplesTool do
    @behaviour Wymcp.Tool

    def name, do: "bad_examples"
    def description, do: ":examples is not a list of maps"

    def actions do
      %{
        op: %{
          description: "Bad",
          properties: %{"x" => %{"type" => "string"}},
          examples: ["payload-1"]
        }
      }
    end

    def run_action(_, _, _), do: {:ok, %{}}
    def hints(_, _), do: []
    def handle_error(_), do: ""
    def action_context(_, _), do: nil
    def title, do: nil
    def annotations, do: nil
    def output_schema, do: nil
  end

  defmodule StrayKeyTool do
    use Wymcp.Tool

    def name, do: "stray_key_tool"
    def description, do: "Carries an action-schema key outside the vocabulary"

    def actions do
      %{
        noop: %{
          description: "Does nothing",
          properties: %{},
          example: [%{}]
        }
      }
    end

    def run_action(:noop, _data, _ctx), do: {:ok, %{}}
  end

  defmodule MissingDescriptionTool do
    @behaviour Wymcp.Tool

    def name, do: "missing_description"
    def description, do: "An action lacks :description"

    def actions do
      %{op: %{properties: %{"x" => %{"type" => "string"}}}}
    end

    def run_action(_, _, _), do: {:ok, %{}}
    def hints(_, _), do: []
    def handle_error(_), do: ""
    def action_context(_, _), do: nil
    def title, do: nil
    def annotations, do: nil
    def output_schema, do: nil
  end

  defmodule MissingPropertiesTool do
    @behaviour Wymcp.Tool

    def name, do: "missing_properties"
    def description, do: "An action lacks :properties"

    def actions do
      %{op: %{description: "Op without properties"}}
    end

    def run_action(_, _, _), do: {:ok, %{}}
    def hints(_, _), do: []
    def handle_error(_), do: ""
    def action_context(_, _), do: nil
    def title, do: nil
    def annotations, do: nil
    def output_schema, do: nil
  end

  defmodule NewlineDescriptionTool do
    @behaviour Wymcp.Tool

    def name, do: "newline_description"
    def description, do: "An action description contains a newline"

    def actions do
      %{op: %{description: "First line\nsecond line", properties: %{}}}
    end

    def run_action(_, _, _), do: {:ok, %{}}
    def hints(_, _), do: []
    def handle_error(_), do: ""
    def action_context(_, _), do: nil
    def title, do: nil
    def annotations, do: nil
    def output_schema, do: nil
  end

  defmodule NewlineActionNameTool do
    @behaviour Wymcp.Tool

    def name, do: "newline_action_name"
    def description, do: "An action name contains a newline"

    def actions do
      %{:"first\nsecond" => %{description: "Valid description", properties: %{}}}
    end

    def run_action(_, _, _), do: {:ok, %{}}
    def hints(_, _), do: []
    def handle_error(_), do: ""
    def action_context(_, _), do: nil
    def title, do: nil
    def annotations, do: nil
    def output_schema, do: nil
  end

  defmodule StringActionNameTool do
    @behaviour Wymcp.Tool

    def name, do: "string_action_name"
    def description, do: "An action name is a string, not an atom"

    def actions do
      %{"op" => %{description: "Valid description", properties: %{}}}
    end

    def run_action(_, _, _), do: {:ok, %{}}
    def hints(_, _), do: []
    def handle_error(_), do: ""
    def action_context(_, _), do: nil
    def title, do: nil
    def annotations, do: nil
    def output_schema, do: nil
  end

  defmodule MultilineNotesTool do
    use Wymcp.Tool

    def name, do: "multiline_notes"
    def description, do: "Notes carry multi-paragraph Markdown"

    def actions do
      %{
        op: %{
          description: "Valid description",
          properties: %{},
          notes: "Overview.\n\n## Components\n\nDetails."
        }
      }
    end

    def run_action(_action, _data, _ctx), do: {:ok, %{}}
  end

  defmodule OneOfTool do
    use Wymcp.Tool

    def name, do: "oneof"
    def description, do: "OR-of-AND test tool"

    def actions do
      %{
        identify: %{
          description: "Identify by id or (name + color)",
          properties: %{
            "id" => %{"type" => "integer"},
            "name" => %{"type" => "string"},
            "color" => %{"type" => "string"}
          },
          required_one_of: [["id"], ["name", "color"]]
        }
      }
    end

    def run_action(:identify, data, _ctx), do: {:ok, %{found: data}}
  end

  defmodule MultiActionTool do
    use Wymcp.Tool

    def name, do: "multi_action"
    def description, do: "A tool with two actions"

    def actions do
      %{
        alpha: %{description: "Do alpha", properties: %{}, required: [], defaults: %{}},
        beta: %{description: "Do beta", properties: %{}, required: [], defaults: %{}}
      }
    end

    def run_action(_action, _data, _ctx), do: {:ok, %{}}
  end

  defmodule VanishingSession do
    @moduledoc false
    use GenServer

    # Alive at Session.lookup/1, gone by the time the stream registers —
    # the lookup→registration race, made deterministic. Answers the
    # router's touch cast, then refuses the register_stream call by
    # stopping without replying, which exits the caller;
    # Transport.Stream.serve/3 turns that into {:error, :session_gone}.
    def start(session_id) do
      GenServer.start(__MODULE__, nil,
        name: {:via, Registry, {Wymcp.Session.Registry, session_id}}
      )
    end

    @impl GenServer
    def init(nil), do: {:ok, nil}

    @impl GenServer
    def handle_cast(:touch, state), do: {:noreply, state}

    @impl GenServer
    def handle_call({:register_stream, _pid}, _from, state), do: {:stop, :normal, state}
  end

  defp call_router(body, opts \\ []) do
    router_opts = Keyword.merge([tools: [TestTool]], opts)
    init_opts = Wymcp.Router.init(router_opts)

    conn(:post, "/", JSON.encode!(body))
    |> put_req_header("content-type", "application/json")
    |> Wymcp.Router.call(init_opts)
  end

  defp initialize(opts \\ []) do
    body = %{
      "jsonrpc" => "2.0",
      "id" => 0,
      "method" => "initialize",
      "params" => %{
        "protocolVersion" => "2025-11-25",
        "capabilities" => %{},
        "clientInfo" => %{"name" => "test", "version" => "1.0"}
      }
    }

    conn = call_router(body, opts)
    [session_id] = get_resp_header(conn, "mcp-session-id")

    # Complete the handshake so session is :ready
    notify_body = %{"jsonrpc" => "2.0", "method" => "notifications/initialized"}
    call_with_session(notify_body, session_id, opts)

    session_id
  end

  defp call_with_session(body, session_id, opts \\ []) do
    router_opts = Keyword.merge([tools: [TestTool]], opts)
    init_opts = Wymcp.Router.init(router_opts)

    conn(:post, "/", JSON.encode!(body))
    |> put_req_header("content-type", "application/json")
    |> put_req_header("mcp-session-id", session_id)
    |> put_req_header("mcp-protocol-version", "2025-11-25")
    |> Wymcp.Router.call(init_opts)
  end

  describe "initialize" do
    test "returns server info, capabilities, and session ID header" do
      body = %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "initialize",
        "params" => %{
          "protocolVersion" => "2025-11-25",
          "capabilities" => %{"sampling" => %{}},
          "clientInfo" => %{"name" => "test", "version" => "1.0"}
        }
      }

      conn = call_router(body)
      resp = JSON.decode!(conn.resp_body)

      assert resp["result"]["protocolVersion"] == "2025-11-25"
      assert resp["result"]["capabilities"]["tools"] == %{"listChanged" => true}

      [session_id] = get_resp_header(conn, "mcp-session-id")
      assert is_binary(session_id)
      assert byte_size(session_id) > 0

      refute Map.has_key?(resp["result"], "instructions")
    end

    test "includes instructions when configured" do
      instructions = "Always call help before using a tool action."

      body = %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "initialize",
        "params" => %{
          "protocolVersion" => "2025-11-25",
          "capabilities" => %{},
          "clientInfo" => %{"name" => "test", "version" => "1.0"}
        }
      }

      conn = call_router(body, instructions: instructions)
      resp = JSON.decode!(conn.resp_body)

      assert resp["result"]["instructions"] == instructions
    end

    test "includes enriched server_info fields and icons conform to the MCP Icon schema" do
      server_info = %{
        title: "My Awesome Server",
        description: "A server that does great things",
        website_url: "https://example.com",
        icons: [
          %{
            src: "https://example.com/icon.svg",
            mime_type: "image/svg+xml",
            sizes: ["any"],
            theme: "dark"
          }
        ]
      }

      body = %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "initialize",
        "params" => %{
          "protocolVersion" => "2025-11-25",
          "capabilities" => %{},
          "clientInfo" => %{"name" => "test", "version" => "1.0"}
        }
      }

      conn = call_router(body, server_info: server_info)
      resp = JSON.decode!(conn.resp_body)

      server_info_resp = resp["result"]["serverInfo"]
      assert server_info_resp["title"] == "My Awesome Server"
      assert server_info_resp["description"] == "A server that does great things"
      assert server_info_resp["websiteUrl"] == "https://example.com"

      # Each emitted icon must validate against the strict canonical
      # Icon schema. This single assertion subsumes hand-rolled checks
      # for `src`, `mimeType`, `sizes`, `theme`, type correctness, and
      # absence of unknown fields like `mime_type`.
      for icon <- server_info_resp["icons"] do
        assert :ok = Wymcp.JsonRpc.validate_schema(@strict_icon_schema, icon),
               "icon #{inspect(icon)} did not validate against the canonical Icon schema"
      end

      # name and version still present from app config
      assert server_info_resp["name"]
      assert server_info_resp["version"]
    end

    test "includes only provided server_info fields" do
      server_info = %{title: "Just A Title"}

      body = %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "initialize",
        "params" => %{
          "protocolVersion" => "2025-11-25",
          "capabilities" => %{},
          "clientInfo" => %{"name" => "test", "version" => "1.0"}
        }
      }

      conn = call_router(body, server_info: server_info)
      resp = JSON.decode!(conn.resp_body)

      server_info_resp = resp["result"]["serverInfo"]
      assert server_info_resp["title"] == "Just A Title"
      assert server_info_resp["name"]
      assert server_info_resp["version"]
      refute Map.has_key?(server_info_resp, "description")
      refute Map.has_key?(server_info_resp, "websiteUrl")
      refute Map.has_key?(server_info_resp, "icons")
    end

    test "drops unknown icon keys and logs a warning naming them" do
      server_info = %{
        icons: [
          %{
            src: "https://example.com/icon.png",
            mime_type: "image/png",
            # Unknown keys — should be dropped and logged.
            url: "https://legacy.example.com/icon.png",
            media_type: "image/png",
            colour: "blue"
          }
        ]
      }

      body = %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "initialize",
        "params" => %{
          "protocolVersion" => "2025-11-25",
          "capabilities" => %{},
          "clientInfo" => %{"name" => "test", "version" => "1.0"}
        }
      }

      {conn, log} =
        with_log(fn ->
          call_router(body, server_info: server_info)
        end)

      resp = JSON.decode!(conn.resp_body)
      [icon] = resp["result"]["serverInfo"]["icons"]

      # Output validates against the canonical Icon schema (strict
      # variant prepared in Task 1).
      assert :ok = Wymcp.JsonRpc.validate_schema(@strict_icon_schema, icon)

      # Unknown keys are absent from the wire output.
      refute Map.has_key?(icon, "url")
      refute Map.has_key?(icon, "media_type")
      refute Map.has_key?(icon, "mediaType")
      refute Map.has_key?(icon, "colour")

      # Warning log names every unknown key so an upgrading caller
      # can find the source of the drop in their logs.
      assert log =~ "dropping unknown icon keys"
      assert log =~ ":url"
      assert log =~ ":media_type"
      assert log =~ ":colour"
    end

    @tag doc: """
         When the client requests a supported version, the server MUST
         echo it back in InitializeResult.protocolVersion. Returning a
         different (e.g. always-latest) value causes spec-strict clients
         like Zed to bail out with "Unsupported protocol version".
         """
    test "echoes the client's requested version when supported" do
      for requested <- ~w(2025-11-25 2025-06-18 2025-03-26) do
        body = %{
          "jsonrpc" => "2.0",
          "id" => 1,
          "method" => "initialize",
          "params" => %{
            "protocolVersion" => requested,
            "capabilities" => %{},
            "clientInfo" => %{"name" => "test", "version" => "1.0"}
          }
        }

        conn = call_router(body)
        resp = JSON.decode!(conn.resp_body)

        assert resp["result"]["protocolVersion"] == requested,
               "expected echo of #{requested}, got #{inspect(resp["result"]["protocolVersion"])}"
      end
    end

    @tag doc: """
         Per spec, when the client requests an unsupported version the
         server MUST respond with one it supports — not a JSON-RPC
         error. The client then decides whether to disconnect.
         """
    test "counter-proposes latest/0 when the requested version is unsupported" do
      body = %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "initialize",
        "params" => %{
          "protocolVersion" => "1999-01-01",
          "capabilities" => %{},
          "clientInfo" => %{"name" => "test", "version" => "1.0"}
        }
      }

      conn = call_router(body)
      resp = JSON.decode!(conn.resp_body)

      assert resp["result"]["protocolVersion"] == Wymcp.ProtocolVersion.latest()
      refute Map.has_key?(resp, "error")
      assert [_session_id] = get_resp_header(conn, "mcp-session-id")
    end

    @tag doc: """
         Per spec: when the server does not support the requested
         version, it MUST respond with one it does — not a JSON-RPC
         error. The session is created and pinned to the counter-proposed
         version; the client decides whether to disconnect.
         """
    test "counter-proposes latest/0 for unsupported protocol version" do
      body = %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "initialize",
        "params" => %{
          "protocolVersion" => "1999-01-01",
          "capabilities" => %{},
          "clientInfo" => %{"name" => "test", "version" => "1.0"}
        }
      }

      conn = call_router(body)
      resp = JSON.decode!(conn.resp_body)

      refute Map.has_key?(resp, "error")
      assert resp["result"]["protocolVersion"] == Wymcp.ProtocolVersion.latest()
      assert [_session_id] = get_resp_header(conn, "mcp-session-id")
    end
  end

  describe "ping" do
    test "returns empty result" do
      body = %{"jsonrpc" => "2.0", "id" => 2, "method" => "ping"}
      conn = call_router(body)
      resp = JSON.decode!(conn.resp_body)

      assert resp["result"] == %{}
    end
  end

  describe "tools/list" do
    test "returns registered tools plus the injected help tool" do
      session_id = initialize()

      body = %{"jsonrpc" => "2.0", "id" => 3, "method" => "tools/list"}
      conn = call_with_session(body, session_id)
      resp = JSON.decode!(conn.resp_body)

      assert [%{"name" => "test_tool"}, %{"name" => "help"}] = resp["result"]["tools"]
    end

    test "action enum description reaches the wire as newline-joined summaries" do
      session_id = initialize(tools: [MultiActionTool])

      body = %{"jsonrpc" => "2.0", "id" => 3, "method" => "tools/list"}
      conn = call_with_session(body, session_id, tools: [MultiActionTool])
      resp = JSON.decode!(conn.resp_body)

      tool = Enum.find(resp["result"]["tools"], &(&1["name"] == "multi_action"))

      assert tool["inputSchema"]["properties"]["action"]["description"] ==
               "alpha: Do alpha\nbeta: Do beta"
    end
  end

  describe "tools/call" do
    test "executes the tool and returns result" do
      session_id = initialize()

      body = %{
        "jsonrpc" => "2.0",
        "id" => 4,
        "method" => "tools/call",
        "params" => %{
          "name" => "test_tool",
          "arguments" => %{"action" => "ping"}
        }
      }

      conn = call_with_session(body, session_id)
      resp = JSON.decode!(conn.resp_body)

      assert resp["result"]["isError"] == false
      content = resp["result"]["content"] |> hd() |> Map.get("text") |> JSON.decode!()
      assert content["status"] == "ok"
    end
  end

  describe "authentication" do
    test "returns 401 when auth module rejects the request" do
      body = %{"jsonrpc" => "2.0", "id" => 5, "method" => "tools/list"}
      conn = call_router(body, auth: FailAuth)

      assert conn.status == 401
      assert get_resp_header(conn, "www-authenticate") == ["Bearer"]
      resp = JSON.decode!(conn.resp_body)
      assert resp["error"]["code"] == -32600
    end

    test "passes through when no auth module is configured (defaults to Noop)" do
      body = %{"jsonrpc" => "2.0", "id" => 6, "method" => "ping"}
      conn = call_router(body)

      assert conn.status == 200
    end

    @tag capture_log: true
    test "auth module that raises returns 401" do
      body = %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "initialize",
        "params" => %{}
      }

      conn = call_router(body, auth: CrashAuth)

      assert conn.status == 401
      assert get_resp_header(conn, "www-authenticate") == ["Bearer"]
    end

    @tag doc: """
         Proves the :www_authenticate forward option flows through Router.init →
         copy_opts_to_assign → the auth plug. Failure means the option is stripped
         or renamed in the router plumbing even while the plug unit tests pass.
         """
    test "401 WWW-Authenticate carries configured auth-params" do
      body = %{"jsonrpc" => "2.0", "id" => 1, "method" => "tools/list"}

      conn =
        call_router(body,
          auth: FailAuth,
          www_authenticate: [resource_metadata: "https://example.com/prm", scope: "mcp"]
        )

      assert conn.status == 401

      assert get_resp_header(conn, "www-authenticate") ==
               [~s(Bearer resource_metadata="https://example.com/prm", scope="mcp")]
    end
  end

  describe "wire checks (GET/DELETE)" do
    test "unauthenticated GET answers 401 before the session-header read" do
      opts = Wymcp.Router.init(tools: [TestTool], auth: FailAuth)

      conn = conn(:get, "/") |> Wymcp.Router.call(opts)

      assert conn.status == 401
      assert get_resp_header(conn, "www-authenticate") == ["Bearer"]
      assert JSON.decode!(conn.resp_body) == %{"error" => "Unauthorized"}
    end

    test "unauthenticated DELETE answers 401 before the session-header read" do
      opts = Wymcp.Router.init(tools: [TestTool], auth: FailAuth)

      conn = conn(:delete, "/") |> Wymcp.Router.call(opts)

      assert conn.status == 401
      assert get_resp_header(conn, "www-authenticate") == ["Bearer"]
      assert JSON.decode!(conn.resp_body) == %{"error" => "Unauthorized"}
    end

    @tag doc: """
         Pins the spec's "on every method" promise for the WWW-Authenticate
         challenge: configured auth-params must render on the GET/DELETE 401s
         too, not just POST's (pinned at the "401 WWW-Authenticate carries
         configured auth-params" test in the authentication describe). The
         params reach the plug through Router.init → copy_opts_to_assign, which
         yields a keyword-list assign; a failure means with_wire_checks/2 or the
         GET/DELETE assign plumbing dropped the option on those two routes only.
         """
    test "configured WWW-Authenticate auth-params render on the GET and DELETE 401s" do
      opts =
        Wymcp.Router.init(
          tools: [TestTool],
          auth: FailAuth,
          www_authenticate: [scope: "mcp"]
        )

      get_conn = conn(:get, "/") |> Wymcp.Router.call(opts)
      delete_conn = conn(:delete, "/") |> Wymcp.Router.call(opts)

      assert get_conn.status == 401
      assert delete_conn.status == 401
      assert get_resp_header(get_conn, "www-authenticate") == [~s(Bearer scope="mcp")]
      assert get_resp_header(delete_conn, "www-authenticate") == [~s(Bearer scope="mcp")]
    end

    test "unauthenticated GET with a valid session answers 401 and leaves the session alive" do
      session_id = initialize()
      opts = Wymcp.Router.init(tools: [TestTool], auth: FailAuth)

      task =
        Task.async(fn ->
          conn(:get, "/")
          |> put_req_header("mcp-session-id", session_id)
          |> Wymcp.Router.call(opts)
        end)

      conn =
        case Task.yield(task, 2000) do
          {:ok, result_conn} ->
            result_conn

          nil ->
            Task.shutdown(task, :brutal_kill)
            flunk("GET blocked — a stream opened instead of a wire-check rejection")
        end

      assert conn.status == 401
      assert JSON.decode!(conn.resp_body) == %{"error" => "Unauthorized"}
      assert {:ok, _pid} = Wymcp.Session.lookup(session_id)
    end

    test "unauthenticated DELETE with a valid session answers 401 and does not terminate it" do
      session_id = initialize()
      opts = Wymcp.Router.init(tools: [TestTool], auth: FailAuth)

      conn =
        conn(:delete, "/")
        |> put_req_header("mcp-session-id", session_id)
        |> Wymcp.Router.call(opts)

      assert conn.status == 401
      assert {:ok, _pid} = Wymcp.Session.lookup(session_id)
    end

    test "disallowed Origin on GET answers 403 in the plain-JSON dialect" do
      opts = Wymcp.Router.init(tools: [TestTool], origin: ["http://allowed.example"])

      conn =
        conn(:get, "/")
        |> put_req_header("origin", "http://evil.example")
        |> Wymcp.Router.call(opts)

      assert conn.status == 403

      assert JSON.decode!(conn.resp_body) ==
               %{"error" => "Origin not allowed: http://evil.example"}
    end

    test "disallowed Origin on DELETE answers 403 in the plain-JSON dialect" do
      opts = Wymcp.Router.init(tools: [TestTool], origin: ["http://allowed.example"])

      conn =
        conn(:delete, "/")
        |> put_req_header("origin", "http://evil.example")
        |> Wymcp.Router.call(opts)

      assert conn.status == 403

      assert JSON.decode!(conn.resp_body) ==
               %{"error" => "Origin not allowed: http://evil.example"}
    end

    test "duplicated Origin header on GET answers 400 in the plain-JSON dialect" do
      opts = Wymcp.Router.init(tools: [TestTool], origin: ["http://allowed.example"])

      conn =
        conn(:get, "/")
        |> put_req_header("origin", "http://allowed.example")
        |> prepend_req_headers([{"origin", "http://allowed.example"}])
        |> Wymcp.Router.call(opts)

      assert conn.status == 400
      assert JSON.decode!(conn.resp_body)["error"] =~ "Duplicated Origin"
    end

    test "duplicated Origin header on DELETE answers 400 in the plain-JSON dialect" do
      opts = Wymcp.Router.init(tools: [TestTool], origin: ["http://allowed.example"])

      conn =
        conn(:delete, "/")
        |> put_req_header("origin", "http://allowed.example")
        |> prepend_req_headers([{"origin", "http://allowed.example"}])
        |> Wymcp.Router.call(opts)

      assert conn.status == 400
      assert JSON.decode!(conn.resp_body)["error"] =~ "Duplicated Origin"
    end

    test "the origin check runs before the auth check" do
      opts =
        Wymcp.Router.init(
          tools: [TestTool],
          auth: FailAuth,
          origin: ["http://allowed.example"]
        )

      conn =
        conn(:get, "/")
        |> put_req_header("origin", "http://evil.example")
        |> Wymcp.Router.call(opts)

      assert conn.status == 403
    end

    test "a passing auth module lets GET and DELETE proceed to the session answers" do
      opts = Wymcp.Router.init(tools: [TestTool], auth: PassAuth)

      get_conn =
        conn(:get, "/")
        |> put_req_header("mcp-session-id", "bogus")
        |> Wymcp.Router.call(opts)

      delete_conn =
        conn(:delete, "/")
        |> put_req_header("mcp-session-id", "bogus")
        |> Wymcp.Router.call(opts)

      assert get_conn.status == 404
      assert delete_conn.status == 404
    end

    @tag doc: """
         Guards the pre-wire-check hole where an unauthenticated GET reset the
         session's idle timer (Session.touch/1 ran before any check), so a
         leaked session ID kept a session alive indefinitely. A failure means
         a rejected request is touching the session again — check the
         wire-check placement in the GET/DELETE route bodies first.
         """
    test "a rejected GET does not reset the session's idle timer" do
      # Supervised startup is safe now that sessions are restart: :temporary
      # (this test previously pinned Session.start_link/1 to dodge the
      # :permanent restart of the expiry it waits for). The monitor
      # replaces the old link+trap_exit arrangement.
      {:ok, pid, session_id} =
        Wymcp.Session.start_session(Wymcp.Testing.build_session_opts(session_idle_timeout: 400))

      ref = Process.monitor(pid)
      opts = Wymcp.Router.init(tools: [TestTool], auth: FailAuth)

      Process.sleep(250)

      task =
        Task.async(fn ->
          conn(:get, "/")
          |> put_req_header("mcp-session-id", session_id)
          |> Wymcp.Router.call(opts)
        end)

      conn =
        case Task.yield(task, 2000) do
          {:ok, result_conn} ->
            result_conn

          nil ->
            Task.shutdown(task, :brutal_kill)
            flunk("GET blocked — a stream opened instead of a wire-check rejection")
        end

      assert conn.status == 401

      # The session must still be alive at rejection time — if the 250 ms
      # sleep overran the 400 ms timeout under load, the test would
      # otherwise pass without testing anything; failing here instead
      # signals "widen the margins".
      assert {:ok, _} = Wymcp.Session.lookup(session_id)

      # An untouched timer expires the session ~400 ms after creation, so
      # the :DOWN arrives well inside this 300 ms window; a touched one
      # would fire at ~650 ms, outside it.
      assert_receive {:DOWN, ^ref, :process, ^pid, {:shutdown, :session_expired}}, 300
    end

    @tag doc: """
         Guards the displacement hole: an unauthenticated GET with a leaked
         session ID could register itself as the session's stream, kicking
         the legitimate client off its SSE connection. A failure means a
         rejected GET reached Session.register_stream/2.
         """
    test "a rejected GET does not displace the session's registered stream" do
      session_id = initialize()
      test_pid = self()

      legit =
        Task.async(fn ->
          result_conn =
            conn(:get, "/")
            |> put_req_header("mcp-session-id", session_id)
            |> Wymcp.Router.call(Wymcp.Router.init(tools: [TestTool]))

          send(test_pid, {:stream_done, result_conn})
          result_conn
        end)

      # Give the legitimate stream time to register
      Process.sleep(100)

      rejected =
        Task.async(fn ->
          conn(:get, "/")
          |> put_req_header("mcp-session-id", session_id)
          |> Wymcp.Router.call(Wymcp.Router.init(tools: [TestTool], auth: FailAuth))
        end)

      rejected_conn =
        case Task.yield(rejected, 2000) do
          {:ok, result_conn} ->
            result_conn

          nil ->
            Task.shutdown(rejected, :brutal_kill)
            flunk("GET blocked — a stream opened instead of a wire-check rejection")
        end

      assert rejected_conn.status == 401

      # The legitimate stream must still be the session's registered
      # stream — displacement would have swapped the registered pid to
      # the rejected GET's process.
      assert Wymcp.Session.get_state(session_id).stream_pid == legit.pid

      Wymcp.Session.terminate_session(session_id)
      assert_receive {:stream_done, legit_conn}, 2000
      assert legit_conn.status == 200
      Task.await(legit, 1000)
    end
  end

  describe "init/1 :www_authenticate validation" do
    test "raises when the option is not a keyword list" do
      assert_raise ArgumentError, ~r/www_authenticate/, fn ->
        Wymcp.Router.init(tools: [TestTool], www_authenticate: "Bearer foo")
      end
    end

    test "raises on a value that is neither a binary nor an MFA tuple" do
      assert_raise ArgumentError, ~r/www_authenticate/, fn ->
        Wymcp.Router.init(tools: [TestTool], www_authenticate: [resource_metadata: 123])
      end
    end

    test "accepts binary and MFA values" do
      assert Wymcp.Router.init(
               tools: [TestTool],
               www_authenticate: [resource_metadata: {SomeApp.Endpoint, :url, []}, scope: "mcp"]
             )
    end
  end

  describe "GET (SSE listener)" do
    @tag doc: """
         GET without a session header must return 400 — the client needs to
         initialize first (POST) to get a session ID, then open the SSE
         stream (GET) with that ID. A failure here means the router is not
         checking for the session header on GET.
         """
    test "returns 400 when no mcp-session-id header" do
      opts = Wymcp.Router.init(tools: [TestTool])
      conn = conn(:get, "/") |> Wymcp.Router.call(opts)
      assert conn.status == 400
    end

    @tag doc: """
         GET with an unknown session ID must return 404. The client should
         re-initialize if its session has expired.
         """
    test "returns 404 when session not found" do
      opts = Wymcp.Router.init(tools: [TestTool])

      conn =
        conn(:get, "/")
        |> put_req_header("mcp-session-id", "nonexistent")
        |> Wymcp.Router.call(opts)

      assert conn.status == 404
    end

    @tag doc: """
         Registration precedes the 200 commit: a session that dies between
         the router's lookup and the stream's registration answers the
         same 404 as an unknown session, before any bytes are committed.
         The stand-in is started with GenServer.start/3, not start_link/3,
         so its exit does not reach the test process, and it is asserted
         alive at lookup time — a stand-in that died earlier would let
         Registry cleanup win, routing the request through the
         already-tested lookup-miss branch and passing for the wrong
         reason.
         """
    test "returns 404 when the session dies between lookup and stream registration" do
      session_id = "vanishing-#{System.unique_integer([:positive])}"
      {:ok, session_pid} = VanishingSession.start(session_id)
      assert {:ok, ^session_pid} = Wymcp.Session.lookup(session_id)

      opts = Wymcp.Router.init(tools: [TestTool])

      conn =
        conn(:get, "/")
        |> put_req_header("mcp-session-id", session_id)
        |> Wymcp.Router.call(opts)

      assert conn.status == 404
      assert JSON.decode!(conn.resp_body) == %{"error" => "Session not found"}
    end

    @tag doc: """
         get_req_header/2 returns every value of a repeated header — the old
         single-element case head crashed with CaseClauseError (a 500) on a
         duplicated Mcp-Session-Id. The GET/DELETE routes answer in the
         plain-JSON dialect, not JSON-RPC: no JSON-RPC request exists on
         these verbs.
         """
    test "returns 400 when the mcp-session-id header is duplicated" do
      opts = Wymcp.Router.init(tools: [TestTool])

      conn =
        conn(:get, "/")
        |> put_req_header("mcp-session-id", "a")
        |> prepend_req_headers([{"mcp-session-id", "b"}])
        |> Wymcp.Router.call(opts)

      assert conn.status == 400
      assert JSON.decode!(conn.resp_body)["error"] =~ "Duplicated Mcp-Session-Id"
    end

    @tag doc: """
         GET with a valid session must open an SSE stream — status 200,
         content-type text/event-stream, chunked state, and the priming
         event in the body: the request process writes the chunks, so the
         returned conn carries the accumulated bytes. The GET blocks for
         the stream's lifetime; terminating the session unblocks it.
         """
    test "opens SSE stream for valid session" do
      session_id = initialize()
      opts = Wymcp.Router.init(tools: [TestTool])

      test_pid = self()

      task =
        Task.async(fn ->
          result_conn =
            conn(:get, "/")
            |> put_req_header("mcp-session-id", session_id)
            |> Wymcp.Router.call(opts)

          send(test_pid, {:stream_done, result_conn})
          result_conn
        end)

      # Give the stream time to start
      Process.sleep(100)

      # Terminate session — the stream's session monitor ends the loop
      Wymcp.Session.terminate_session(session_id)

      assert_receive {:stream_done, result_conn}, 2000
      assert result_conn.status == 200
      assert result_conn.state == :chunked

      {_, content_type} =
        Enum.find(result_conn.resp_headers, fn {k, _} -> k == "content-type" end)

      assert content_type =~ "text/event-stream"
      assert result_conn.resp_body == "id: evt-1\ndata: \n\n"

      Task.await(task, 1000)
    end

    @tag doc: """
         Two GETs on one session: the second replaces the first. The
         stream is the GET request process itself, so the replaced request
         must survive replacement and finish its committed 200 — the
         session asks the old stream to stop (Transport.Stream.replace/1)
         precisely so nothing kills it. Before replacement existed the
         first task hung and Task.await/2 timed out instead.
         """
    test "a second GET replaces the first stream and the replaced request finishes" do
      session_id = initialize()
      opts = Wymcp.Router.init(tools: [TestTool])

      sse_request = fn ->
        Task.async(fn ->
          conn(:get, "/")
          |> put_req_header("mcp-session-id", session_id)
          |> Wymcp.Router.call(opts)
        end)
      end

      first = sse_request.()

      # Let the first stream register before the second replaces it.
      Process.sleep(100)

      second = sse_request.()

      first_conn = Task.await(first, 2000)
      assert first_conn.status == 200
      assert first_conn.state == :chunked
      assert first_conn.resp_body == "id: evt-1\ndata: \n\n"

      # Unblock the surviving stream the way the sibling test does.
      Wymcp.Session.terminate_session(session_id)
      second_conn = Task.await(second, 2000)
      assert second_conn.status == 200
    end

    @tag doc: """
         First router-level resumption coverage: the Last-Event-ID request
         header sets the resumption point, observable as the priming
         event's id in the response bytes — evt-7 resumes the counter at
         8. Replay of missed events stays out of scope: the counter
         resumes, nothing is re-sent.
         """
    test "resumes the event counter from a Last-Event-ID header" do
      session_id = initialize()
      opts = Wymcp.Router.init(tools: [TestTool])

      task =
        Task.async(fn ->
          conn(:get, "/")
          |> put_req_header("mcp-session-id", session_id)
          |> put_req_header("last-event-id", "evt-7")
          |> Wymcp.Router.call(opts)
        end)

      Process.sleep(100)
      Wymcp.Session.terminate_session(session_id)

      result_conn = Task.await(task, 2000)
      assert result_conn.resp_body == "id: evt-8\ndata: \n\n"
    end

    @tag doc: """
         A malformed Last-Event-ID is raw client input, not an error: the
         resumption point is discarded with a warning naming the raw
         value, and the stream starts fresh at evt-1.
         """
    test "discards a malformed Last-Event-ID and starts fresh" do
      session_id = initialize()
      opts = Wymcp.Router.init(tools: [TestTool])

      log =
        capture_log(fn ->
          task =
            Task.async(fn ->
              conn(:get, "/")
              |> put_req_header("mcp-session-id", session_id)
              |> put_req_header("last-event-id", "evt-x")
              |> Wymcp.Router.call(opts)
            end)

          Process.sleep(100)
          Wymcp.Session.terminate_session(session_id)

          result_conn = Task.await(task, 2000)
          assert result_conn.resp_body == "id: evt-1\ndata: \n\n"
        end)

      assert log =~ "SSE resumption point discarded"
      assert log =~ "evt-x"
    end
  end

  describe "capability negotiation" do
    @tag doc: """
         When the client declares sampling support in its initialize
         request, the server must echo it back in the capabilities
         response. This tells the client that the server may send
         sampling/createMessage requests during tool execution.
         """
    test "advertises sampling when client declares sampling capability" do
      body = %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "initialize",
        "params" => %{
          "protocolVersion" => "2025-11-25",
          "capabilities" => %{"sampling" => %{}},
          "clientInfo" => %{"name" => "test", "version" => "1.0"}
        }
      }

      conn = call_router(body)
      resp = JSON.decode!(conn.resp_body)

      assert resp["result"]["capabilities"]["sampling"] == %{}
      assert resp["result"]["capabilities"]["tools"] == %{"listChanged" => true}
    end

    test "advertises elicitation when client declares elicitation capability" do
      body = %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "initialize",
        "params" => %{
          "protocolVersion" => "2025-11-25",
          "capabilities" => %{"elicitation" => %{}},
          "clientInfo" => %{"name" => "test", "version" => "1.0"}
        }
      }

      conn = call_router(body)
      resp = JSON.decode!(conn.resp_body)

      assert resp["result"]["capabilities"]["elicitation"] == %{}
      assert resp["result"]["capabilities"]["tools"] == %{"listChanged" => true}
    end

    @tag doc: """
         When the client does not declare sampling or elicitation, the
         server must not advertise them. Advertising unsupported capabilities
         would cause the server to push requests that the client ignores.
         """
    test "does not advertise sampling/elicitation when client omits them" do
      body = %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "initialize",
        "params" => %{
          "protocolVersion" => "2025-11-25",
          "capabilities" => %{},
          "clientInfo" => %{"name" => "test", "version" => "1.0"}
        }
      }

      conn = call_router(body)
      resp = JSON.decode!(conn.resp_body)

      refute Map.has_key?(resp["result"]["capabilities"], "sampling")
      refute Map.has_key?(resp["result"]["capabilities"], "elicitation")
      assert resp["result"]["capabilities"]["tools"] == %{"listChanged" => true}
    end
  end

  describe "tools/list title and annotations" do
    test "returns title and annotations in tool definitions" do
      session_id = initialize(tools: [AnnotatedTestTool])

      body = %{"jsonrpc" => "2.0", "id" => 3, "method" => "tools/list"}
      conn = call_with_session(body, session_id, tools: [AnnotatedTestTool])
      resp = JSON.decode!(conn.resp_body)

      tool = Enum.find(resp["result"]["tools"], &(&1["name"] == "annotated_test"))
      assert tool["title"] == "Annotated Test"
      assert tool["annotations"]["readOnlyHint"] == true
      assert tool["annotations"]["openWorldHint"] == false
    end
  end

  describe "listChanged capability" do
    test "advertises listChanged in tools capability" do
      body = %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "initialize",
        "params" => %{
          "protocolVersion" => "2025-11-25",
          "capabilities" => %{},
          "clientInfo" => %{"name" => "test", "version" => "1.0"}
        }
      }

      conn = call_router(body)
      resp = JSON.decode!(conn.resp_body)

      assert resp["result"]["capabilities"]["tools"] == %{"listChanged" => true}
    end
  end

  describe "logging capability" do
    test "advertises logging capability" do
      body = %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "initialize",
        "params" => %{
          "protocolVersion" => "2025-11-25",
          "capabilities" => %{},
          "clientInfo" => %{"name" => "test", "version" => "1.0"}
        }
      }

      conn = call_router(body)
      resp = JSON.decode!(conn.resp_body)

      assert resp["result"]["capabilities"]["logging"] == %{}
    end
  end

  describe "logging/setLevel" do
    test "sets log level and returns empty result" do
      session_id = initialize()

      body = %{
        "jsonrpc" => "2.0",
        "id" => 10,
        "method" => "logging/setLevel",
        "params" => %{"level" => "warning"}
      }

      conn = call_with_session(body, session_id)
      resp = JSON.decode!(conn.resp_body)

      assert resp["result"] == %{}
    end

    test "returns error for invalid level" do
      session_id = initialize()

      body = %{
        "jsonrpc" => "2.0",
        "id" => 10,
        "method" => "logging/setLevel",
        "params" => %{"level" => "verbose"}
      }

      conn = call_with_session(body, session_id)
      resp = JSON.decode!(conn.resp_body)

      assert resp["error"]["code"] == -32602
    end
  end

  describe "version negotiation" do
    @tag doc: """
         When the client requests a supported but non-latest version, the
         server counter-proposes the latest. The client must then use the
         server's version. This test will need updating when a second
         protocol version is added — for now it verifies the mechanism
         exists by confirming the server always responds with the latest.
         """
    test "server responds with latest supported version" do
      body = %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "initialize",
        "params" => %{
          "protocolVersion" => "2025-11-25",
          "capabilities" => %{},
          "clientInfo" => %{"name" => "test", "version" => "1.0"}
        }
      }

      conn = call_router(body)
      resp = JSON.decode!(conn.resp_body)

      assert resp["result"]["protocolVersion"] == "2025-11-25"
    end

    test "counter-proposes latest/0 for an unsupported version" do
      body = %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "initialize",
        "params" => %{
          "protocolVersion" => "2024-01-01",
          "capabilities" => %{},
          "clientInfo" => %{"name" => "test", "version" => "1.0"}
        }
      }

      conn = call_router(body)
      resp = JSON.decode!(conn.resp_body)

      refute Map.has_key?(resp, "error")
      assert resp["result"]["protocolVersion"] == Wymcp.ProtocolVersion.latest()
    end
  end

  describe "routing" do
    test "PUT returns 404" do
      opts = Wymcp.Router.init(tools: [])

      conn =
        conn(:put, "/")
        |> put_req_header("content-type", "application/json")
        |> Wymcp.Router.call(opts)

      assert conn.status == 404
    end
  end

  describe "DELETE (session termination)" do
    test "terminates an active session" do
      session_id = initialize()
      opts = Wymcp.Router.init(tools: [TestTool])

      conn =
        conn(:delete, "/")
        |> put_req_header("mcp-session-id", session_id)
        |> Wymcp.Router.call(opts)

      assert conn.status == 200
      # Give Registry time to deregister after supervisor termination
      Process.sleep(10)
      assert {:error, :not_found} = Wymcp.Session.lookup(session_id)
    end

    test "returns 404 for unknown session" do
      opts = Wymcp.Router.init(tools: [])

      conn =
        conn(:delete, "/")
        |> put_req_header("mcp-session-id", "bogus")
        |> Wymcp.Router.call(opts)

      assert conn.status == 404
    end

    @tag doc: """
         Spec: servers SHOULD answer requests without an Mcp-Session-Id
         header with HTTP 400 — DELETE previously answered 404, colliding
         with the unknown-session signal that tells a client to
         re-initialize. Missing header = malformed request (400); unknown
         session = re-initialize (404).
         """
    test "returns 400 when no mcp-session-id header" do
      opts = Wymcp.Router.init(tools: [])

      conn = conn(:delete, "/") |> Wymcp.Router.call(opts)

      assert conn.status == 400
      assert JSON.decode!(conn.resp_body)["error"] =~ "Missing mcp-session-id header"
    end

    test "returns 400 when the mcp-session-id header is duplicated" do
      opts = Wymcp.Router.init(tools: [])

      conn =
        conn(:delete, "/")
        |> put_req_header("mcp-session-id", "a")
        |> prepend_req_headers([{"mcp-session-id", "b"}])
        |> Wymcp.Router.call(opts)

      assert conn.status == 400
      assert JSON.decode!(conn.resp_body)["error"] =~ "Duplicated Mcp-Session-Id"
    end
  end

  describe "singleton-header check" do
    @tag doc: """
         Before the singleton-header check existed, initialize carrying a
         duplicated MCP-Protocol-Version simply succeeded — nothing read the
         header's cardinality on that path. Initialize is session-exempt, so
         Plugs.Session returned before reading it, and Methods.Initialize
         negotiates from params["protocolVersion"], never from the header.
         This is the first request every client sends, so a regression here is
         maximally visible.

         It also carries a second, less obvious job: `resp["id"] == 0` below
         is the router-driven assertion that pins Plugs.Classify BEFORE
         Plugs.SingletonHeaders. Response.rejection_id/1 reads the assign
         Classify writes, so under that reorder the assign is nil, the rule's
         catch-all answers nil, and this assertion goes red. The null-id
         siblings further down cannot catch it — nil is what they expect
         either way. Do not delete this as duplicate coverage.
         """
    test "initialize with a duplicated MCP-Protocol-Version answers 400" do
      opts = Wymcp.Router.init(tools: [TestTool])

      body = %{
        "jsonrpc" => "2.0",
        "id" => 0,
        "method" => "initialize",
        "params" => %{
          "protocolVersion" => "2025-11-25",
          "capabilities" => %{},
          "clientInfo" => %{"name" => "test", "version" => "1.0"}
        }
      }

      conn =
        conn(:post, "/", JSON.encode!(body))
        |> put_req_header("content-type", "application/json")
        |> put_req_header("mcp-protocol-version", "2025-11-25")
        |> prepend_req_headers([{"mcp-protocol-version", "2025-11-25"}])
        |> Wymcp.Router.call(opts)

      assert conn.status == 400
      assert get_resp_header(conn, "mcp-session-id") == []
      resp = JSON.decode!(conn.resp_body)
      assert resp["id"] == 0
      assert resp["error"]["code"] == -32600
      assert resp["error"]["data"]["error"] =~ "Duplicated MCP-Protocol-Version"
    end

    @tag doc: """
         The forced wire change. Plugs.Session gates its
         MCP-Protocol-Version read on
         ProtocolVersion.supports_protocol_version_header?/1, so on a
         2025-03-26 session the header was never read and a duplicate never
         noticed. The check sits before any session pid resolves and so cannot
         know the negotiated version — a version-blind reject list is the price
         of running before the request touches session state.
         """
    test "a 2025-03-26 session gets 400 for a duplicated MCP-Protocol-Version" do
      opts = Wymcp.Router.init(tools: [TestTool])

      init_body = %{
        "jsonrpc" => "2.0",
        "id" => 0,
        "method" => "initialize",
        "params" => %{
          "protocolVersion" => "2025-03-26",
          "capabilities" => %{},
          "clientInfo" => %{"name" => "test", "version" => "1.0"}
        }
      }

      init_conn =
        conn(:post, "/", JSON.encode!(init_body))
        |> put_req_header("content-type", "application/json")
        |> Wymcp.Router.call(opts)

      assert JSON.decode!(init_conn.resp_body)["result"]["protocolVersion"] == "2025-03-26"
      [session_id] = get_resp_header(init_conn, "mcp-session-id")

      list_body = %{"jsonrpc" => "2.0", "id" => 9, "method" => "tools/list"}

      conn =
        conn(:post, "/", JSON.encode!(list_body))
        |> put_req_header("content-type", "application/json")
        |> put_req_header("mcp-session-id", session_id)
        |> put_req_header("mcp-protocol-version", "2025-11-25")
        |> prepend_req_headers([{"mcp-protocol-version", "2025-11-25"}])
        |> Wymcp.Router.call(opts)

      assert conn.status == 400

      assert JSON.decode!(conn.resp_body)["error"]["data"]["error"] =~
               "Duplicated MCP-Protocol-Version"
    end

    @tag doc: """
         GET and DELETE never read MCP-Protocol-Version at all
         before the check existed — a duplicate reached the routes' own
         missing-session-header 400 with the wrong message, or (with a live
         session) succeeded outright. Discriminating on the message rather than
         the status is deliberate: both answers are 400.
         """
    test "GET with a duplicated MCP-Protocol-Version answers 400 naming the header" do
      opts = Wymcp.Router.init(tools: [TestTool])

      conn =
        conn(:get, "/")
        |> put_req_header("mcp-protocol-version", "2025-11-25")
        |> prepend_req_headers([{"mcp-protocol-version", "2025-11-25"}])
        |> Wymcp.Router.call(opts)

      assert conn.status == 400

      assert JSON.decode!(conn.resp_body) == %{
               "error" =>
                 "Duplicated MCP-Protocol-Version header. Send exactly one MCP-Protocol-Version header."
             }
    end

    test "DELETE with a duplicated MCP-Protocol-Version answers 400 without terminating the session" do
      session_id = initialize()
      opts = Wymcp.Router.init(tools: [TestTool])

      conn =
        conn(:delete, "/")
        |> put_req_header("mcp-session-id", session_id)
        |> put_req_header("mcp-protocol-version", "2025-11-25")
        |> prepend_req_headers([{"mcp-protocol-version", "2025-11-25"}])
        |> Wymcp.Router.call(opts)

      assert conn.status == 400
      assert JSON.decode!(conn.resp_body)["error"] =~ "Duplicated MCP-Protocol-Version"
      assert {:ok, _pid} = Wymcp.Session.lookup(session_id)
    end

    @tag doc: """
         A JSON-RPC response message's id belongs to a request
         the *server* sent; the missing-session-header 400 used to echo it,
         handing a strict client a second answer to its own outstanding
         sampling/elicitation call. The envelope now carries null. Both this
         400 and the session-terminated 404 reach that answer the same way —
         through Wymcp.Response.rejection_id/1 — rather than either branch
         special-casing :response, which is how the 404 alone used to do it.
         """
    test "a response message rejected for a missing session header carries a null id" do
      opts = Wymcp.Router.init(tools: [TestTool])
      body = %{"jsonrpc" => "2.0", "id" => 42, "result" => %{"role" => "assistant"}}

      conn =
        conn(:post, "/", JSON.encode!(body))
        |> put_req_header("content-type", "application/json")
        |> Wymcp.Router.call(opts)

      assert conn.status == 400
      resp = JSON.decode!(conn.resp_body)
      assert resp["id"] == nil
      assert resp["error"]["data"]["error"] =~ "Missing Mcp-Session-Id"
    end

    @tag doc: """
         The same null-id rule on the *duplicated*-header rejection, driven
         end-to-end through the real router rather than a hand-built conn.

         Note what this test does NOT pin, because inverting the rule moved
         it: Response.rejection_id/1 reads the :wymcp_message_type assign that
         Plugs.Classify writes, and a nil assign now falls to the catch-all
         and yields nil — which is exactly what this test asserts. So moving
         Plugs.SingletonHeaders ahead of Plugs.Classify would leave this test
         green. Under the old rule a nil assign returned the body id, and it
         did catch that reorder.

         The order is pinned instead by the keeps-its-id assertions, which
         only a *request* body can make: "initialize with a duplicated
         MCP-Protocol-Version answers 400" above (resp["id"] == 0) is the
         router-driven one. Do not delete that as redundant coverage.
         """
    test "a response message rejected for a duplicated session header carries a null id" do
      opts = Wymcp.Router.init(tools: [TestTool])
      body = %{"jsonrpc" => "2.0", "id" => 42, "result" => %{"role" => "assistant"}}

      conn =
        conn(:post, "/", JSON.encode!(body))
        |> put_req_header("content-type", "application/json")
        |> put_req_header("mcp-session-id", "abc")
        |> prepend_req_headers([{"mcp-session-id", "abc"}])
        |> Wymcp.Router.call(opts)

      assert conn.status == 400
      resp = JSON.decode!(conn.resp_body)
      assert resp["id"] == nil
      assert resp["error"]["data"]["error"] =~ "Duplicated Mcp-Session-Id"
    end

    @tag doc: """
         The `:unknown` half of the duplicated-header branch, and the site
         spec.md names as where the closed bug was probe-verified. Its
         `:response` sibling directly above gave a null id under the old rule
         too, so that test guards nothing this topic changed; only a truncated
         answer — `{"jsonrpc":"2.0","id":42}`, which Wymcp.Plugs.Classify tags
         :unknown — distinguishes the two rules. Driven through the real router
         for the same reason the sibling is: the plug-level file sets the
         message type by hand and so cannot catch a pipeline reorder that
         leaves the assign nil.
         """
    test "a truncated answer rejected for a duplicated session header carries a null id" do
      opts = Wymcp.Router.init(tools: [TestTool])

      conn =
        conn(:post, "/", JSON.encode!(%{"jsonrpc" => "2.0", "id" => 42}))
        |> put_req_header("content-type", "application/json")
        |> put_req_header("mcp-session-id", "abc")
        |> prepend_req_headers([{"mcp-session-id", "abc"}])
        |> Wymcp.Router.call(opts)

      assert conn.status == 400
      resp = JSON.decode!(conn.resp_body)
      assert resp["id"] == nil
      assert resp["error"]["data"]["error"] =~ "Duplicated Mcp-Session-Id"
    end

    @tag doc: """
         Spec D6's router-driven leg, and the composition nothing else covers:
         a real truncated client answer, tagged by Wymcp.Plugs.Classify rather
         than by a hand-written assign. `{"jsonrpc":"2.0","id":42}` classifies
         :unknown — indistinguishable from a request by construction — so its
         id must not come back. Every plug test sets the message type itself;
         only a router-driven test proves Classify actually produces the tag
         the rule reads.
         """
    test "a truncated answer rejected for a missing session header carries a null id" do
      opts = Wymcp.Router.init(tools: [TestTool])

      conn =
        conn(:post, "/", JSON.encode!(%{"jsonrpc" => "2.0", "id" => 42}))
        |> put_req_header("content-type", "application/json")
        |> Wymcp.Router.call(opts)

      assert conn.status == 400
      resp = JSON.decode!(conn.resp_body)
      assert resp["id"] == nil
      assert resp["error"]["data"]["error"] =~ "Missing Mcp-Session-Id"
    end

    @tag doc: """
         The same truncated answer reaching Wymcp.Plugs.Validate: it holds a
         live session, so it passes the wire checks and Wymcp.Plugs.Session and
         is refused by schema validation instead. This is the path spec D5
         describes end to end — the site that was the last raw-id echo.
         """
    test "a truncated answer on a live session is refused by Validate with a null id" do
      session_id = initialize()
      opts = Wymcp.Router.init(tools: [TestTool])

      conn =
        conn(:post, "/", JSON.encode!(%{"jsonrpc" => "2.0", "id" => 42}))
        |> put_req_header("content-type", "application/json")
        |> put_req_header("mcp-session-id", session_id)
        |> put_req_header("mcp-protocol-version", "2025-11-25")
        |> Wymcp.Router.call(opts)

      assert conn.status == 400
      assert JSON.decode!(conn.resp_body)["id"] == nil
    end

    @tag doc: """
         The same body meeting a dead session: spec D2's 404 branch, driven
         end-to-end. An empty body is the whole signal — a client receiving 404
         must start a new session, so there is no next action a diagnostic
         string would add.
         """
    test "a truncated answer on a dead session answers an empty 404" do
      opts = Wymcp.Router.init(tools: [TestTool])

      conn =
        conn(:post, "/", JSON.encode!(%{"jsonrpc" => "2.0", "id" => 42}))
        |> put_req_header("content-type", "application/json")
        |> put_req_header("mcp-session-id", "no-such-session")
        |> Wymcp.Router.call(opts)

      assert conn.status == 404
      assert conn.resp_body == ""
    end
  end

  describe "session-aware routing" do
    @tag doc: """
         Non-exempt requests without Mcp-Session-Id must be rejected with
         400 per the MCP spec. The sessionless fallback has been removed.
         """
    test "non-initialize requests without session are rejected with 400" do
      body = %{"jsonrpc" => "2.0", "id" => 1, "method" => "tools/list"}
      conn = call_router(body)

      assert conn.status == 400
      resp = JSON.decode!(conn.resp_body)
      assert resp["error"]["code"] == -32600
      assert resp["error"]["data"]["error"] =~ "Missing Mcp-Session-Id"
    end

    @tag doc: """
         End-to-end proof that an unknown Mcp-Session-Id on tools/list
         is rejected with the spec-mandated 404 + JSON-RPC -32001 in
         the SDK-exact wire shape (no data field).
         A failure here means either Plugs.Session.session_terminated/2
         no longer halts, or the JsonRpc atom registry was reverted, or
         the 2-arity `error_response/2` was lost.
         The id field is preserved so the client can correlate the
         response with its request.
         """
    test "tools/list with unknown session ID returns 404 + -32001" do
      body = %{"jsonrpc" => "2.0", "id" => 1, "method" => "tools/list"}

      router_opts = [tools: [TestTool]]
      init_opts = Wymcp.Router.init(router_opts)

      conn =
        conn(:post, "/", JSON.encode!(body))
        |> put_req_header("content-type", "application/json")
        |> put_req_header("mcp-session-id", "bogus")
        |> Wymcp.Router.call(init_opts)

      assert conn.status == 404
      resp = JSON.decode!(conn.resp_body)
      assert resp["id"] == 1
      assert resp["error"]["code"] == -32001
      assert resp["error"]["message"] == "Session terminated"
      refute Map.has_key?(resp["error"], "data")
    end

    test "tools/call with unknown session ID returns 404 + -32001" do
      body = %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "tools/call",
        "params" => %{
          "name" => "test_tool",
          "arguments" => %{"action" => "ping"}
        }
      }

      router_opts = [tools: [TestTool]]
      init_opts = Wymcp.Router.init(router_opts)

      conn =
        conn(:post, "/", JSON.encode!(body))
        |> put_req_header("content-type", "application/json")
        |> put_req_header("mcp-session-id", "stale-id")
        |> Wymcp.Router.call(init_opts)

      assert conn.status == 404
      resp = JSON.decode!(conn.resp_body)
      assert resp["id"] == 1
      assert resp["error"]["code"] == -32001
      assert resp["error"]["message"] == "Session terminated"
      refute Map.has_key?(resp["error"], "data")
    end
  end

  describe "malformed requests" do
    test "malformed JSON returns parse error" do
      opts = Wymcp.Router.init(tools: [TestTool])

      conn =
        conn(:post, "/", "{not valid json}")
        |> put_req_header("content-type", "application/json")
        |> Wymcp.Router.call(opts)

      body = JSON.decode!(conn.resp_body)

      assert conn.status == 400
      assert body["error"]["code"] == -32700
      assert body["error"]["message"] =~ "Parse error"
    end

    test "empty body returns error" do
      opts = Wymcp.Router.init(tools: [TestTool])

      conn =
        conn(:post, "/", "")
        |> put_req_header("content-type", "application/json")
        |> Wymcp.Router.call(opts)

      body = JSON.decode!(conn.resp_body)

      assert conn.status in [400, 404]
      assert body["error"] != nil
    end
  end

  describe "duplicate tool names" do
    test "raises on duplicate tool names at init" do
      assert_raise ArgumentError, ~r/Duplicate tool name "test_tool"/, fn ->
        Wymcp.Router.init(tools: [TestTool, DuplicateTool])
      end
    end
  end

  describe "help auto-injection" do
    test "init raises when a consumer tool claims the reserved name" do
      assert_raise ArgumentError,
                   ~r/reserved name "help"\. The help tool is provided by Wymcp and injected into every server automatically\./,
                   fn ->
                     Wymcp.Router.init(tools: [ReservedNameTool])
                   end
    end

    test "init raises the double-init message when given already-initialized opts" do
      initialized = Wymcp.Router.init(tools: [TestTool])

      assert_raise ArgumentError, ~r/already been through Wymcp\.Router\.init\/1/, fn ->
        Wymcp.Router.init(initialized)
      end
    end

    test "tools/list includes the injected help tool after the consumer tools" do
      session_id = initialize()

      body = %{"jsonrpc" => "2.0", "id" => 3, "method" => "tools/list"}
      conn = call_with_session(body, session_id)
      resp = JSON.decode!(conn.resp_body)

      assert [%{"name" => "test_tool"}, %{"name" => "help"}] = resp["result"]["tools"]
    end

    test "help answers end-to-end through tools/call" do
      session_id = initialize()

      body = %{
        "jsonrpc" => "2.0",
        "id" => 4,
        "method" => "tools/call",
        "params" => %{"name" => "help", "arguments" => %{"tool" => "test_tool"}}
      }

      conn = call_with_session(body, session_id)
      resp = JSON.decode!(conn.resp_body)

      assert resp["result"]["isError"] == false
      response = resp["result"]["content"] |> hd() |> Map.get("text") |> JSON.decode!()
      assert response["tool"] == "test_tool"
      assert response["actions"]["ping"]["description"] == "Returns ok"
    end
  end

  describe "empty tools list" do
    test "tools/list returns only the help tool when no tools registered" do
      session_id = initialize(tools: [])

      body = %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "tools/list",
        "params" => %{}
      }

      conn = call_with_session(body, session_id, tools: [])
      resp = JSON.decode!(conn.resp_body)
      assert [%{"name" => "help"}] = resp["result"]["tools"]
    end

    test "tools/call returns method_not_found when no tools registered" do
      session_id = initialize(tools: [])

      body = %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "tools/call",
        "params" => %{"name" => "anything", "arguments" => %{}}
      }

      conn = call_with_session(body, session_id, tools: [])
      resp = JSON.decode!(conn.resp_body)
      assert resp["error"]["code"] == -32601
    end
  end

  describe "server option" do
    defmodule TestMcpServer do
      @moduledoc false
      use Wymcp.Server
    end

    @tag doc: """
         The :server option is passed through Router.init/1 to the pipeline.
         When set, Methods.Initialize includes it in the Session.start_session
         opts so the session knows which server module to call. A failure here
         means the option is being dropped somewhere in the init chain.
         """
    test "accepts :server option without error" do
      opts = Wymcp.Router.init(tools: [], server: TestMcpServer)
      assert is_list(opts)
    end

    test "works without :server option" do
      opts = Wymcp.Router.init(tools: [])
      assert is_list(opts)
    end

    @tag doc: """
         Verifies end-to-end that the :server module reaches the session.
         The test initializes a session through the router and checks that
         the session's state includes the server module.
         """
    @tag doc: """
         When a :server module doesn't implement the Wymcp.Server behaviour,
         Router.init/1 should log a warning but not crash. This allows duck-
         typed modules and avoids hard failures at startup.
         """
    test "warns when server module doesn't implement Wymcp.Server behaviour" do
      log =
        capture_log(fn ->
          Wymcp.Router.init(tools: [], server: String)
        end)

      assert log =~ "does not implement"
    end

    test "server module is stored in session state after initialize" do
      router_opts = Wymcp.Router.init(tools: [], server: TestMcpServer)

      init_conn =
        conn(
          :post,
          "/",
          JSON.encode!(%{
            "jsonrpc" => "2.0",
            "id" => 1,
            "method" => "initialize",
            "params" => %{
              "protocolVersion" => "2025-11-25",
              "capabilities" => %{},
              "clientInfo" => %{"name" => "test", "version" => "1.0"}
            }
          })
        )
        |> put_req_header("content-type", "application/json")
        |> Wymcp.Router.call(router_opts)

      assert init_conn.status == 200
      [session_id] = get_resp_header(init_conn, "mcp-session-id")
      state = Wymcp.Session.get_state(session_id)
      assert state.server == TestMcpServer
    end
  end

  describe "null request id" do
    test "handles request with null id" do
      session_id = initialize()

      body = %{
        "jsonrpc" => "2.0",
        "id" => nil,
        "method" => "tools/call",
        "params" => %{"name" => "nonexistent", "arguments" => %{}}
      }

      conn = call_with_session(body, session_id)
      resp = JSON.decode!(conn.resp_body)
      assert resp["id"] == nil
      assert resp["error"]["code"] == -32601
    end
  end

  describe "init/1 — action schema validation" do
    @tag doc: """
         :description and :properties are load-bearing at request time —
         Schema.action_summaries/1 interpolates schema.description into every
         tools/list and Help.render_action/1 dot-accesses both. A missing key
         must fail at boot per this module's validation contract, not as a
         KeyError escaping the pipeline on the first tools/list.
         """
    test "raises when an action lacks :description" do
      assert_raise ArgumentError, ~r/:description/, fn ->
        Wymcp.Router.init(tools: [MissingDescriptionTool])
      end
    end

    test "raises when an action description contains a newline" do
      assert_raise ArgumentError, ~r/newline/, fn ->
        Wymcp.Router.init(tools: [NewlineDescriptionTool])
      end
    end

    test "raises when an action carries a key outside the schema vocabulary" do
      assert_raise ArgumentError, ~r/unknown action-schema key/, fn ->
        Wymcp.Router.init(tools: [StrayKeyTool])
      end
    end

    test "raises when an action name contains a newline" do
      assert_raise ArgumentError, ~r/newline/, fn ->
        Wymcp.Router.init(tools: [NewlineActionNameTool])
      end
    end

    test "raises when an action name is not an atom" do
      assert_raise ArgumentError, ~r/must be an atom/, fn ->
        Wymcp.Router.init(tools: [StringActionNameTool])
      end
    end

    @tag doc: """
         Pins D5's scope boundary (2026-07-29-action-description-joiner):
         the newline check covers :description and the action name, never
         the other consumer-authored doc fields. cai's ui tool ships :notes
         containing "\\n\\n## Components\\n\\n" — a check hoisted into a
         shared doc-field helper would fail that tool's next boot. A failure
         here means the check leaked past :description.
         """
    test "accepts an action whose :notes contains newlines" do
      opts = Wymcp.Router.init(tools: [MultilineNotesTool])

      assert Keyword.fetch!(opts, :tools) == [MultilineNotesTool, Wymcp.Help]
    end

    test "raises when an action lacks :properties" do
      assert_raise ArgumentError, ~r/:properties/, fn ->
        Wymcp.Router.init(tools: [MissingPropertiesTool])
      end
    end

    test "raises when :required is not a list of binaries" do
      assert_raise ArgumentError, ~r/required/, fn ->
        Wymcp.Router.init(tools: [BadShapeRequiredTool])
      end
    end

    test "raises when :required references a field absent from :properties" do
      assert_raise ArgumentError, ~r/(unknown|not declared)/i, fn ->
        Wymcp.Router.init(tools: [UnknownFieldRequiredTool])
      end
    end

    test "raises when a :required_one_of group is not a list of binaries" do
      assert_raise ArgumentError, ~r/required_one_of/, fn ->
        Wymcp.Router.init(tools: [BadShapeRequiredOneOfTool])
      end
    end

    test "raises when :required_one_of references a field absent from :properties" do
      assert_raise ArgumentError, ~r/(unknown|not declared)/i, fn ->
        Wymcp.Router.init(tools: [UnknownFieldRequiredOneOfTool])
      end
    end

    test "raises when a :required_one_of group is empty" do
      assert_raise ArgumentError, ~r/empty/i, fn ->
        Wymcp.Router.init(tools: [EmptyGroupTool])
      end
    end

    test "raises when a :required_one_of group is a strict superset of another" do
      assert_raise ArgumentError, ~r/(superset|dead)/i, fn ->
        Wymcp.Router.init(tools: [SupersetGroupTool])
      end
    end

    test "raises when :notes is not a binary" do
      assert_raise ArgumentError, ~r/:notes/, fn ->
        Wymcp.Router.init(tools: [BadNotesTool])
      end
    end

    test "raises when :related is not a list of binaries" do
      assert_raise ArgumentError, ~r/:related/, fn ->
        Wymcp.Router.init(tools: [BadRelatedTool])
      end
    end

    test "raises when :examples is not a list of maps" do
      assert_raise ArgumentError, ~r/:examples/, fn ->
        Wymcp.Router.init(tools: [BadExamplesTool])
      end
    end
  end

  describe "tools/list + tools/call with :required_one_of (end-to-end)" do
    @tag doc: """
         The input schema deliberately omits per-action constraints, so
         required_one_of is NOT advertised in tools/list. Clients learn
         about it via the help tool; enforcement is at dispatch.
         """
    test "tools/list omits anyOf (input schema has no per-action constraints)" do
      session_id = initialize(tools: [OneOfTool])

      body = %{"jsonrpc" => "2.0", "id" => 1, "method" => "tools/list"}
      conn = call_with_session(body, session_id, tools: [OneOfTool])
      resp = JSON.decode!(conn.resp_body)

      tool = Enum.find(resp["result"]["tools"], &(&1["name"] == "oneof"))
      refute Map.has_key?(tool["inputSchema"], "oneOf")
      refute Map.has_key?(tool["inputSchema"]["properties"]["data"], "anyOf")
    end

    @tag doc: """
         The dispatch-level check is the sole enforcer of required_one_of —
         the constraint is invisible in tools/list but a call with no group
         satisfied still gets the structured missing_required_group error.
         """
    test "tools/call with no group satisfied returns missing_required_group" do
      session_id = initialize(tools: [OneOfTool])

      body = %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "tools/call",
        "params" => %{
          "name" => "oneof",
          "arguments" => %{"action" => "identify", "data" => %{"name" => "alpha"}}
        }
      }

      conn = call_with_session(body, session_id, tools: [OneOfTool])
      resp = JSON.decode!(conn.resp_body)

      assert resp["result"]["isError"] == true
      content = resp["result"]["content"] |> hd() |> Map.get("text") |> JSON.decode!()
      assert content["error"] == "missing_required_group"
      assert content["required_one_of"] == [["id"], ["name", "color"]]
    end
  end
end
