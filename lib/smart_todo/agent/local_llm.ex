defmodule SmartTodo.Agent.LocalLlm do
  @moduledoc """
  Manages lifecycle and HTTP interaction for a local llama.cpp server
  running the Gemma 3 12B model.

  When the project is compiled with the `:gemma3_local` provider the
  supervisor starts this module. It ensures the model file is present,
  launches the llama.cpp server, waits for it to become reachable, and
  exposes a chat helper compatible with the rest of the agent pipeline.
  """

  use GenServer
  require Logger

  alias Req

  @provider Application.compile_env(:smart_todo, :llm_provider, :gemini)
  @project_root Path.expand("../../..", __DIR__)

  @doc """
  Starts the local LLM manager.
  """
  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  @doc """
  Returns true when the application was compiled for the local provider.
  """
  def local_provider?, do: @provider == :gemma3_local

  @doc """
  Ensures the llama.cpp server is running and ready to accept requests.
  """
  def ensure_server do
    if local_provider?() do
      timeout = config() |> Map.get(:startup_timeout, 180_000)

      try do
        GenServer.call(__MODULE__, :ensure_server, timeout)
      catch
        :exit, {:noproc, _} -> {:error, :not_started}
      end
    else
      :ok
    end
  end

  @doc """
  Sends the chat payload to the local server using the OpenAI-compatible
  endpoint exposed by llama.cpp.
  """
  def chat(payload, opts \\ []) do
    with :ok <- ensure_server(),
         {:ok, request} <- build_chat_request(payload) do
      do_chat(request, opts)
    end
  end

  @impl true
  def init(_opts) do
    {:ok, %{server_pid: nil, server_ref: nil, config: config()}}
  end

  @impl true
  def handle_call(:ensure_server, _from, %{server_pid: pid} = state)
      when is_pid(pid) and Process.alive?(pid) do
    {:reply, :ok, state}
  end

  def handle_call(:ensure_server, _from, state) do
    config = state.config || config()

    with :ok <- ensure_model(config),
         {:ok, pid} <- start_server(config),
         ref <- Process.monitor(pid),
         :ok <- wait_until_ready(config) do
      {:reply, :ok, %{state | server_pid: pid, server_ref: ref, config: config}}
    else
      {:error, reason} = error ->
        {:reply, error, state}
    end
  end

  @impl true
  def handle_info({:DOWN, ref, :process, pid, reason}, %{server_pid: pid, server_ref: ref} = state) do
    Logger.error("Local LLM server exited: #{inspect(reason)}")
    {:noreply, %{state | server_pid: nil, server_ref: nil}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp config do
    defaults = default_config()

    Application.get_env(:smart_todo, :local_llm, [])
    |> Map.new()
    |> Map.merge(defaults, fn _key, value, _default -> value end)
  end

  defp default_config do
    model_dir = Path.join(@project_root, "priv/local_llm")
    model_file = "gemma-3-12b-it-Q4_K_M.gguf"
    model_path = Path.expand(Path.join(model_dir, model_file))

    %{
      model_path: model_path,
      model_name: Path.rootname(Path.basename(model_path)),
      download_url:
        "https://huggingface.co/google/gemma-3-12b-it-GGUF/resolve/main/gemma-3-12b-it-Q4_K_M.gguf?download=1",
      server_host: "127.0.0.1",
      server_port: 11_434,
      server_binary: Path.expand("../llama.cpp/server", @project_root),
      extra_server_args: [],
      startup_timeout: 180_000,
      receive_timeout: :timer.minutes(10),
      health_path: "/health"
    }
  end

  defp ensure_model(%{model_path: path} = config),
    do: ensure_model(path, Map.get(config, :download_url))

  defp ensure_model(path, _url) when is_binary(path) and File.exists?(path), do: :ok

  defp ensure_model(path, nil) do
    {:error, :missing_download_url}
  end

  defp ensure_model(path, url) do
    File.mkdir_p!(Path.dirname(path))
    tmp = path <> ".download"

    case File.open(tmp, [:write, :binary]) do
      {:ok, device} ->
        try do
          Logger.info("Downloading Gemma 3 model from #{url}")

          case Req.get(url: url, into: device) do
            {:ok, %Req.Response{status: 200}} ->
              File.close(device)
              File.rename!(tmp, path)
              :ok

            {:ok, %Req.Response{status: status}} ->
              File.close(device)
              File.rm(tmp)
              {:error, {:download_failed, status}}

            {:error, reason} ->
              File.close(device)
              File.rm(tmp)
              {:error, reason}
          end
        rescue
          exception ->
            File.close(device)
            File.rm(tmp)
            reraise(exception, __STACKTRACE__)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp start_server(%{server_binary: nil}) do
    {:error, :missing_server_binary}
  end

  defp start_server(%{server_binary: path} = config) do
    if File.exists?(path) do
      args = server_args(config)
      Logger.info("Starting llama.cpp server: #{path} #{Enum.join(args, " ")}")

      Task.start_link(fn ->
        System.cmd(path, args,
          into: IO.stream(:stdio, :line),
          stderr_to_stdout: true
        )
      end)
    else
      {:error, {:missing_server_binary, path}}
    end
  end

  defp server_args(config) do
    base = [
      "--model",
      config.model_path,
      "--host",
      config.server_host,
      "--port",
      Integer.to_string(config.server_port),
      "--api"
    ]

    base ++ Map.get(config, :extra_server_args, [])
  end

  defp wait_until_ready(config, attempts \\ 30)

  defp wait_until_ready(_config, 0), do: {:error, :startup_timeout}

  defp wait_until_ready(config, attempts) do
    case ping_server(config) do
      :ok -> :ok
      {:error, reason} ->
        Process.sleep(500)
        Logger.debug("Local LLM not ready yet: #{inspect(reason)}")
        wait_until_ready(config, attempts - 1)
    end
  end

  defp ping_server(%{health_path: path} = config) when is_binary(path) and path != "" do
    url = server_base_url(config) <> path

    case Req.get(url: url, receive_timeout: 2_000) do
      {:ok, %Req.Response{status: status}} when status in 200..299 -> :ok
      {:ok, %Req.Response{status: 404}} -> :ok
      {:ok, response} -> {:error, {:unhealthy, response.status}}
      {:error, reason} -> {:error, reason}
    end
  rescue
    exception -> {:error, exception}
  end

  defp ping_server(config) do
    url = server_base_url(config) <> "/v1/models"

    case Req.get(url: url, receive_timeout: 2_000) do
      {:ok, %Req.Response{status: status}} when status in 200..299 -> :ok
      {:error, reason} -> {:error, reason}
      {:ok, response} -> {:error, {:unhealthy, response.status}}
    end
  rescue
    exception -> {:error, exception}
  end

  defp do_chat(request, opts) do
    config = config()
    timeout = Keyword.get(opts, :receive_timeout, Map.get(config, :receive_timeout, :timer.minutes(10)))

    request_options = [
      url: server_base_url(config) <> "/v1/chat/completions",
      json: request,
      receive_timeout: timeout
    ]

    case Req.post(request_options) do
      {:ok, %Req.Response{status: 200, body: body}} -> {:ok, body}
      {:ok, %Req.Response{status: status, body: body}} -> {:error, {:http_error, status, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp build_chat_request(payload) do
    with {:ok, messages} <- build_messages(payload),
         {:ok, request} <- build_request_map(messages, payload) do
      {:ok, request}
    end
  end

  defp build_messages(payload) do
    messages =
      payload
      |> system_message()
      |> Enum.concat(Enum.map(Map.get(payload, "contents", []), &convert_message/1))
      |> Enum.filter(& &1)

    {:ok, messages}
  end

  defp build_request_map(messages, payload) do
    config = config()

    base = %{
      "model" => model_identifier(config),
      "messages" => messages
    }

    base = maybe_put_temperature(base, config)

    tools = build_functions(payload)

    request =
      case tools do
        [] -> base
        _ ->
          base
          |> Map.put("functions", tools)
          |> Map.put("function_call", "auto")
      end

    {:ok, request}
  end

  defp maybe_put_temperature(map, %{temperature: nil}), do: map

  defp maybe_put_temperature(map, %{temperature: value}) when is_number(value) do
    Map.put(map, "temperature", value)
  end

  defp maybe_put_temperature(map, _config), do: map

  defp model_identifier(config) do
    cond do
      (name = Map.get(config, :model_name)) && name != "" -> name
      (path = Map.get(config, :model_path)) -> Path.basename(path)
      true -> "gemma-3-12b"
    end
  end

  defp system_message(%{"systemInstruction" => %{"parts" => parts}}) do
    case parts |> Enum.map(&Map.get(&1, "text")) |> Enum.reject(&is_nil/1) |> Enum.join("\n") do
      "" -> []
      text -> [%{"role" => "system", "content" => text}]
    end
  end

  defp system_message(_), do: []

  defp convert_message(%{"role" => "user", "parts" => parts}) do
    case parts |> Enum.map(&Map.get(&1, "text")) |> Enum.reject(&is_nil/1) |> Enum.join("\n") do
      "" -> nil
      text -> %{"role" => "user", "content" => text}
    end
  end

  defp convert_message(%{"role" => "model", "parts" => parts}) do
    with %{"functionCall" => %{"name" => name} = call} <- Enum.find(parts, &Map.has_key?(&1, "functionCall")) do
      args =
        call
        |> Map.get("args", %{})
        |> Jason.encode!()

      %{
        "role" => "assistant",
        "content" => nil,
        "function_call" => %{"name" => name, "arguments" => args}
      }
    else
      _ -> nil
    end
  end

  defp convert_message(%{"role" => "tool", "parts" => parts}) do
    with %{"functionResponse" => %{"name" => name} = response} <-
           Enum.find(parts, &Map.has_key?(&1, "functionResponse")) do
      content =
        response
        |> Map.get("response")
        |> Jason.encode!()

      %{
        "role" => "tool",
        "name" => name,
        "tool_call_id" => name,
        "content" => content
      }
    else
      _ -> nil
    end
  end

  defp convert_message(_), do: nil

  defp build_functions(payload) do
    payload
    |> Map.get("tools", [])
    |> Enum.flat_map(fn
      %{"functionDeclarations" => declarations} -> Enum.map(declarations, &Map.take(&1, ["name", "description", "parameters"]))
      _ -> []
    end)
  end

  defp server_base_url(config) do
    "http://#{config.server_host}:#{config.server_port}"
  end
end
