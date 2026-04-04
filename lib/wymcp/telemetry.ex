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

  * `[:wymcp, :tool, :start]` — tool execution starting
    - Measurements: `%{system_time: integer()}`
    - Metadata: `%{tool_name: String.t(), session_id: String.t() | nil}`

  * `[:wymcp, :tool, :stop]` — tool execution completed
    - Measurements: `%{duration: integer()}` (native time units)
    - Metadata: `%{tool_name: String.t(), session_id: String.t() | nil}`

  * `[:wymcp, :tool, :error]` — tool raised an exception
    - Measurements: `%{duration: integer()}`
    - Metadata: `%{tool_name: String.t(), error: String.t()}`
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
