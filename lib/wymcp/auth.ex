defmodule Wymcp.Auth do
  @moduledoc """
  Behaviour for MCP request authentication.

  Consuming applications implement this behaviour to validate Bearer tokens
  from the `Authorization` header. The implementation typically:

  1. Extracts the Bearer token from the Authorization header
  2. Validates it (e.g., looks up a hashed token in the database)
  3. On success: adds identity information to `conn.assigns` and returns `{:ok, conn}`
  4. On failure: returns `{:error, message}`

  The auth module is configured via router opts:

      forward "/mcp", Wymcp.Router,
        tools: [MyApp.Tools.Events],
        auth: MyApp.McpAuth

  When no `:auth` option is provided, `Wymcp.Auth.Noop` is used (no authentication).

  ## Example implementation

      defmodule MyApp.McpAuth do
        @behaviour Wymcp.Auth

        @impl Wymcp.Auth
        def authenticate(conn) do
          with ["Bearer " <> token] <- Plug.Conn.get_req_header(conn, "authorization"),
               {:ok, user} <- MyApp.Accounts.fetch_user_by_api_token(token) do
            {:ok, Plug.Conn.assign(conn, :current_user, user)}
          else
            _ -> {:error, "Invalid or missing Bearer token"}
          end
        end
      end

  ## MCP specification notes

  Per the MCP 2025-11-25 spec, servers that require authentication MUST return
  401 with a `WWW-Authenticate: Bearer` header when the token is missing or
  invalid. The `Wymcp.Plugs.Auth` plug handles this response format automatically
  when `c:authenticate/1` returns `{:error, _}`.

  ## Related Modules

  See: `Wymcp.Auth.Noop`, `Wymcp.Plugs.Auth`
  """

  @doc """
  Validates the MCP request's authentication credentials.

  Returns `{:ok, conn}` with any identity information added to assigns,
  or `{:error, message}` if authentication fails.
  """
  @callback authenticate(conn :: Plug.Conn.t()) :: {:ok, Plug.Conn.t()} | {:error, String.t()}
end
