defmodule Airo.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      AiroWeb.Telemetry,
      # Vault before Repo: encrypted Ecto types crypto through it, including
      # during migrations/seeds.
      Airo.Vault,
      Airo.Repo,
      {DNSCluster, query: Application.get_env(:airo, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Airo.PubSub},
      # Shared HTTP transport for upstream provider calls. Finch pools
      # connections per {scheme, host, port}, so each provider base_url gets its
      # own connection pool (DESIGN §13).
      {Finch, name: Airo.Finch, pools: Airo.Transport.finch_pools()},
      # Runtime ETS tables (health snapshots, round-robin counters), then the
      # health prober that populates them.
      Airo.Runtime.Store,
      Airo.Health.Prober,
      # Start a worker by calling: Airo.Worker.start_link(arg)
      # {Airo.Worker, arg},
      # Start to serve requests, typically the last entry
      AiroWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Airo.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    AiroWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
