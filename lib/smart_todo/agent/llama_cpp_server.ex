defmodule SmartTodo.Agent.LlamaCppServer do
  @moduledoc """
  Manages health checks for the llama.cpp server for local Gemma 3 model inference.

  This GenServer:
  - Assumes llama.cpp server is already running (started by entrypoint script)
  - Provides health checks to verify server availability
  - Acts as a readiness indicator for the application

  Note: Model download, compilation, and server startup are handled by the
  entrypoint script before the Elixir application starts.
  """

  use GenServer
  require Logger

  @health_check_interval 5_000  # Check every 5 seconds during startup

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Get the base URL for the llama.cpp server
  """
  def base_url do
    config = Application.get_env(:smart_todo, :llm, [])
    port = Keyword.get(config, :local_server_port, 8080)
    "http://localhost:#{port}"
  end

  @doc """
  Check if the server is ready to accept requests
  """
  def ready? do
    case GenServer.call(__MODULE__, :status, 5000) do
      :ready -> true
      _ -> false
    end
  catch
    :exit, _ -> false
  end

  # Server callbacks

  @impl true
  def init(_opts) do
    # Only monitor if configured for local provider
    config = Application.get_env(:smart_todo, :llm, [])
    provider = Keyword.get(config, :provider, :gemini)

    if provider == :local do
      Logger.info("Connecting to llama.cpp server started by entrypoint script")
      # Server should already be running, verify with health check
      send(self(), :verify_server)
      {:ok, %{status: :connecting}}
    else
      Logger.info("Skipping llama.cpp server monitoring (provider: #{provider})")
      {:ok, %{status: :disabled}}
    end
  end

  @impl true
  def handle_info(:verify_server, state) do
    case check_health() do
      :ok ->
        Logger.info("✓ Successfully connected to llama.cpp server")
        {:noreply, %{state | status: :ready}}

      :not_ready ->
        Logger.warning("llama.cpp server not yet ready, will retry...")
        schedule_health_check()
        {:noreply, %{state | status: :connecting}}
    end
  end

  @impl true
  def handle_info(:health_check, %{status: :connecting} = state) do
    case check_health() do
      :ok ->
        Logger.info("✓ llama.cpp server is now ready")
        {:noreply, %{state | status: :ready}}

      :not_ready ->
        schedule_health_check()
        {:noreply, state}
    end
  end

  @impl true
  def handle_info(:health_check, state) do
    # Already ready, no need to check
    {:noreply, state}
  end

  @impl true
  def handle_call(:status, _from, %{status: status} = state) do
    {:reply, status, state}
  end

  @impl true
  def terminate(_reason, _state) do
    # Server is managed by entrypoint script, not by this GenServer
    :ok
  end

  # Private functions

  defp check_health do
    url = "#{base_url()}/health"

    case Req.get(url, receive_timeout: 2000, retry: false) do
      {:ok, %Req.Response{status: 200}} -> :ok
      _ -> :not_ready
    end
  rescue
    _ -> :not_ready
  end

  defp schedule_health_check do
    Process.send_after(self(), :health_check, @health_check_interval)
  end
end
