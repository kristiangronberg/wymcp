defmodule Wymcp.Application do
  @moduledoc false
  use Application

  @impl Application
  def start(_type, _args) do
    children = [
      {Registry, keys: :unique, name: Wymcp.Session.Registry},
      Wymcp.Session.Supervisor,
      {Task.Supervisor, name: Wymcp.StreamSupervisor}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Wymcp.Supervisor)
  end
end
