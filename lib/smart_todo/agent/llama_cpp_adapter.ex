defmodule SmartTodo.Agent.LlamaCppAdapter do
  @moduledoc """
  Adapter for llama.cpp server that translates between Gemini API format
  and llama.cpp's OpenAI-compatible API format.
  """

  alias SmartTodo.Agent.LangfuseTracker

  require Logger

  @doc """
  Makes a request to a llama.cpp server, translating from Gemini format.

  Expected payload structure (Gemini format):
  - systemInstruction: %{"role" => "system", "parts" => [%{"text" => ...}]}
  - contents: list of conversation turns
  - tools: list of function declarations
  - toolConfig: function calling configuration

  Returns: {:ok, response_body} or {:error, reason}
  """
  def request(url, payload, opts \\ []) do
    openai_payload = translate_to_openai(payload, opts)
    trace_id = Keyword.get(opts, :trace_id)

    # Extract base URL (remove /models/... part if present)
    base_url = url
    |> String.split("/models/")
    |> List.first()

    api_url = "#{base_url}/v1/chat/completions"

    receive_timeout = Keyword.get(opts, :receive_timeout, 120_000)

    Logger.info("LlamaCppAdapter making request",
      url: api_url,
      timeout_ms: receive_timeout
    )

    # Wrap API call with Langfuse tracking
    api_call_fn = fn ->
      case Req.post(url: api_url, json: openai_payload, receive_timeout: receive_timeout) do
        {:ok, %Req.Response{status: 200, body: body}} ->
          Logger.info("LlamaCppAdapter request successful", status: 200)
          gemini_response = translate_from_openai(body)
          {:ok, gemini_response}

        {:ok, %Req.Response{status: status, body: body}} ->
          Logger.error("llama.cpp request failed: #{status} - #{inspect(body)}")
          {:error, {:http_error, status, body}}

        {:error, reason} ->
          Logger.error("llama.cpp request error: #{inspect(reason)}")
          {:error, reason}
      end
    end

    if trace_id do
      generation_id = LangfuseTracker.generate_generation_id("llama-cpp")

      LangfuseTracker.track_llm_call(
        trace_id,
        generation_id,
        [
          name: "llama-cpp-api-call",
          model: openai_payload["model"],
          input: openai_payload,
          metadata: %{url: api_url, provider: "llama.cpp"}
        ],
        api_call_fn
      )
    else
      api_call_fn.()
    end
  end

  # Translate Gemini API format to OpenAI format
  defp translate_to_openai(payload, opts) do
    messages = build_openai_messages(payload)
    tools = build_openai_tools(payload["tools"])

    # Get model from opts, environment variable, or use default
    # For llama.cpp servers, this can often be omitted or set to a simple identifier
    model = Keyword.get(opts, :model) ||
            System.get_env("LLAMA_CPP_MODEL") ||
            "qwen2.5-3b-instruct"

    base = %{
      "model" => model,
      "messages" => messages,
      "temperature" => 0.7,
      "max_tokens" => 2048,
      "cache_prompt" => true
    }

    if tools && length(tools) > 0 do
      # Configure tool_choice based on environment or server capabilities
      # Options: "auto", "required", or "none"
      # "required" forces tool use (like Gemini's "ANY" mode) but may not be supported by all llama.cpp servers
      # "auto" is more widely supported and lets the model decide
      tool_choice = System.get_env("LLAMA_CPP_TOOL_CHOICE", "auto")

      Map.merge(base, %{
        "tools" => tools,
        "tool_choice" => tool_choice
      })
    else
      base
    end
  end

  defp build_openai_messages(payload) do
    system_message = extract_system_message(payload["systemInstruction"])
    content_messages = translate_contents(payload["contents"] || [])

    ([system_message | content_messages]
    |> Enum.reject(&is_nil/1))
  end

  defp extract_system_message(nil), do: nil

  defp extract_system_message(%{"parts" => parts}) do
    text = parts
           |> Enum.map(fn %{"text" => t} -> t end)
           |> Enum.join("\n")

    %{"role" => "system", "content" => text}
  end

  defp translate_contents(contents) do
    # Use map_reduce to track tool_call_id and function name across messages
    {messages, _state} =
      Enum.map_reduce(contents, %{}, fn content, state ->
        translate_content_with_state(content, state)
      end)

    messages
  end

  defp translate_content_with_state(%{"role" => "user", "parts" => parts}, state) do
    content = parts
              |> Enum.map(fn %{"text" => t} -> t end)
              |> Enum.join("\n")

    {%{"role" => "user", "content" => content}, state}
  end

  defp translate_content_with_state(%{"role" => "model", "parts" => parts}, state) do
    # Check if this is a function call
    case Enum.find(parts, &Map.has_key?(&1, "functionCall")) do
      %{"functionCall" => fc} ->
        tool_call_id = generate_tool_call_id()
        function_name = fc["name"]

        message = %{
          "role" => "assistant",
          "content" => nil,
          "tool_calls" => [
            %{
              "id" => tool_call_id,
              "type" => "function",
              "function" => %{
                "name" => function_name,
                "arguments" => Jason.encode!(fc["args"])
              }
            }
          ]
        }

        # Store the tool_call_id and function name for the next tool response
        new_state = Map.merge(state, %{
          last_tool_call_id: tool_call_id,
          last_function_name: function_name
        })

        {message, new_state}

      _ ->
        # Regular assistant message
        content = parts
                  |> Enum.map(fn %{"text" => t} -> t end)
                  |> Enum.join("\n")

        {%{"role" => "assistant", "content" => content}, state}
    end
  end

  defp translate_content_with_state(%{"role" => "tool", "parts" => parts}, state) do
    # Extract function response
    case Enum.find(parts, &Map.has_key?(&1, "functionResponse")) do
      %{"functionResponse" => fr} ->
        # Reuse the tool_call_id and function name from the previous assistant message
        tool_call_id = Map.get(state, :last_tool_call_id, generate_tool_call_id())
        function_name = Map.get(state, :last_function_name, fr["name"])

        message = %{
          "role" => "tool",
          "tool_call_id" => tool_call_id,
          "name" => function_name,
          "content" => Jason.encode!(fr["response"])
        }

        {message, state}

      _ ->
        {nil, state}
    end
  end

  defp translate_content_with_state(_, state), do: {nil, state}

  defp build_openai_tools(nil), do: []
  defp build_openai_tools([]), do: []

  defp build_openai_tools([%{"functionDeclarations" => functions}]) do
    Enum.map(functions, fn func ->
      %{
        "type" => "function",
        "function" => %{
          "name" => func["name"],
          "description" => func["description"],
          "parameters" => func["parameters"]
        }
      }
    end)
  end

  # Translate OpenAI response back to Gemini format
  defp translate_from_openai(%{"choices" => [choice | _]} = _response) do
    message = choice["message"]

    parts = extract_parts_from_openai(message)

    %{
      "candidates" => [
        %{
          "content" => %{
            "parts" => parts,
            "role" => "model"
          },
          "finishReason" => map_finish_reason(choice["finish_reason"])
        }
      ]
    }
  end

  defp extract_parts_from_openai(%{"tool_calls" => [tool_call | _]}) do
    function = tool_call["function"]
    args = Jason.decode!(function["arguments"])

    [
      %{
        "functionCall" => %{
          "name" => function["name"],
          "args" => args
        }
      }
    ]
  end

  defp extract_parts_from_openai(%{"content" => content}) when is_binary(content) do
    [%{"text" => content}]
  end

  defp extract_parts_from_openai(_), do: [%{"text" => ""}]

  defp map_finish_reason("stop"), do: "STOP"
  defp map_finish_reason("tool_calls"), do: "STOP"
  defp map_finish_reason("length"), do: "MAX_TOKENS"
  defp map_finish_reason(_), do: "OTHER"

  defp generate_tool_call_id do
    "call_#{:crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)}"
  end
end
