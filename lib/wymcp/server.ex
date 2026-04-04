defmodule Wymcp.Server do
  @moduledoc """
  Behaviour for consuming applications to hook into the MCP session lifecycle.

  Implement this behaviour to run custom logic when a session becomes ready
  (after the `notifications/initialized` handshake) and when it shuts down.

  Both callbacks are optional — `use Wymcp.Server` provides working defaults.

  ## Design decisions

  Only two lifecycle hooks are provided: `init/2` and `terminate/2`. There
  is deliberately no `handle_request/2` callback. In wymcp's Plug-based
  architecture, consuming apps add Plug middleware before
  `forward "/mcp", Wymcp.Router` for per-request interception. This keeps
  request-level concerns (logging, rate limiting, metrics) in the Plug
  pipeline where they compose naturally, and reserves this behaviour for
  session-scoped lifecycle events. A `handle_request/2` callback can be
  added non-breakingly later if a concrete use case emerges.

  ### Per-request hooks via Plug middleware

  For request-level concerns like logging, add a plug before the router
  in your Phoenix endpoint or pipeline:

      # lib/my_app/plugs/mcp_logger.ex
      defmodule MyApp.Plugs.McpLogger do
        @behaviour Plug

        require Logger

        @impl Plug
        def init(opts), do: opts

        @impl Plug
        def call(conn, _opts) do
          method = conn.body_params["method"]
          start = System.monotonic_time()

          Plug.Conn.register_before_send(conn, fn conn ->
            duration = System.monotonic_time() - start
            ms = System.convert_time_unit(duration, :native, :millisecond)
            Logger.info("MCP \#{method} completed in \#{ms}ms (status=\#{conn.status})")
            conn
          end)
        end
      end

      # lib/my_app_web/router.ex
      pipeline :mcp do
        plug MyApp.Plugs.McpLogger
      end

      scope "/mcp" do
        pipe_through :mcp
        forward "/", Wymcp.Router,
          tools: [MyApp.Tools.Events],
          server: MyApp.McpServer
      end

  Session-aware data (like the authenticated user) is available in
  `conn.assigns` from earlier plugs, or in `ctx.assigns` inside tools.

  `init/2` is the primary extension point for per-client configuration.
  The assigns map arrives with `session_pid` pre-seeded — following the
  Phoenix pattern where `socket.assigns` carries process references
  (like `transport_pid` in Channel). The typical pattern: inspect
  `client_info`, look up the authenticated user's permissions (the auth
  plug already stored the token in assigns), and call
  `Wymcp.Session.register_tool/2` for each authorized tool.

  `terminate/2` runs from the session GenServer's `terminate/2` callback,
  so it fires on normal shutdown (idle timeout, client DELETE) and abnormal
  shutdown (crash, supervisor restart).

  ## Usage

      defmodule MyApp.McpServer do
        use Wymcp.Server

        @impl Wymcp.Server
        def init(client_info, assigns) do
          user = MyApp.Auth.lookup_user(assigns[:auth_token])

          for tool <- MyApp.Permissions.tools_for(user) do
            Wymcp.Session.register_tool(assigns.session_pid, tool)
          end

          {:ok, Map.put(assigns, :user, user)}
        end

        @impl Wymcp.Server
        def terminate(_reason, assigns) do
          MyApp.Audit.log_session_end(assigns[:user])
          :ok
        end
      end

  ## Related Modules

  See: `Wymcp.Session`

  ## Tests

  See: `Wymcp.ServerTest`
  """

  @callback init(client_info :: map(), assigns :: map()) ::
              {:ok, assigns :: map()} | {:error, reason :: term()}

  @callback terminate(reason :: term(), assigns :: map()) :: :ok

  @optional_callbacks [init: 2, terminate: 2]

  defmacro __using__(_opts) do
    quote do
      @behaviour Wymcp.Server

      @impl Wymcp.Server
      @spec init(map(), map()) :: {:ok, map()} | {:error, term()}
      def init(_client_info, assigns), do: {:ok, assigns}

      @impl Wymcp.Server
      @spec terminate(term(), map()) :: :ok
      def terminate(_reason, _assigns), do: :ok

      defoverridable init: 2, terminate: 2
    end
  end
end
