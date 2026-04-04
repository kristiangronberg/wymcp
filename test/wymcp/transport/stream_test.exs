defmodule Wymcp.Transport.StreamTest do
  use ExUnit.Case, async: true

  @moduledoc """
  Tests for the SSE stream module.

  Stream wraps Plug.Conn chunked responses with SSE formatting. Since
  we can't fully test chunked responses with Plug.Test (no adapter),
  we test the open/1 function for header setup.
  """

  import Plug.Test

  alias Wymcp.Transport.Stream

  describe "open/1" do
    test "sets content-type to text/event-stream and cache-control to no-cache" do
      conn = conn(:get, "/")
      opened = Stream.open(conn)

      assert opened.status == 200
      assert opened.state == :chunked

      {_, content_type} =
        Enum.find(opened.resp_headers, fn {k, _} -> k == "content-type" end)

      assert content_type =~ "text/event-stream"

      {_, cache_control} =
        Enum.find(opened.resp_headers, fn {k, _} -> k == "cache-control" end)

      assert cache_control == "no-cache"
    end
  end
end
