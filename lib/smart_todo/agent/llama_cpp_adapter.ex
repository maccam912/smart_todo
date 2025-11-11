defmodule SmartTodo.Agent.LlamaCppAdapter do
  @moduledoc """
  Adapter for llama.cpp server that translates between Gemini API format
  and llama.cpp's OpenAI-compatible API format.
  """

  require Logger
  alias SmartTodo.Agent.LlamaCppServer

  @doc """
  Makes a request to the local llama.cpp server, translating from Gemini format.

  Expected payload structure (Gemini format):
  - systemInstruction: %{"role" => "system", "parts" => [%{"text" => ...}]}
  - contents: list of conversation turns
  - tools: list of function declarations
  - toolConfig: function calling configuration

  Returns: {:ok, response_body} or {:error, reason}
  """
  def request(payload, opts \\ []) do
    if not LlamaCppServer.ready?() do
      {:error, :server_not_ready}
    else
      openai_payload = translate_to_openai(payload)
      url = "#{LlamaCppServer.base_url()}/v1/chat/completions"

      receive_timeout = Keyword.get(opts, :receive_timeout, 120_000)

      case Req.post(url: url, json: openai_payload, receive_timeout: receive_timeout) do
        {:ok, %Req.Response{status: 200, body: body}} ->
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
  end

  # Translate Gemini API format to OpenAI format
  defp translate_to_openai(payload) do
    messages = build_openai_messages(payload)
    tools = build_openai_tools(payload["tools"])

    base = %{
      "model" => "gemma-3-12b",
      "messages" => messages,
      "temperature" => 0.7,
      "max_tokens" => 2048
    }

    if tools && length(tools) > 0 do
      Map.merge(base, %{
        "tools" => tools,
        "tool_choice" => "required"  # Force tool use like Gemini's "ANY" mode
      })
    else
      base
    end
  end

  defp build_openai_messages(payload) do
    system_message = extract_system_message(payload["systemInstruction"])
    content_messages = translate_contents(payload["contents"] || [])

    [system_message | content_messages]
    |> Enum.reject(&is_nil/1)
  end

  defp extract_system_message(nil), do: nil

  defp extract_system_message(%{"parts" => parts}) do
    text = parts
           |> Enum.map(fn %{"text" => t} -> t end)
           |> Enum.join("\n")

    %{"role" => "system", "content" => text}
  end

  defp translate_contents(contents) do
    Enum.map(contents, &translate_content/1)
  end

  defp translate_content(%{"role" => "user", "parts" => parts}) do
    content = parts
              |> Enum.map(fn %{"text" => t} -> t end)
              |> Enum.join("\n")

    %{"role" => "user", "content" => content}
  end

  defp translate_content(%{"role" => "model", "parts" => parts}) do
    # Check if this is a function call
    case Enum.find(parts, &Map.has_key?(&1, "functionCall")) do
      %{"functionCall" => fc} ->
        %{
          "role" => "assistant",
          "content" => nil,
          "tool_calls" => [
            %{
              "id" => generate_tool_call_id(),
              "type" => "function",
              "function" => %{
                "name" => fc["name"],
                "arguments" => Jason.encode!(fc["args"])
              }
            }
          ]
        }

      _ ->
        # Regular assistant message
        content = parts
                  |> Enum.map(fn %{"text" => t} -> t end)
                  |> Enum.join("\n")

        %{"role" => "assistant", "content" => content}
    end
  end

  defp translate_content(%{"role" => "tool", "parts" => parts}) do
    # Extract function response
    case Enum.find(parts, &Map.has_key?(&1, "functionResponse")) do
      %{"functionResponse" => fr} ->
        %{
          "role" => "tool",
          "tool_call_id" => generate_tool_call_id(),
          "content" => Jason.encode!(fr["response"])
        }

      _ ->
        nil
    end
  end

  defp translate_content(_), do: nil

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
