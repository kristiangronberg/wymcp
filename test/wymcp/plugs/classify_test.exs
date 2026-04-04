defmodule Wymcp.Plugs.ClassifyTest do
  use ExUnit.Case, async: true

  @moduledoc """
  Tests for the message classification plug.

  Every incoming POST body is one of three JSON-RPC message types:
  a request (has "method" + "id"), a notification (has "method", no "id"),
  or a response (has "id" + ("result" or "error"), no "method"). The
  classify plug tags the type in conn.assigns so downstream plugs can
  branch on it without repeating the detection logic.

  The classification rules follow JSON-RPC 2.0:
  - Requests: MUST have "method" (string) and "id"
  - Notifications: MUST have "method" (string), MUST NOT have "id"
  - Responses: MUST have "id", MUST NOT have "method", MUST have
    "result" or "error"
  """

  import Plug.Test

  alias Wymcp.Plugs.Classify

  @tag doc: """
       A JSON-RPC request has both "method" and "id". This is the most
       common message type — all tools/list, tools/call, initialize, and
       ping calls are requests. A failure here breaks the entire pipeline.
       """
  test "tags request (has method + id)" do
    conn =
      conn(:post, "/")
      |> Map.put(:body_params, %{"jsonrpc" => "2.0", "id" => 1, "method" => "tools/list"})
      |> Classify.call(Classify.init([]))

    assert conn.assigns[:wymcp_message_type] == :request
  end

  @tag doc: """
       A JSON-RPC notification has "method" but no "id". The server must
       not send a response to notifications. notifications/initialized and
       notifications/cancelled are the primary examples.
       """
  test "tags notification (has method, no id)" do
    conn =
      conn(:post, "/")
      |> Map.put(:body_params, %{"jsonrpc" => "2.0", "method" => "notifications/initialized"})
      |> Classify.call(Classify.init([]))

    assert conn.assigns[:wymcp_message_type] == :notification
  end

  @tag doc: """
       A JSON-RPC result response has "id" and "result" but no "method".
       These are client answers to server-initiated requests like
       sampling/createMessage. A failure here means sampling/elicitation
       responses will be misrouted.
       """
  test "tags result response (has id + result, no method)" do
    conn =
      conn(:post, "/")
      |> Map.put(:body_params, %{
        "jsonrpc" => "2.0",
        "id" => 42,
        "result" => %{"role" => "assistant", "content" => %{"type" => "text", "text" => "hi"}}
      })
      |> Classify.call(Classify.init([]))

    assert conn.assigns[:wymcp_message_type] == :response
  end

  @tag doc: """
       A JSON-RPC error response has "id" and "error" but no "method".
       The client may return an error instead of a result when it cannot
       fulfill a sampling or elicitation request.
       """
  test "tags error response (has id + error, no method)" do
    conn =
      conn(:post, "/")
      |> Map.put(:body_params, %{
        "jsonrpc" => "2.0",
        "id" => 42,
        "error" => %{"code" => -1, "message" => "denied"}
      })
      |> Classify.call(Classify.init([]))

    assert conn.assigns[:wymcp_message_type] == :response
  end

  @tag doc: """
       A body with no "method", no "result", and no "error" is
       unclassifiable. Tag it as :unknown and let downstream plugs
       (Validate) reject it with a proper error.
       """
  test "tags unknown when body has no method, result, or error" do
    conn =
      conn(:post, "/")
      |> Map.put(:body_params, %{"jsonrpc" => "2.0", "id" => 1})
      |> Classify.call(Classify.init([]))

    assert conn.assigns[:wymcp_message_type] == :unknown
  end
end
