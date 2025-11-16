defmodule SmartTodo.Agent.LangfuseTracker do
  @moduledoc """
  Handles Langfuse tracing and generation tracking for LLM API calls.

  This module provides functionality to track both Gemini and local LLM (OpenAI format)
  calls to Langfuse for observability and monitoring.
  """

  require Logger

  alias LangfuseSdk.{Trace, Generation}

  @doc """
  Checks if Langfuse tracking is enabled.
  """
  def enabled? do
    Application.get_env(:langfuse_sdk, :enabled, false) &&
      not is_nil(Application.get_env(:langfuse_sdk, :public_key)) &&
      not is_nil(Application.get_env(:langfuse_sdk, :secret_key))
  end

  @doc """
  Creates a new trace for an LLM session.

  ## Parameters
    - trace_id: Unique identifier for the trace
    - metadata: Additional metadata (user_id, session info, etc.)

  ## Examples
      iex> create_trace("trace-123", %{user_id: "user-456", scope: "todos"})
      :ok
  """
  def create_trace(trace_id, metadata \\ %{}) do
    if enabled?() do
      try do
        trace =
          Trace.new(%{
            id: trace_id,
            name: "llm-session",
            metadata: metadata,
            timestamp: DateTime.utc_now()
          })

        case LangfuseSdk.create(trace) do
          {:ok, _} ->
            Logger.debug("Langfuse trace created", trace_id: trace_id)
            :ok

          {:error, reason} ->
            Logger.warning("Failed to create Langfuse trace",
              trace_id: trace_id,
              reason: inspect(reason)
            )

            :error
        end
      rescue
        e ->
          Logger.warning("Exception creating Langfuse trace",
            trace_id: trace_id,
            error: inspect(e)
          )

          :error
      end
    else
      :disabled
    end
  end

  @doc """
  Tracks an LLM generation (API call).

  ## Parameters
    - generation_id: Unique identifier for this generation
    - trace_id: The trace this generation belongs to
    - opts: Options including:
      - :name - Name/type of the generation (e.g., "gemini-call", "llama-cpp-call")
      - :model - Model identifier
      - :input - Input data (prompt/messages)
      - :metadata - Additional metadata

  Returns a generation reference that can be used to update the generation
  with the output later.
  """
  def start_generation(generation_id, trace_id, opts \\ []) do
    if enabled?() do
      try do
        generation =
          Generation.new(%{
            id: generation_id,
            trace_id: trace_id,
            name: Keyword.get(opts, :name, "llm-generation"),
            model: Keyword.get(opts, :model),
            input: Keyword.get(opts, :input),
            metadata: Keyword.get(opts, :metadata, %{}),
            start_time: DateTime.utc_now()
          })

        case LangfuseSdk.create(generation) do
          {:ok, _} ->
            Logger.debug("Langfuse generation started",
              generation_id: generation_id,
              trace_id: trace_id
            )

            {:ok, generation}

          {:error, reason} ->
            Logger.warning("Failed to start Langfuse generation",
              generation_id: generation_id,
              reason: inspect(reason)
            )

            {:error, reason}
        end
      rescue
        e ->
          Logger.warning("Exception starting Langfuse generation",
            generation_id: generation_id,
            error: inspect(e)
          )

          {:error, e}
      end
    else
      {:disabled, nil}
    end
  end

  @doc """
  Completes a generation with the output and usage statistics.

  ## Parameters
    - generation: The generation struct from start_generation
    - output: The LLM response
    - opts: Options including:
      - :usage - Token usage statistics
      - :status_message - Error message if failed
      - :level - "DEFAULT", "WARNING", or "ERROR"
  """
  def complete_generation(generation, output, opts \\ []) do
    if enabled?() and not is_nil(generation) do
      try do
        updated_generation = %{
          generation
          | end_time: DateTime.utc_now(),
            output: output,
            usage: Keyword.get(opts, :usage),
            status_message: Keyword.get(opts, :status_message),
            level: Keyword.get(opts, :level, "DEFAULT")
        }

        case LangfuseSdk.update(updated_generation) do
          {:ok, _} ->
            Logger.debug("Langfuse generation completed",
              generation_id: generation.id
            )

            :ok

          {:error, reason} ->
            Logger.warning("Failed to complete Langfuse generation",
              generation_id: generation.id,
              reason: inspect(reason)
            )

            :error
        end
      rescue
        e ->
          Logger.warning("Exception completing Langfuse generation",
            generation_id: generation.id,
            error: inspect(e)
          )

          :error
      end
    else
      :disabled
    end
  end

  @doc """
  Tracks a complete LLM call (convenience function that starts and completes).

  This function wraps the execution of an LLM API call with Langfuse tracking.

  ## Parameters
    - trace_id: The trace this generation belongs to
    - generation_id: Unique identifier for this generation
    - opts: Options for the generation (name, model, input, metadata)
    - api_call_fn: Function that executes the API call and returns {:ok, response} or {:error, reason}

  ## Examples
      iex> track_llm_call("trace-123", "gen-456", [
      ...>   name: "gemini-call",
      ...>   model: "gemini-2.0-flash",
      ...>   input: %{"messages" => [...]}
      ...> ], fn -> make_api_call() end)
      {:ok, response}
  """
  def track_llm_call(trace_id, generation_id, opts, api_call_fn) do
    case start_generation(generation_id, trace_id, opts) do
      {:ok, generation} ->
        start_time = System.monotonic_time(:millisecond)

        case api_call_fn.() do
          {:ok, response} ->
            duration = System.monotonic_time(:millisecond) - start_time

            # Extract usage information if available
            usage = extract_usage(response, opts)

            complete_generation(generation, response, usage: usage, metadata: %{duration_ms: duration})
            {:ok, response}

          {:error, reason} = error ->
            complete_generation(generation, nil,
              status_message: inspect(reason),
              level: "ERROR"
            )

            error
        end

      {:disabled, _} ->
        # Langfuse is disabled, just execute the API call
        api_call_fn.()

      {:error, _reason} ->
        # Failed to create generation, but still execute the API call
        api_call_fn.()
    end
  end

  @doc """
  Extracts usage statistics from an LLM response.

  Handles both Gemini and OpenAI response formats.
  """
  defp extract_usage(response, opts) when is_map(response) do
    cond do
      # OpenAI format
      Map.has_key?(response, "usage") ->
        usage = response["usage"]

        %{
          input: usage["prompt_tokens"],
          output: usage["completion_tokens"],
          total: usage["total_tokens"]
        }

      # Gemini format
      Map.has_key?(response, "usageMetadata") ->
        usage = response["usageMetadata"]

        %{
          input: usage["promptTokenCount"],
          output: usage["candidatesTokenCount"],
          total: usage["totalTokenCount"]
        }

      # Manual usage provided in opts
      Keyword.has_key?(opts, :usage) ->
        Keyword.get(opts, :usage)

      true ->
        nil
    end
  end

  defp extract_usage(_response, opts) do
    Keyword.get(opts, :usage)
  end

  @doc """
  Generates a unique trace ID for a session.
  """
  def generate_trace_id(prefix \\ "trace") do
    "#{prefix}-#{:crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)}"
  end

  @doc """
  Generates a unique generation ID.
  """
  def generate_generation_id(prefix \\ "gen") do
    "#{prefix}-#{:crypto.strong_rand_bytes(12) |> Base.encode16(case: :lower)}"
  end
end
