defmodule SmartTodo.Agent.LlmSession do
  @moduledoc """
  Orchestrates Gemini-driven task automation using the conversational state machine.

  Each interaction runs in its own supervised task and queries the Gemini 2.5 Flash
  model for a sequence of state-machine commands. The loop requests a single tool
  call at a time, applies the operation, feeds the updated state back to the model,
  and stops on completion, error, or after 20 model responses.
  """

  alias SmartTodo.Accounts.Scope
  alias SmartTodo.Agent.StateMachine
  alias Req

  require Logger
  require OpenTelemetry.Tracer, as: Tracer

  @status_options ~w(todo in_progress done)a
  @urgency_options ~w(low normal high critical)a
  @recurrence_options ~w(none daily weekly monthly yearly)a

  @max_errors 3
  @max_rounds 20
  @default_model "gpt-4-turbo"
  @base_url "https://api.openai.com/v1"
  @default_receive_timeout :timer.minutes(10)

  @spec start(Scope.t(), String.t(), keyword()) :: {:ok, pid()}
  def start(scope, user_text, opts \\ []) do
    Task.Supervisor.start_child(SmartTodo.Agent.TaskSupervisor, fn ->
      run(scope, user_text, opts)
    end)
  end

  defp generate_session_id do
    # Generate UUID v4 for session tracking
    <<u0::48, _::4, u1::12, _::2, u2::62>> = :crypto.strong_rand_bytes(16)
    <<u0::48, 4::4, u1::12, 2::2, u2::62>>
    |> Base.encode16(case: :lower)
    |> String.replace(~r/(.{8})(.{4})(.{4})(.{4})(.{12})/, "\\1-\\2-\\3-\\4-\\5")
  end

  @spec run(Scope.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term(), map()}
  def run(scope, user_text, opts \\ []) do
    # Generate session ID for OpenInference tracking
    session_id = generate_session_id()
    user_id = case scope do
      %Scope{user: %{id: id}} when not is_nil(id) -> to_string(id)
      _ -> nil
    end

    opts = opts
           |> ensure_default_timeouts()
           |> Keyword.put(:session_id, session_id)
           |> Keyword.put(:scope, scope)

    # Create agent span wrapping the entire conversation
    Tracer.with_span "smart_todo.agent.session", %{kind: :internal} do
      # Set OpenInference agent span attributes
      base_attributes = [
        {"openinference.span.kind", "AGENT"},
        {"session.id", session_id},
        {"input.value", user_text}
      ]

      attributes = base_attributes
                   |> maybe_add_attribute("user.id", user_id)

      Tracer.set_attributes(attributes)

      result = with {:ok, initial} <- build_initial_session(scope, user_text, session_id),
                    {:ok, result} <- conversation_loop(initial, opts) do
        {:ok, result}
      else
        {:error, reason, ctx} ->
          {:error, reason, ctx}
      end

      # Set output value on the agent span
      case result do
        {:ok, res} ->
          Tracer.set_attribute("output.value", format_agent_output(res))
          result
        {:error, _reason, _ctx} ->
          Tracer.set_status(:error, "Agent session failed")
          result
      end
    end
  end

  defp build_initial_session(scope, user_text, session_id) do
    {machine, response} = StateMachine.start_session(scope)

    conversation = [user_turn(user_text, response, :initial)]

    {:ok,
     %{
       machine: machine,
       last_response: response,
       conversation: conversation,
       executed: [],
       scope: scope,
       user_text: user_text,
       errors: 0,
       session_id: session_id
     }}
  end

  defp conversation_loop(context, opts, round \\ 0)

  defp conversation_loop(%{machine: %{state: :completed}} = ctx, _opts, _round) do
    {:ok,
     %{
       machine: ctx.machine,
       last_response: ctx.last_response,
       executed: Enum.reverse(ctx.executed),
       conversation: ctx.conversation
     }}
  end

  defp conversation_loop(ctx, opts, round) do
    max_rounds = Keyword.get(opts, :max_rounds, @max_rounds)
    max_errors = Keyword.get(opts, :max_errors, @max_errors)

    cond do
      round >= max_rounds ->
        {:error, :max_rounds, failure_context(ctx)}

      Map.get(ctx, :errors, 0) >= max_errors ->
        {:error, :max_errors, failure_context(ctx)}

      true ->
        tools = tools_from_response(ctx.last_response)
        model = get_model(opts)

        payload = %{
          "model" => model,
          "messages" => [system_message(ctx.scope) | ctx.conversation],
          "tools" => tools,
          "tool_choice" => "auto"
        }

        case request_command(payload, ctx.last_response, opts) do
          {:ok, call, body} ->
            case apply_command(ctx, call, body) do
              {:ok, after_call} ->
                conversation_loop(after_call, opts, round + 1)

              {:retry, retry_ctx} ->
                if Map.get(retry_ctx, :errors, 0) >= max_errors do
                  {:error, :max_errors, failure_context(retry_ctx)}
                else
                  conversation_loop(retry_ctx, opts, round + 1)
                end

              other ->
                {:error, {:unexpected_command_result, other}, failure_context(ctx)}
            end

          {:error, reason, extra} ->
            {:error, reason, failure_context(ctx, extra)}
        end
    end
  end

  defp request_command(payload, last_response, opts) do
    case call_model(payload, opts) do
      {:ok, body} ->
        with {:ok, parsed} <- extract_function_call(body),
             {:ok, command} <- resolve_command(parsed.command, last_response) do
          {:ok, %{name: parsed.command, command: command, params: parsed.params}, body}
        else
          {:error, reason} -> {:error, reason, error_context(last_response, payload, body)}
        end

      {:error, reason} ->
        {:error, reason, error_context(last_response, payload, nil)}
    end
  end

  defp apply_command(ctx, %{command: command, params: params, name: name}, _raw_body) do
    case StateMachine.handle_command(ctx.machine, command, params) do
      {:ok, machine, response} ->
        status = if machine.state == :completed, do: :completed, else: :pending

        conversation =
          ctx.conversation ++
            [model_turn(name, params), tool_turn(name, params, response, status)] ++
            if status == :pending, do: [user_turn(nil, response, :followup)], else: []

        final_ctx =
          ctx
          |> Map.put(:conversation, conversation)
          |> Map.put(:machine, machine)
          |> Map.put(:last_response, response)
          |> Map.update!(:executed, &[command_entry(command, params) | &1])

        {:ok, final_ctx}

      {:error, machine, response} ->
        conversation = add_error_turn(ctx.conversation, name, params, response)

        updated =
          ctx
          |> Map.put(:machine, machine)
          |> Map.put(:last_response, response)
          |> Map.put(:conversation, conversation)
          |> increment_error_count()

        {:retry, updated}
    end
  end

  defp command_entry(command, params) do
    %{name: command, params: params}
  end

  defp increment_error_count(ctx) do
    Map.update(ctx, :errors, 1, &(&1 + 1))
  end

  defp failure_context(ctx), do: failure_context(ctx, %{})

  defp failure_context(ctx, nil), do: failure_context(ctx, %{})

  defp failure_context(ctx, extra) when is_list(extra) do
    failure_context(ctx, Enum.into(extra, %{}))
  end

  defp failure_context(ctx, extra) when is_map(extra) do
    base = %{
      machine: ctx.machine,
      last_response: ctx.last_response,
      executed: Enum.reverse(ctx.executed),
      conversation: ctx.conversation,
      errors: Map.get(ctx, :errors, 0)
    }

    Map.merge(base, extra)
  end

  defp call_model(payload, opts) do
    url = model_endpoint(get_model(opts), opts)
    request_fun = Keyword.get(opts, :request_fun, &openai_request/3)
    request_opts = prepare_request_opts(opts)

    request_fun.(url, payload, request_opts)
  end

  defp openai_request(url, payload, opts) do
    api_key_value = Keyword.get(opts, :api_key, api_key())
    headers = Keyword.get(opts, :headers, [])
    timeout = Keyword.get(opts, :receive_timeout, default_receive_timeout())
    session_id = Keyword.get(opts, :session_id)
    user_id = extract_user_id(opts)

    # Add Authorization header for OpenAI
    auth_headers =
      if api_key_value do
        [{"Authorization", "Bearer #{api_key_value}"} | headers]
      else
        headers
      end

    request_options = [
      url: url,
      json: payload,
      receive_timeout: timeout,
      headers: auth_headers
    ]

    model = get_model(opts)

    # Start OpenTelemetry span for LLM request
    Tracer.with_span "gen_ai.openai.chat", %{kind: :client} do
      # Set semantic convention attributes for GenAI and OpenInference
      base_attributes = [
        {"gen_ai.system", "openai"},
        {"gen_ai.request.model", model},
        {"gen_ai.operation.name", "chat"},
        {"server.address", URI.parse(url).host},
        {"http.request.method", "POST"},
        {"url.full", url},
        # OpenInference attributes
        {"openinference.span.kind", "LLM"},
        {"input.value", encode_input_value(payload)},
        # Capture full conversation for LLM observability
        {"llm.input_messages", encode_messages(get_in(payload, ["messages"]))},
        {"llm.model_name", model},
        {"llm.tool_calls", encode_tools(get_in(payload, ["tools"]))}
      ]

      # Add optional OpenInference attributes
      attributes = base_attributes
                   |> maybe_add_attribute("session.id", session_id)
                   |> maybe_add_attribute("user.id", user_id)

      Tracer.set_attributes(attributes)

      # Log request details
      Logger.info("Attempting LLM connection",
        url: url,
        timeout_ms: timeout,
        has_api_key: not is_nil(api_key_value),
        header_count: length(headers)
      )

      case Req.post(request_options) do
        {:ok, %Req.Response{status: 200, body: body}} ->
          Logger.info("LLM request successful", url: url, status: 200)

          # Set response attributes including OpenInference output
          Tracer.set_attributes([
            {"http.response.status_code", 200},
            {"gen_ai.response.finish_reasons", extract_finish_reason(body)},
            {"output.value", encode_output_value(body)},
            {"llm.output_messages", encode_output_messages(body)}
          ])

          {:ok, body}

        {:ok, %Req.Response{status: status, body: body}} ->
          Logger.error("LLM HTTP error",
            url: url,
            status: status,
            body: inspect(body, limit: 500),
            error_type: :http_error
          )

          Tracer.set_attributes([
            {"http.response.status_code", status},
            {"error", true}
          ])
          Tracer.set_status(:error, "HTTP error: #{status}")

          {:error, {:http_error, status, body}}

        {:error, reason} ->
          Logger.error("LLM connection failed",
            url: url,
            timeout_ms: timeout,
            reason: inspect(reason, limit: 500),
            error_type: classify_error(reason)
          )

          Tracer.set_attributes([{"error", true}])
          Tracer.set_status(:error, "Request failed: #{inspect(reason)}")

          {:error, reason}
      end
    end
  end

  defp extract_user_id(opts) do
    # Try to get user_id from scope in opts if available
    case Keyword.get(opts, :scope) do
      %Scope{user: %{id: id}} when not is_nil(id) -> to_string(id)
      _ -> nil
    end
  end

  defp maybe_add_attribute(attributes, _key, nil), do: attributes
  defp maybe_add_attribute(attributes, key, value), do: attributes ++ [{key, value}]

  defp encode_input_value(payload) do
    # Extract the last user message as input
    case get_in(payload, ["contents"]) do
      contents when is_list(contents) ->
        contents
        |> Enum.reverse()
        |> Enum.find(fn content -> content["role"] == "user" end)
        |> case do
          %{"parts" => parts} when is_list(parts) ->
            parts
            |> Enum.map(fn part -> Map.get(part, "text", "") end)
            |> Enum.join("\n")
          _ -> Jason.encode!(payload)
        end
      _ -> Jason.encode!(payload)
    end
  end

  defp encode_output_value(body) do
    # Extract the model's response text
    case get_in(body, ["candidates"]) do
      [candidate | _] ->
        case get_in(candidate, ["content", "parts"]) do
          parts when is_list(parts) ->
            parts
            |> Enum.map(fn part ->
              cond do
                Map.has_key?(part, "text") -> part["text"]
                Map.has_key?(part, "functionCall") -> Jason.encode!(part["functionCall"])
                true -> ""
              end
            end)
            |> Enum.join("\n")
          _ -> Jason.encode!(body)
        end
      _ -> Jason.encode!(body)
    end
  end

  defp encode_messages(nil), do: "[]"
  defp encode_messages(messages) when is_list(messages) do
    # Encode conversation history for LLM observability
    messages
    |> Enum.map(fn msg ->
      %{
        role: msg["role"],
        content: extract_message_content(msg)
      }
    end)
    |> Jason.encode!()
  end
  defp encode_messages(_), do: "[]"

  defp extract_message_content(%{"parts" => parts}) when is_list(parts) do
    parts
    |> Enum.map(fn part ->
      cond do
        Map.has_key?(part, "text") -> part["text"]
        Map.has_key?(part, "functionCall") -> Jason.encode!(part["functionCall"])
        Map.has_key?(part, "functionResponse") -> Jason.encode!(part["functionResponse"])
        true -> ""
      end
    end)
    |> Enum.join("\n")
  end
  defp extract_message_content(_), do: ""

  defp encode_system_instruction(nil), do: nil
  defp encode_system_instruction(%{"parts" => parts}) when is_list(parts) do
    parts
    |> Enum.map(fn part -> Map.get(part, "text", "") end)
    |> Enum.join("\n")
  end
  defp encode_system_instruction(_), do: nil

  defp encode_tools(nil), do: nil
  defp encode_tools(tools) when is_list(tools) do
    # Just encode the tool count and names for now to avoid huge payloads
    tool_count = length(tools)
    function_names = tools
                     |> Enum.flat_map(fn tool ->
                       case get_in(tool, ["functionDeclarations"]) do
                         functions when is_list(functions) ->
                           Enum.map(functions, fn f -> f["name"] end)
                         _ -> []
                       end
                     end)

    Jason.encode!(%{count: tool_count, functions: function_names})
  end
  defp encode_tools(_), do: nil

  defp encode_output_messages(body) do
    # Encode the model's output messages for LLM observability
    case get_in(body, ["choices"]) do
      choices when is_list(choices) ->
        choices
        |> Enum.map(fn choice ->
          %{
            role: get_in(choice, ["message", "role"]) || "assistant",
            content: get_in(choice, ["message", "content"]) || "",
            tool_calls: get_in(choice, ["message", "tool_calls"]),
            finish_reason: Map.get(choice, "finish_reason")
          }
        end)
        |> Jason.encode!()
      _ -> "[]"
    end
  end

  defp format_agent_output(result) do
    # Format the agent's final output for tracing
    case result do
      %{machine: %{state: state}, last_response: response, executed: executed} ->
        %{
          state: state,
          message: Map.get(response, :message, ""),
          executed_commands: length(executed),
          commands: Enum.map(executed, fn cmd -> Map.get(cmd, :name, "unknown") end)
        }
        |> Jason.encode!()
      _ -> Jason.encode!(result)
    end
  end

  defp extract_finish_reason(%{"choices" => [choice | _]}) do
    Map.get(choice, "finish_reason", "UNKNOWN")
  end

  defp extract_finish_reason(_), do: "UNKNOWN"

  defp classify_error(%Mint.TransportError{reason: reason}), do: {:transport_error, reason}
  defp classify_error(%Mint.HTTPError{reason: reason}), do: {:http_protocol_error, reason}
  defp classify_error({:timeout, _}), do: :timeout
  defp classify_error(:timeout), do: :timeout
  defp classify_error(:econnrefused), do: :connection_refused
  defp classify_error(:nxdomain), do: :dns_resolution_failed
  defp classify_error(:closed), do: :connection_closed
  defp classify_error(_), do: :unknown

  defp ensure_default_timeouts(opts) do
    configured_timeout = default_receive_timeout()

    opts
    |> Keyword.put_new(:receive_timeout, configured_timeout)
  end

  defp default_receive_timeout do
    Application.get_env(:smart_todo, :llm_receive_timeout, @default_receive_timeout)
  end

  defp api_key do
    present(System.get_env("OPENAI_API_KEY"))
  end

  defp get_model(opts) do
    Keyword.get(opts, :model) || System.get_env("LLM_MODEL") || @default_model
  end

  defp model_endpoint(_model, opts) do
    base =
      Keyword.get(opts, :base_url) ||
        Application.get_env(:smart_todo, :llm, []) |> Keyword.get(:base_url) ||
        System.get_env("OPENAI_API_BASE") ||
        @base_url

    "#{base}/chat/completions"
  end

  defp prepare_request_opts(opts) do
    opts
    |> Keyword.put_new_lazy(:receive_timeout, &default_receive_timeout/0)
  end

  defp normalize_headers(headers) do
    headers
    |> List.wrap()
    |> Enum.flat_map(fn entry ->
      cond do
        is_map(entry) -> Map.to_list(entry)
        is_list(entry) -> entry
        true -> [entry]
      end
    end)
  end

  defp present(value) when value in [nil, ""], do: nil
  defp present(value), do: value

  defp extract_function_call(%{"choices" => [choice | _]}) do
    tool_calls = get_in(choice, ["message", "tool_calls"]) || []

    case tool_calls do
      [%{"function" => %{"name" => name, "arguments" => args_str}} | _] ->
        # OpenAI returns arguments as a JSON string, so we need to decode it
        case Jason.decode(args_str) do
          {:ok, args} -> {:ok, %{command: name, params: normalize_args(args)}}
          {:error, _} -> {:error, :invalid_json_arguments}
        end

      [] ->
        # This case handles when the model returns a regular message instead of a tool call
        # For this agent, we'll treat it as no function call.
        {:error, :no_function_call}

      _ ->
        {:error, :unsupported_tool_call_format}
    end
  end

  defp extract_function_call(_), do: {:error, :invalid_response}

  defp normalize_args(args) when is_map(args), do: args
  defp normalize_args(_), do: %{}

  @supported_commands ~w(select_task create_task update_task_fields delete_task complete_task exit_editing discard_all complete_session record_plan)a

  defp resolve_command(name, last_response) when is_binary(name) do
    case command_lookup(last_response)[name] do
      nil -> {:error, {:unsupported_command, name}}
      command -> {:ok, command}
    end
  end

  defp resolve_command(_, _), do: {:error, :invalid_command_name}

  defp command_lookup(response) do
    Enum.reduce(response.available_commands, %{}, fn command, acc ->
      name = command_name(command)

      case Enum.find(@supported_commands, fn atom -> Atom.to_string(atom) == name end) do
        nil -> acc
        atom -> Map.put(acc, name, atom)
      end
    end)
  end

  defp tools_from_response(response) do
    Enum.map(response.available_commands, fn command ->
      %{
        "type" => "function",
        "function" => %{
          "name" => command_name(command),
          "description" => command_desc(command),
          "parameters" => tool_parameters(command)
        }
      }
    end)
  end

  defp command_name(%{name: name}), do: name
  defp command_name(%{"name" => name}), do: name

  defp command_desc(%{description: desc}), do: desc
  defp command_desc(%{"description" => desc}), do: desc

  defp command_params(%{params: params}), do: params
  defp command_params(%{"params" => params}), do: params

  defp tool_parameters(command) do
    name = command_name(command)
    params = command_params(command)

    properties =
      Enum.into(params, %{}, fn {key, desc} ->
        key_string = to_string(key)

        schema =
          name
          |> parameter_schema(key_string)
          |> Map.put("description", desc)

        {key, schema}
      end)

    required = required_parameters(params)

    base = %{"type" => "object", "properties" => properties}

    if required == [] do
      base
    else
      Map.put(base, "required", required)
    end
  end

  defp required_parameters(params) do
    params
    |> Enum.filter(fn {_key, desc} -> String.contains?(String.downcase(desc), "required") end)
    |> Enum.map(fn {key, _} -> key end)
  end

  defp parameter_schema("record_plan", "steps") do
    %{"type" => "array", "items" => %{"type" => "string"}}
  end

  defp parameter_schema(_command, "task_id"), do: %{"type" => "integer"}
  defp parameter_schema(_command, "pending_ref"), do: %{"type" => "integer"}
  defp parameter_schema(_command, "assignee_id"), do: %{"type" => "integer"}

  defp parameter_schema(_command, "prerequisite_ids") do
    %{"type" => "array", "items" => %{"type" => "integer"}}
  end

  defp parameter_schema(command_name, "status")
       when command_name in ["create_task", "update_task_fields"] do
    %{"type" => "string", "enum" => Enum.map(@status_options, &Atom.to_string/1)}
  end

  defp parameter_schema(command_name, "urgency")
       when command_name in ["create_task", "update_task_fields"] do
    %{"type" => "string", "enum" => Enum.map(@urgency_options, &Atom.to_string/1)}
  end

  defp parameter_schema(command_name, "recurrence")
       when command_name in ["create_task", "update_task_fields"] do
    %{"type" => "string", "enum" => Enum.map(@recurrence_options, &Atom.to_string/1)}
  end

  defp parameter_schema(_command, "due_date") do
    %{"type" => "string", "format" => "date"}
  end

  defp parameter_schema(_command, _param) do
    %{"type" => "string"}
  end

  defp model_turn(name, params) do
    %{
      "role" => "assistant",
      "tool_calls" => [
        %{
          "type" => "function",
          "function" => %{
            "name" => name,
            "arguments" => Jason.encode!(params)
          }
        }
      ]
    }
  end

  defp tool_turn(name, params, response, status) do
    outcome =
      case status do
        :completed -> "completed"
        :pending -> "ok"
      end

    content = %{
      "status" => outcome,
      "state" => render_state_snapshot(response),
      "echo" => params
    }

    %{
      "role" => "tool",
      "tool_call_id" => name, # This might need adjustment based on actual OpenAI response
      "name" => name,
      "content" => Jason.encode!(content)
    }
  end

  defp add_error_turn(conversation, name, params, response) do
    conversation ++
      [
        model_turn(name, params),
        tool_error_turn(name, params, response),
        user_turn(nil, response, :error)
      ]
  end

  defp tool_error_turn(name, params, response) do
    content = %{
      "status" => "error",
      "state" => render_state_snapshot(response),
      "echo" => params
    }

    %{
      "role" => "tool",
      "tool_call_id" => name,
      "name" => name,
      "content" => Jason.encode!(content)
    }
  end

  defp user_turn(user_text, response, :initial) do
    %{
      "role" => "user",
      "content" => "User request: #{user_text}\n" <> render_state_text(response)
    }
  end

  defp user_turn(_user_text, response, :error) do
    %{
      "role" => "user",
      "content" =>
        "The previous command failed. Review the error details and try another command.\n" <>
          render_state_text(response)
    }
  end

  defp user_turn(_user_text, response, :followup) do
    %{
      "role" => "user",
      "content" => "State updated. Provide the next command.\n" <> render_state_text(response)
    }
  end

  defp render_state_text(response) do
    # Organize for optimal prefix caching: static/semi-static content first, dynamic content last
    [
      # Semi-static: Available commands (only changes on state transitions)
      "Available commands:",
      render_commands(response.available_commands),
      "",
      # Semi-static: Recorded plans (grows but doesn't change existing entries)
      "Recorded plans:",
      render_plan_notes(response.plan_notes),
      "",
      # Dynamic: Pending operations (changes as operations are staged)
      "Pending operations:",
      render_ops(response.pending_operations),
      "",
      # Dynamic: Open tasks (changes frequently as tasks are modified)
      "Open tasks:",
      render_tasks(response.open_tasks),
      "",
      # Dynamic: Current state and status (changes every turn)
      "Current state: #{response.state}",
      "Error?: #{response.error?}",
      "Session message: #{response.message}"
    ]
    |> Enum.join("\n")
  end

  defp render_state_snapshot(response) do
    %{
      message: response.message,
      state: response.state,
      error: response.error?,
      open_tasks: response.open_tasks,
      pending_operations: response.pending_operations,
      plan_notes: response.plan_notes,
      available_commands: response.available_commands
    }
  end

  defp render_tasks(tasks) when is_list(tasks) do
    tasks
    |> Enum.map(fn task ->
      # Extract target and encode the entire task data
      target = Map.get(task, :target) || Map.get(task, "target") || "unknown"
      "- #{target}: #{Jason.encode!(task)}"
    end)
    |> Enum.join("\n")
  end

  defp render_tasks(_), do: "- none"

  defp render_ops(ops) when is_list(ops) do
    ops
    |> Enum.map(fn op ->
      type = Map.get(op, :type) || Map.get(op, "type")
      target = Map.get(op, :target) || Map.get(op, "target")
      params = Map.get(op, :params) || Map.get(op, "params")
      "- #{type} -> #{target} #{Jason.encode!(params)}"
    end)
    |> Enum.join("\n")
  end

  defp render_ops(_), do: "- none"

  defp render_plan_notes(notes) when is_list(notes) do
    notes
    |> Enum.map(fn note ->
      plan = Map.get(note, :plan) || Map.get(note, "plan")
      steps = Map.get(note, :steps) || Map.get(note, "steps") || []

      steps_text =
        steps
        |> Enum.map(&to_string/1)
        |> Enum.join(" | ")

      cond do
        plan && plan != "" && steps_text != "" -> "- #{plan} (steps: #{steps_text})"
        plan && plan != "" -> "- #{plan}"
        steps_text != "" -> "- steps: #{steps_text}"
        true -> "- (empty plan)"
      end
    end)
    |> Enum.join("\n")
  end

  defp render_plan_notes(_), do: "- none"

  defp render_commands(commands) when is_list(commands) do
    commands
    |> Enum.map(fn command ->
      name = command_name(command)
      desc = command_desc(command)
      params = Jason.encode!(command_params(command))
      "- #{name}: #{desc} | params: #{params}"
    end)
    |> Enum.join("\n")
  end

  defp render_commands(_), do: "- none"

  defp system_message(scope) do
    %{
      "role" => "system",
      "content" => system_prompt(scope)
    }
  end

  defp system_prompt(scope) do
    # Static base instructions (never changes - optimal for caching)
    base =
      """
      You manage SmartTodo tasks strictly through the provided function-call tools.
      ## Core Rules
      1. Every reply MUST be exactly one function call defined in `available_commands`.
      2. Read the state snapshot each turn; `available_commands` is the source of truth for what you can call.
      3. To change, complete, or delete an existing task you MUST call `select_task` first. Once a task is selected, the editing commands (update, complete, delete, exit_editing) become available. If you are not editing, those commands are unavailable.
      4. New tasks are staged with `create_task`; existing tasks accumulate staged changes until you `complete_session` (commit) or `discard_all`.
      5. Whenever solving the request requires more than one command, call `record_plan` first to capture the steps you intend to take.
      6. `complete_session` MUST be the final command you ever issue in a session; after calling it you may not send any further commands.
      ## Task Target Format
      - Existing tasks: "existing:123" where 123 is the task ID
      - Pending tasks: "pending:1" where 1 is the pending reference number
      - Use task_id parameter for existing tasks, pending_ref parameter for pending tasks
      ## Status Values
      - todo: Not started
      - in_progress: Currently being worked on
      - done: Completed (filtered from open tasks)
      ## Urgency Values
      - low, normal, high, critical
      ## Recurrence Values
      - none, daily, weekly, monthly, yearly
      """

    # Semi-static: User preferences (changes rarely)
    case preference_text(scope) do
      nil -> base
      preferences -> base <> "\n## User Preferences\n" <> preferences <> "\n"
    end
  end

  defp preference_text(%Scope{user: %{preference: %{prompt_preferences: pref}}})
       when is_binary(pref) and pref != "",
       do: pref

  defp preference_text(_), do: nil

  defp error_context(last_response, conversation, _body) do
    %{
      last_response: last_response,
      conversation: conversation
    }
  end
end
