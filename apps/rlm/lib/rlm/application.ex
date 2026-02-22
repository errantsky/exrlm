defmodule RLM.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Registry, keys: :unique, name: RLM.Registry},
      {Phoenix.PubSub, name: RLM.PubSub},
      {Task.Supervisor, name: RLM.TaskSupervisor},
      {DynamicSupervisor, name: RLM.RunSup, strategy: :one_for_one},
      {DynamicSupervisor, name: RLM.EventStore, strategy: :one_for_one},
      {RLM.Telemetry, []},
      {RLM.TraceStore, []},
      {RLM.EventLog.Sweeper, []}
    ]

    opts = [strategy: :one_for_one, name: RLM.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
