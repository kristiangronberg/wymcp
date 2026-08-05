defmodule Wymcp.Auth do
  @moduledoc """
  The consumer contract for MCP request authentication: `authenticate/1`
  validates the request's Bearer token and adds identity to `conn.assigns`.

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

  `authenticate/1` runs once per request on every non-fallthrough route —
  POST, GET (the SSE stream), and DELETE. Authenticate from connection
  data such as the `Authorization` header, never from the request body:
  on GET and DELETE no body is parsed, so `conn.body_params` is
  unfetched. Auth is per-request only — an already-open SSE stream lives
  until its session ends, and a reconnect is a fresh GET that
  re-authenticates naturally.

  ## Example implementation

      defmodule MyApp.McpAuth do
        @behaviour Wymcp.Auth

        @impl Wymcp.Auth
        def authenticate(conn) do
          case Plug.Conn.get_req_header(conn, "authorization") do
            [header] ->
              with "Bearer " <> token <- header,
                   {:ok, user} <- MyApp.Accounts.fetch_user_by_api_token(token) do
                {:ok, Plug.Conn.assign(conn, :current_user, user)}
              else
                _ -> {:error, "Invalid Bearer token"}
              end

            [] ->
              {:error, "Missing Authorization header"}

            [_, _ | _] ->
              {:error, "Duplicated Authorization header. Send exactly one Authorization header."}
          end
        end
      end

  The three-way read is the point. `Plug.Conn.get_req_header/2` returns
  *every* value of a repeated header, so a two-way `["Bearer " <> token]`
  match folds a duplicated `Authorization` into the same answer as a missing
  one — a wrong message, not merely a vague one, and it is the arm a
  copied-and-trimmed example loses first.

  `Authorization` is the one singleton header (`docs/glossary.md`) wymcp
  cannot validate centrally: `Wymcp.Plugs.SingletonHeaders` runs *after* this
  callback, because a 401 must win over any answer that depends on reading
  the request further. A duplicated `Authorization` therefore reaches
  `c:authenticate/1` untouched, and this example is the only leverage wymcp
  has on it.

  ## MCP specification notes

  Per the MCP 2025-11-25 spec, servers that require authentication MUST return
  401 with a `WWW-Authenticate: Bearer` challenge when the token is missing or
  invalid. The `Wymcp.Plugs.Auth` plug handles this response format automatically
  when `c:authenticate/1` returns `{:error, _}`.
  """

  @doc """
  Validates the MCP request's authentication credentials.

  Returns `{:ok, conn}` with any identity information added to assigns,
  or `{:error, message}` if authentication fails.
  """
  @callback authenticate(conn :: Plug.Conn.t()) :: {:ok, Plug.Conn.t()} | {:error, String.t()}
end
