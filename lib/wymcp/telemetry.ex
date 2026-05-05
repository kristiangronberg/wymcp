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
    - Metadata: `%{tool_name: String.t(), session_id: String.t() | nil}`

  * `[:wymcp, :tool, :stop]` — tool execution completed
    - Measurements: `%{duration: integer()}` (native time units)
    - Metadata: `%{tool_name: String.t(), session_id: String.t() | nil}`

  * `[:wymcp, :tool, :error]` — tool raised an exception
    - Measurements: `%{duration: integer()}`
    - Metadata: `%{tool_name: String.t(), session_id: String.t() | nil,
      request_id: term(), exception: String.t(), error: String.t()}`

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
