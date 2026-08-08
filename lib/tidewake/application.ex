defmodule Tidewake.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      TidewakeWeb.Telemetry,
      Tidewake.Repo,
      {Oban, Application.fetch_env!(:tidewake, Oban)},
      {DNSCluster, query: Application.get_env(:tidewake, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Tidewake.PubSub},
      # Start a worker by calling: Tidewake.Worker.start_link(arg)
      # {Tidewake.Worker, arg},
      # Start to serve requests, typically the last entry
      TidewakeWeb.Endpoint
    ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Tidewake.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    TidewakeWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
