defmodule SmartTodo.Agent.LlamaCppServer do
  @moduledoc """
  Manages the llama.cpp server process for local Gemma 3 model inference.

  This GenServer:
  - Downloads the Gemma 3 12B GGUF model if not present
  - Starts llama.cpp server via Port
  - Monitors the server process
  - Provides health checks
  """

  use GenServer
  require Logger

  @llama_cpp_repo "https://github.com/ggerganov/llama.cpp"
  @startup_timeout 120_000  # 2 minutes to start server
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
    # Only start if configured for local provider
    config = Application.get_env(:smart_todo, :llm, [])
    provider = Keyword.get(config, :provider, :gemini)

    if provider == :local do
      Logger.info("Initializing llama.cpp server for local Gemma 3 model")
      send(self(), :initialize)
      {:ok, %{status: :initializing, port: nil, model_path: nil}}
    else
      Logger.info("Skipping llama.cpp server (provider: #{provider})")
      {:ok, %{status: :disabled, port: nil, model_path: nil}}
    end
  end

  @impl true
  def handle_info(:initialize, state) do
    case setup_and_start() do
      {:ok, port, model_path} ->
        Logger.info("llama.cpp server started successfully")
        schedule_health_check()
        {:noreply, %{state | status: :starting, port: port, model_path: model_path}}

      {:error, reason} ->
        Logger.error("Failed to start llama.cpp server: #{inspect(reason)}")
        {:stop, {:shutdown, reason}, state}
    end
  end

  @impl true
  def handle_info(:health_check, %{status: :starting} = state) do
    case check_health() do
      :ok ->
        Logger.info("llama.cpp server is ready")
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
  def handle_info({port, {:data, data}}, %{port: port} = state) do
    Logger.debug("llama.cpp output: #{data}")
    {:noreply, state}
  end

  @impl true
  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    Logger.error("llama.cpp server exited with status #{status}")
    {:stop, {:shutdown, :server_crashed}, state}
  end

  @impl true
  def handle_call(:status, _from, %{status: status} = state) do
    {:reply, status, state}
  end

  @impl true
  def terminate(reason, %{port: port} = _state) when not is_nil(port) do
    Logger.info("Shutting down llama.cpp server: #{inspect(reason)}")
    Port.close(port)
    :ok
  end

  @impl true
  def terminate(_reason, _state), do: :ok

  # Private functions

  defp setup_and_start do
    with {:ok, model_path} <- ensure_model_downloaded(),
         {:ok, llama_server_path} <- ensure_llama_cpp_built(),
         {:ok, port} <- start_server(llama_server_path, model_path) do
      {:ok, port, model_path}
    end
  end

  defp ensure_model_downloaded do
    config = Application.get_env(:smart_todo, :llm, [])
    model_dir = Keyword.get(config, :local_model_path, "priv/models")
    model_url = Keyword.get(config, :local_model_url)

    model_path = Path.join(model_dir, "gemma-3-12b-it-Q4_K_M.gguf")

    if File.exists?(model_path) do
      Logger.info("Model already exists at #{model_path}")
      {:ok, model_path}
    else
      Logger.info("Downloading model from #{model_url}")
      File.mkdir_p!(model_dir)

      case download_file(model_url, model_path) do
        :ok -> {:ok, model_path}
        {:error, reason} -> {:error, {:model_download_failed, reason}}
      end
    end
  end

  defp download_file(url, destination) do
    # Use Req to download the file with progress
    Logger.info("Starting download to #{destination}")

    case Req.get(url, into: File.stream!(destination)) do
      {:ok, %Req.Response{status: 200}} ->
        Logger.info("Download completed successfully")
        :ok

      {:ok, %Req.Response{status: status}} ->
        File.rm(destination)
        {:error, {:http_error, status}}

      {:error, reason} ->
        File.rm_rf(destination)
        {:error, reason}
    end
  end

  defp ensure_llama_cpp_built do
    # Use absolute path that matches Docker image structure
    # In Docker, llama.cpp is pre-built and copied to /app/priv/llama.cpp
    llama_cpp_dir = "/app/priv/llama.cpp"
    # llama-server is built in the build/bin directory
    llama_server = Path.join([llama_cpp_dir, "build", "bin", "llama-server"])

    if File.exists?(llama_server) do
      Logger.info("Using pre-built llama.cpp at #{llama_server}")
      {:ok, llama_server}
    else
      Logger.info("llama.cpp not found at #{llama_server}, cloning and building...")
      build_llama_cpp(llama_cpp_dir, llama_server)
    end
  end

  defp build_llama_cpp(llama_cpp_dir, llama_server) do
    File.mkdir_p!("priv")

    steps = [
      {"Clone llama.cpp", "git", ["clone", "--depth", "1", @llama_cpp_repo, llama_cpp_dir]},
      {"Build llama.cpp", "cmake", ["-B", "build", "-S", ".", "-DCMAKE_BUILD_TYPE=Release"], llama_cpp_dir},
      {"Compile llama.cpp", "cmake", ["--build", "build", "--config", "Release", "--target", "llama-server"], llama_cpp_dir}
    ]

    Enum.reduce_while(steps, :ok, fn step, _acc ->
      {desc, cmd, args, working_dir} = case step do
        {d, c, a, wd} -> {d, c, a, wd}
        {d, c, a} -> {d, c, a, nil}
      end

      Logger.info("#{desc}...")

      opts = if working_dir, do: [cd: working_dir, stderr_to_stdout: true], else: [stderr_to_stdout: true]

      case System.cmd(cmd, args, opts) do
        {_output, 0} ->
          {:cont, :ok}

        {output, status} ->
          Logger.error("#{desc} failed (status #{status}): #{output}")
          {:halt, {:error, {:build_failed, desc}}}
      end
    end)

    if File.exists?(llama_server) do
      {:ok, llama_server}
    else
      {:error, :llama_server_not_found}
    end
  end

  defp start_server(llama_server_path, model_path) do
    config = Application.get_env(:smart_todo, :llm, [])
    port = Keyword.get(config, :local_server_port, 8080)

    # Start llama-server with appropriate flags
    args = [
      "--model", model_path,
      "--port", to_string(port),
      "--ctx-size", "8192",
      "--n-predict", "2048",
      "--threads", "3"
    ]

    Logger.info("Starting llama-server: #{llama_server_path} #{Enum.join(args, " ")}")

    port_obj = Port.open(
      {:spawn_executable, llama_server_path},
      [:binary, :exit_status, args: args]
    )

    {:ok, port_obj}
  rescue
    error ->
      {:error, {:port_open_failed, error}}
  end

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
