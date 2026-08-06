defmodule Wymcp.Plugs.ValidateTest do
  @moduledoc """
  The plug is called directly with a hand-built conn: on the wire it runs after
  Plug.Parsers and Wymcp.Plugs.Classify, so these tests set :body_params and
  :wymcp_message_type themselves. The router-driven composition — letting
  Classify do the tagging — is covered in router_test.exs.
  """

  use ExUnit.Case, async: true

  import Plug.Test
  import Plug.Conn

  alias Wymcp.Plugs.Validate

  @tag doc: """
       Spec D5. A client holding a valid session that POSTs a truncated answer
       classifies :unknown, passes Wymcp.Plugs.Session, and fails schema
       validation here — so before the fix this 400 handed back an id the
       server had minted. A failure means the envelope reached for
       request["id"] again; note the whole body still travels under
       data.original_request, so nothing diagnostic is lost.
       """
  test "an unclassifiable body's 400 carries a null id" do
    conn =
      conn(:post, "/")
      |> Map.put(:body_params, %{"jsonrpc" => "2.0", "id" => 42})
      |> assign(:wymcp_message_type, :unknown)
      |> Validate.call(Validate.init([]))

    assert conn.status == 400
    body = JSON.decode!(conn.resp_body)
    assert body["id"] == nil
    assert body["error"]["data"]["original_request"] == %{"jsonrpc" => "2.0", "id" => 42}
  end

  @tag doc: """
       The other side of D5: Wymcp.Plugs.Classify's :request test is only
       "binary method + id present", looser than schema validity, so a
       recognisable malformed request — here a wrong jsonrpc version — keeps
       its id and stays correlatable. Only bodies where request and response
       are indistinguishable lose it.
       """
  test "a recognisable malformed request keeps its id" do
    conn =
      conn(:post, "/")
      |> Map.put(:body_params, %{"jsonrpc" => "1.0", "id" => 5, "method" => "ping"})
      |> assign(:wymcp_message_type, :request)
      |> Validate.call(Validate.init([]))

    assert conn.status == 400
    assert JSON.decode!(conn.resp_body)["id"] == 5
  end
end
