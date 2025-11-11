defmodule SmartTodo.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  @llm_provider Application.compile_env(:smart_todo, :llm_provider, :gemini)

  def start(_type, _args) do
    children =
      [
        SmartTodoWeb.Telemetry,
        SmartTodo.Repo,
        {DNSCluster, query: Application.get_env(:smart_todo, :dns_cluster_query) || :ignore},
        {Phoenix.PubSub, name: SmartTodo.PubSub},
        {Task.Supervisor, name: SmartTodo.Agent.TaskSupervisor}
      ] ++ llm_children() ++ [SmartTodoWeb.Endpoint]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: SmartTodo.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp llm_children do
    case @llm_provider do
      :gemma3_local -> [SmartTodo.Agent.LocalLlm]
      _ -> []
    end
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    SmartTodoWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
