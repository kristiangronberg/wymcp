defmodule Wymcp.Auth.Noop do
  @moduledoc """
  Default pass-through authentication — no credentials required.

  This is the default auth module used when no `:auth` option is passed to
  `Wymcp.Router`. It accepts every request unconditionally, matching
  Vancouver's original behavior.

  Appropriate for local development servers or MCP endpoints that are
  already protected by other means (e.g., a reverse proxy).
  """

  @behaviour Wymcp.Auth

  @impl Wymcp.Auth
  @spec authenticate(Plug.Conn.t()) :: {:ok, Plug.Conn.t()}
  def authenticate(%Plug.Conn{} = conn), do: {:ok, conn}
end
