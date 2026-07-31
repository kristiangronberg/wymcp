defmodule Wymcp.ServerTest do
  use ExUnit.Case, async: true

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
