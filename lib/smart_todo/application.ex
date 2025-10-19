defmodule SmartTodo.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      SmartTodoWeb.Telemetry,
      SmartTodo.Repo,
      {DNSCluster, query: Application.get_env(:smart_todo, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: SmartTodo.PubSub},
      {Task.Supervisor, name: SmartTodo.Agent.TaskSupervisor},
      # MCP Server
      {Anubis.Server, server: SmartTodo.MCP.Server, name: :smart_todo_mcp, transport: :streamable_http},
      # Start a worker by calling: SmartTodo.Worker.start_link(arg)
      # {SmartTodo.Worker, arg},
      # Start to serve requests, typically the last entry
      SmartTodoWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: SmartTodo.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    SmartTodoWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
