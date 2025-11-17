defmodule SmartTodo.Agent.LlamaCppAdapter do
  @moduledoc """
  Adapter for llama.cpp server that translates between Gemini API format
  and llama.cpp's OpenAI-compatible API format.
  """

  require Logger
  require OpenTelemetry.Tracer, as: Tracer

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

    # Extract base URL (remove /models/... part if present)
    base_url = url
    |> String.split("/models/")
    |> List.first()

    api_url = "#{base_url}/v1/chat/completions"

    receive_timeout = Keyword.get(opts, :receive_timeout, 120_000)
    model = openai_payload["model"]
    session_id = Keyword.get(opts, :session_id)
    user_id = extract_user_id(opts)

    # Start OpenTelemetry span for LLM request
    Tracer.with_span "gen_ai.llama_cpp.chat", %{kind: :client} do
      # Set semantic convention attributes for GenAI and OpenInference
      base_attributes = [
        {"gen_ai.system", "llama_cpp"},
        {"gen_ai.request.model", model},
        {"gen_ai.operation.name", "chat"},
        {"gen_ai.request.temperature", openai_payload["temperature"]},
        {"gen_ai.request.max_tokens", openai_payload["max_tokens"]},
        {"server.address", URI.parse(api_url).host},
        {"http.request.method", "POST"},
        {"url.full", api_url},
        # OpenInference attributes
        {"openinference.span.kind", "LLM"},
        {"input.value", encode_input_value(openai_payload)},
        # Capture full conversation for LLM observability
        {"llm.input_messages", encode_messages(openai_payload["messages"])},
        {"llm.model_name", model},
        {"llm.invocation_parameters", encode_invocation_params(openai_payload)},
        {"llm.tools", encode_tools(openai_payload["tools"])}
      ]

      # Add optional OpenInference attributes
      attributes = base_attributes
                   |> maybe_add_attribute("session.id", session_id)
                   |> maybe_add_attribute("user.id", user_id)

      Tracer.set_attributes(attributes)

      Logger.info("LlamaCppAdapter making request",
        url: api_url,
        timeout_ms: receive_timeout
      )

      case Req.post(url: api_url, json: openai_payload, receive_timeout: receive_timeout) do
        {:ok, %Req.Response{status: 200, body: body}} ->
          Logger.info("LlamaCppAdapter request successful", status: 200)

          # Set response attributes including OpenInference output
          Tracer.set_attributes([
            {"http.response.status_code", 200},
            {"gen_ai.response.finish_reasons", extract_openai_finish_reason(body)},
            {"gen_ai.usage.input_tokens", get_in(body, ["usage", "prompt_tokens"])},
            {"gen_ai.usage.output_tokens", get_in(body, ["usage", "completion_tokens"])},
            {"output.value", encode_output_value(body)},
            {"llm.output_messages", encode_output_messages(body)},
            {"llm.token_count.prompt", get_in(body, ["usage", "prompt_tokens"])},
            {"llm.token_count.completion", get_in(body, ["usage", "completion_tokens"])},
            {"llm.token_count.total", get_in(body, ["usage", "total_tokens"])}
          ])

          gemini_response = translate_from_openai(body)
          {:ok, gemini_response}

        {:ok, %Req.Response{status: status, body: body}} ->
          Logger.error("llama.cpp request failed: #{status} - #{inspect(body)}")

          Tracer.set_attributes([
            {"http.response.status_code", status},
            {"error", true}
          ])
          Tracer.set_status(:error, "HTTP error: #{status}")

          {:error, {:http_error, status, body}}

        {:error, reason} ->
          Logger.error("llama.cpp request error: #{inspect(reason)}")

          Tracer.set_attributes([{"error", true}])
          Tracer.set_status(:error, "Request failed: #{inspect(reason)}")

          {:error, reason}
      end
    end
  end

  defp extract_openai_finish_reason(%{"choices" => [choice | _]}) do
    Map.get(choice, "finish_reason", "unknown")
  end

  defp extract_openai_finish_reason(_), do: "unknown"

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

  defp extract_user_id(opts) do
    # Try to get user_id from scope in opts if available
    case Keyword.get(opts, :scope) do
      %{user: %{id: id}} when not is_nil(id) -> to_string(id)
      _ -> nil
    end
  end

  defp maybe_add_attribute(attributes, _key, nil), do: attributes
  defp maybe_add_attribute(attributes, key, value), do: attributes ++ [{key, value}]

  defp encode_input_value(openai_payload) do
    # Extract the last user message as input
    case get_in(openai_payload, ["messages"]) do
      messages when is_list(messages) ->
        messages
        |> Enum.reverse()
        |> Enum.find(fn msg -> msg["role"] == "user" end)
        |> case do
          %{"content" => content} when is_binary(content) -> content
          _ -> Jason.encode!(openai_payload)
        end
      _ -> Jason.encode!(openai_payload)
    end
  end

  defp encode_output_value(body) do
    # Extract the assistant's response from OpenAI format
    case get_in(body, ["choices"]) do
      [choice | _] ->
        case get_in(choice, ["message"]) do
          %{"content" => content} when is_binary(content) ->
            content
          %{"tool_calls" => tool_calls} when is_list(tool_calls) ->
            Jason.encode!(tool_calls)
          _ -> Jason.encode!(body)
        end
      _ -> Jason.encode!(body)
    end
  end

  defp encode_messages(nil), do: "[]"
  defp encode_messages(messages) when is_list(messages) do
    messages
    |> Enum.map(fn msg ->
      %{
        role: msg["role"],
        content: msg["content"] || encode_tool_calls(msg["tool_calls"])
      }
    end)
    |> Jason.encode!()
  end
  defp encode_messages(_), do: "[]"

  defp encode_tool_calls(nil), do: nil
  defp encode_tool_calls(tool_calls) when is_list(tool_calls) do
    Jason.encode!(tool_calls)
  end
  defp encode_tool_calls(_), do: nil

  defp encode_invocation_params(payload) do
    %{
      temperature: payload["temperature"],
      max_tokens: payload["max_tokens"],
      cache_prompt: payload["cache_prompt"]
    }
    |> Jason.encode!()
  end

  defp encode_tools(nil), do: nil
  defp encode_tools(tools) when is_list(tools) do
    tool_names = Enum.map(tools, fn tool ->
      get_in(tool, ["function", "name"])
    end)
    Jason.encode!(%{count: length(tools), functions: tool_names})
  end
  defp encode_tools(_), do: nil

  defp encode_output_messages(body) do
    case get_in(body, ["choices"]) do
      choices when is_list(choices) ->
        choices
        |> Enum.map(fn choice ->
          message = choice["message"]
          %{
            role: message["role"] || "assistant",
            content: message["content"] || encode_tool_calls(message["tool_calls"]),
            finish_reason: choice["finish_reason"]
          }
        end)
        |> Jason.encode!()
      _ -> "[]"
    end
  end
end
