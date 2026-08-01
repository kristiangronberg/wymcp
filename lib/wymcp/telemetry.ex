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
      session_id: String.t() | nil, is_error: boolean(),
      error_kind: :dispatch | :tool | nil}`

  * `[:wymcp, :tool, :error]` — tool raised an exception
    - Measurements: `%{duration: integer()}`
    - Metadata: `%{tool_name: String.t(), action: String.t() | nil,
      session_id: String.t() | nil, request_id: term(),
      exception: String.t(), error: String.t()}`

  For tool events, `action` is the raw `"action"` string from the call
  arguments — what the client actually sent — or `nil` when the arguments
  carried none (a help call's arguments carry the *target* action, which is
  echoed here). On `[:wymcp, :tool, :stop]`, `is_error` mirrors the MCP
  result's `isError` flag for tool-returned errors, and `error_kind`
  classifies that error's origin: `:dispatch` — a gate rejected the call
  before the tool's action handler ran (wymcp's dispatch gate, or a
  hand-written `run/2` classifying its own gate rejection); `:tool` — the
  tool ran and answered with an error.
  `error_kind` is `nil` exactly when `is_error` is `false`. Both keys are
  `:stop`-only — neither `[:wymcp, :tool, :start]` nor
  `[:wymcp, :tool, :error]` carries them, so read them with `Map.get/3`
  from a handler attached to more than one of these events. The
  `error_kind` vocabulary may grow; match it with a fallback clause, never
  exhaustively.

  * `[:wymcp, :help, :called]` — the help tool answered a call (including
    error answers), emitted after the answer is resolved so the metadata
    carries the outcome. The authoritative introspection record; the same
    call also emits the generic tool events above with
    `tool_name: "help"`. A raise inside help drops this event — the call
    still surfaces as `[:wymcp, :tool, :error]` with `tool_name: "help"`
    (the target tool echo is lost; `action` still carries the target
    action, per the note above). A `Wymcp.Session.get_tools/1` *exit* —
    a dead session process, or a `GenServer.call` timeout — is not a
    raise, so the tool layer's `rescue` does not catch it and neither this
    event nor `[:wymcp, :tool, :error]` fires; only
    `[:wymcp, :tool, :start]` records the attempt. The window is narrow:
    the call layer resolves the same session's tools before help runs, so
    a session that is already gone fails there first.
    - Measurements: `%{system_time: integer()}`
    - Metadata: `%{tool: String.t() | nil, action: String.t() | nil,
      level: :index | :tool | :action, session_id: String.t() | nil,
      is_error: boolean()}` — `tool`/`action` echo the requested target
      exactly as sent, even when they name nothing (a probe for a
      nonexistent target is itself signal); `level` is which answer level
      the parameter shape addressed; `is_error` is whether the answer was
      an error answer.

  * `[:wymcp, :auth, :reject]` — auth module returned `{:error, reason}`
    - Measurements: `%{system_time: integer()}`
    - Metadata: `%{auth_module: module(), reason: String.t(),
      request_id: term(), method: String.t() | nil}`

  * `[:wymcp, :auth, :error]` — auth module raised an exception
    - Measurements: `%{system_time: integer()}`
    - Metadata: `%{auth_module: module(), exception: String.t(),
      error: String.t(), request_id: term(),
      method: String.t() | nil}`

  * `[:wymcp, :server, :reject]` — the consumer's `c:Wymcp.Server.init/2`
    returned `{:error, reason}`; the session is terminated and the
    `notifications/initialized` request answered with a JSON-RPC
    internal_error
    - Measurements: `%{system_time: integer()}`
    - Metadata: `%{server: module(), session_id: String.t(),
      reason: term(), request_id: term() | nil}` — `reason` is the raw
      term the callback returned

  * `[:wymcp, :server, :error]` — the consumer's `c:Wymcp.Server.init/2`
    raised, exited, or threw; treated as a rejection (same session
    termination and internal_error answer)
    - Measurements: `%{system_time: integer()}`
    - Metadata: `%{server: module(), session_id: String.t(),
      exception: String.t(), error: String.t(), request_id: term() | nil}`
      — `exception` is the exception struct name for a raise, or
      `"exit"` / `"throw"` for the other kinds
  """

  def emit(component, event, measurements \\ %{}, metadata \\ %{}) do
    :telemetry.execute(
      [:wymcp, component, event],
      Map.put_new(measurements, :system_time, System.system_time()),
      metadata
    )
  end
end
