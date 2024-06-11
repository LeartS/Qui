defmodule Qui.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @job_queue_name :main_queue

  @impl true
  def start(_type, _args) do
    children = [
      QuiWeb.Telemetry,
      {DNSCluster, query: Application.get_env(:Qui, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Qui.PubSub},
      {Qui.JobQueue, persistence_filename: "/tmp/Qui_main_queue", name: @job_queue_name},
      Qui.WorkerSupervisor,
      # Start to serve requests, typically the last entry
      QuiWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Qui.Supervisor]
    {:ok, _pid} = res = Supervisor.start_link(children, opts)

    Qui.WorkerSupervisor.start_workers([
      {@job_queue_name, &Qui.Task.process/1, 5}
    ])

    res
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    QuiWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  def job_queue_name(), do: @job_queue_name
end
