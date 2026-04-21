defmodule KomunBackend.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      KomunBackendWeb.Telemetry,
      KomunBackend.Repo,
      {DNSCluster, query: Application.get_env(:komun_backend, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: KomunBackend.PubSub},
      # Redis connection pool
      {Redix, host: System.get_env("REDIS_HOST", "localhost"),
              port: String.to_integer(System.get_env("REDIS_PORT", "6379")),
              name: :redix},
      # Fire-and-forget tasks (AI triage, notifications, etc.)
      {Task.Supervisor, name: KomunBackend.TaskSupervisor},
      # Background jobs
      {Oban, Application.fetch_env!(:komun_backend, Oban)},
      KomunBackendWeb.Endpoint
    ]

    opts = [strategy: :one_for_one, name: KomunBackend.Supervisor]
    Supervisor.start_link(children, opts)
  end

  @impl true
  def config_change(changed, _new, removed) do
    KomunBackendWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
