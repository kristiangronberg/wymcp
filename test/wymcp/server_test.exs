defmodule Wymcp.ServerTest do
  use ExUnit.Case, async: true

  @moduledoc """
  Tests for the `Wymcp.Server` behaviour.

  The Server behaviour provides lifecycle hooks for consuming applications.
  The two callbacks — `init/2` and `terminate/2` — are both optional. A
  module that `use`s `Wymcp.Server` without overriding either callback gets
  working no-op defaults: `init/2` passes assigns through unchanged and
  `terminate/2` returns `:ok`.

  The behaviour is intentionally minimal — no `handle_request/2` or
  `handle_notification/2`. In wymcp's Plug-based architecture, consuming
  apps already have Plug middleware as an extension point before dispatch.
  Session-aware interception is handled by tools via `ctx.assigns`.
  """

  defmodule TestServer do
    @moduledoc false
    use Wymcp.Server

    @impl Wymcp.Server
    def init(client_info, assigns) do
      {:ok, Map.put(assigns, :client_name, client_info["name"])}
    end
  end

  defmodule RejectingServer do
    @moduledoc false
    use Wymcp.Server

    @impl Wymcp.Server
    def init(_client_info, _assigns) do
      {:error, "not authorized"}
    end
  end

  defmodule DefaultServer do
    @moduledoc false
    use Wymcp.Server
  end

  describe "default callbacks" do
    @tag doc: """
         A server module that uses the behaviour without overriding any
         callbacks must still be callable. The defaults pass assigns
         through unchanged and return :ok for terminate. A failure here
         means the __using__ macro is broken.
         """
    test "init/2 returns {:ok, assigns} unchanged" do
      assert {:ok, %{foo: :bar}} == DefaultServer.init(%{}, %{foo: :bar})
    end

    test "terminate/2 returns :ok" do
      assert :ok == DefaultServer.terminate(:normal, %{})
    end
  end

  describe "custom init/2" do
    @tag doc: """
         A server module can override init/2 to seed session assigns from
         client_info. This is the primary hook for per-client configuration
         like looking up permissions or registering tools.
         """
    test "can seed assigns from client_info" do
      {:ok, assigns} = TestServer.init(%{"name" => "claude"}, %{})
      assert assigns.client_name == "claude"
    end

    test "can reject the session" do
      assert {:error, "not authorized"} = RejectingServer.init(%{}, %{})
    end
  end
end
