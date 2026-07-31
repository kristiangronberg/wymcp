defmodule Wymcp.Transport.StreamTest do
  @moduledoc """
  Chunked responses can't be fully exercised with Plug.Test (no adapter
  support for reading chunks back), so these tests cover `open/1`'s
  header setup only.
  """

  use ExUnit.Case, async: true

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
