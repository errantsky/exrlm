defmodule RLM.Application do
  @moduledoc false
  use Application

  use Boundary,
    top_level?: true,
    deps: [RLM, RLMWeb]

  @impl true
  def start(_type, _args) do
    children = [
      # Core engine
      {Registry, keys: :unique, name: RLM.Registry},
      {Phoenix.PubSub, name: RLM.PubSub},
      {Task.Supervisor, name: RLM.TaskSupervisor},
      {DynamicSupervisor, name: RLM.RunSup, strategy: :one_for_one},
      {DynamicSupervisor, name: RLM.EventStore, strategy: :one_for_one},
      {RLM.Telemetry, []},
      {RLM.TraceStore, []},
      {RLM.EventLog.Sweeper, []},
      # Web dashboard
      RLMWeb.Telemetry,
      {DNSCluster, query: Application.get_env(:rlm, :dns_cluster_query) || :ignore},
      RLMWeb.Endpoint
    ]

    opts = [strategy: :one_for_one, name: RLM.Supervisor]
    Supervisor.start_link(children, opts)
  end

  @impl true
  def config_change(changed, _new, removed) do
    RLMWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
