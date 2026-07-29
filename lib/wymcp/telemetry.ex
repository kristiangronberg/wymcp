defmodule Wymcp.Telemetry do
  @moduledoc """
  Telemetry events emitted by Wymcp.

  Consuming applications can attach handlers to these events for
  monitoring, logging, and metrics.

  ## Events

  * `[:wymcp, :session, :start]` — session created during initialize
    - Measurements: `%{system_time: integer()}`
    - Metadata: `%{session_id: String.t(), client_info: map()}`

  * `[:wymcp, :session, :expired]` — session terminated due to idle timeout
    - Measurements: `%{system_time: integer()}`
    - Metadata: `%{session_id: String.t()}`

  * `[:wymcp, :session, :not_found]` — request bearing an unrecognised
    `Mcp-Session-Id` rejected with HTTP 404
    - Measurements: `%{system_time: integer()}`
    - Metadata: `%{session_id: String.t(), request_id: term() | nil,
      method: String.t() | nil}`

  * `[:wymcp, :tool, :start]` — tool execution starting
    - Measurements: `%{system_time: integer()}`
    - Metadata: `%{tool_name: String.t(), action: String.t() | nil,
      session_id: String.t() | nil}`

  * `[:wymcp, :tool, :stop]` — tool execution completed
    - Measurements: `%{duration: integer()}` (native time units)
    - Metadata: `%{tool_name: String.t(), action: String.t() | nil,
      session_id: String.t() | nil, is_error: boolean()}`

  * `[:wymcp, :tool, :error]` — tool raised an exception
    - Measurements: `%{duration: integer()}`
    - Metadata: `%{tool_name: String.t(), action: String.t() | nil,
      session_id: String.t() | nil, request_id: term(),
      exception: String.t(), error: String.t()}`

  For tool events, `action` is the raw `"action"` string from the call
  arguments — what the client actually sent — or `nil` when the arguments
  carried none (a help call's arguments carry the *target* action, which is
  echoed here). `is_error` mirrors the MCP result's `isError` flag for
  tool-returned errors.

  * `[:wymcp, :help, :called]` — the help tool answered a call (including
    error answers). The authoritative introspection record; the same call
    also emits the generic tool events above with `tool_name: "help"`.
    - Measurements: `%{system_time: integer()}`
    - Metadata: `%{tool: String.t() | nil, action: String.t() | nil,
      level: :index | :tool | :action, session_id: String.t() | nil}` —
      `tool`/`action` echo the requested target; `level` is which answer
      level the parameter shape addressed.

  * `[:wymcp, :auth, :reject]` — auth module returned `{:error, reason}`
    - Measurements: `%{system_time: integer()}`
    - Metadata: `%{auth_module: module(), reason: String.t(),
      request_id: term(), method: String.t() | nil}`

  * `[:wymcp, :auth, :error]` — auth module raised an exception
    - Measurements: `%{system_time: integer()}`
    - Metadata: `%{auth_module: module(), exception: String.t(),
      error: String.t(), request_id: term(),
      method: String.t() | nil}`
  """

  @spec emit(atom(), atom(), map(), map()) :: :ok
  def emit(component, event, measurements \\ %{}, metadata \\ %{}) do
    :telemetry.execute(
      [:wymcp, component, event],
      Map.put_new(measurements, :system_time, System.system_time()),
      metadata
    )
  end
end
