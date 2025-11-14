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
  alias SmartTodo.Agent.LlamaCppAdapter
  alias Req

  require Logger

  @status_options ~w(todo in_progress done)a
  @urgency_options ~w(low normal high critical)a
  @recurrence_options ~w(none daily weekly monthly yearly)a

  @max_errors 3
  @max_rounds 20
  @default_model "qwen2.5-3b-instruct"
  @base_url "https://llama-cpp.rackspace.koski.co"
  @helicone_base_url "https://gateway.helicone.ai/v1beta"
  @helicone_target_url "https://generativelanguage.googleapis.com"
  @helicone_default_properties %{"App" => "smart_todo"}
  @default_receive_timeout :timer.minutes(10)

  @spec start(Scope.t(), String.t(), keyword()) :: {:ok, pid()}
  def start(scope, user_text, opts \\ []) do
    Task.Supervisor.start_child(SmartTodo.Agent.TaskSupervisor, fn ->
      run(scope, user_text, opts)
    end)
  end

  @spec run(Scope.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term(), map()}
  def run(scope, user_text, opts \\ []) do
    opts = ensure_default_timeouts(opts)

    with {:ok, initial} <- build_initial_session(scope, user_text),
         {:ok, result} <- conversation_loop(initial, opts) do
      {:ok, result}
    else
      {:error, reason, ctx} ->
        {:error, reason, ctx}
    end
  end

  defp build_initial_session(scope, user_text) do
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
       errors: 0
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

        payload =
          %{
            "systemInstruction" => %{
              "role" => "system",
              "parts" => [%{"text" => system_prompt(ctx.scope)}]
            },
            "contents" => ctx.conversation,
            "tools" => [%{"functionDeclarations" => tools}],
            "toolConfig" => %{"functionCallingConfig" => %{"mode" => "ANY"}}
          }

        request_opts = maybe_put_scope_helicone_properties(opts, ctx.scope)

        case request_command(payload, ctx.last_response, request_opts) do
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
    helicone = helicone_settings(opts)
    url = model_endpoint(Keyword.get(opts, :model, @default_model), opts, helicone)
    request_fun = Keyword.get(opts, :request_fun, &default_request/3)
    request_opts = prepare_request_opts(opts, helicone)

    request_fun.(url, payload, request_opts)
  end

  defp default_request(url, payload, opts) do
    # Check if this is a Gemini API or a llama.cpp server
    using_gemini_api? =
      String.contains?(url, "generativelanguage.googleapis.com") or
      String.contains?(url, "helicone")

    if using_gemini_api? do
      gemini_request(url, payload, opts)
    else
      # Use adapter for llama.cpp servers
      Logger.info("Using LlamaCppAdapter for non-Gemini server", url: url)

      # Model configuration is handled by the adapter (via LLAMA_CPP_MODEL env var or default)
      LlamaCppAdapter.request(url, payload, opts)
    end
  end

  defp gemini_request(url, payload, opts) do
    api_key_value = Keyword.get(opts, :api_key, api_key())
    headers = normalize_headers(Keyword.get(opts, :headers, []))
    timeout = Keyword.get(opts, :receive_timeout, default_receive_timeout())

    request_options =
      [
        url: url,
        json: payload,
        receive_timeout: timeout
      ]
      |> maybe_put_api_key(api_key_value)
      |> maybe_put_headers(headers)

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
        {:ok, body}

      {:ok, %Req.Response{status: status, body: body}} ->
        Logger.error("LLM HTTP error",
          url: url,
          status: status,
          body: inspect(body, limit: 500),
          error_type: :http_error
        )

        {:error, {:http_error, status, body}}

      {:error, reason} ->
        Logger.error("LLM connection failed",
          url: url,
          timeout_ms: timeout,
          reason: inspect(reason, limit: 500),
          error_type: classify_error(reason)
        )

        {:error, reason}
    end
  end

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
    present(System.get_env("GEMINI_API_KEY")) || present(System.get_env("GOOGLE_API_KEY"))
  end

  defp model_endpoint(model, opts, helicone) do
    base =
      case Keyword.get(opts, :base_url) do
        nil ->
          case helicone do
            %{base_url: base_url} ->
              base_url

            _ ->
              Application.get_env(:smart_todo, :llm, [])
              |> Keyword.get(:base_url, @base_url)
          end

        base_url ->
          base_url
      end

    "#{base}/models/#{model}:generateContent"
  end

  defp prepare_request_opts(opts, helicone) do
    opts
    |> Keyword.put_new_lazy(:receive_timeout, &default_receive_timeout/0)
    |> maybe_attach_helicone_headers(helicone)
  end

  defp maybe_put_scope_helicone_properties(opts, %Scope{user: %{id: id}}) when not is_nil(id) do
    properties =
      opts
      |> Keyword.get(:helicone_properties, %{})
      |> normalize_properties()
      |> Map.put_new("UserId", id)

    Keyword.put(opts, :helicone_properties, properties)
  end

  defp maybe_put_scope_helicone_properties(opts, _), do: opts

  defp maybe_attach_helicone_headers(opts, nil), do: opts

  defp maybe_attach_helicone_headers(opts, %{api_key: key, target_url: target, properties: props}) do
    existing_headers =
      opts
      |> Keyword.get(:headers, [])
      |> normalize_headers()
      |> Enum.reject(&helicone_header?/1)

    headers = helicone_header_list(key, target, props) ++ existing_headers

    opts
    |> Keyword.put(:headers, headers)
    |> Keyword.put(:helicone_api_key, key)
    |> Keyword.put(:helicone_target_url, target)
    |> Keyword.put(:helicone_properties, props)
  end

  defp helicone_settings(opts) do
    # Get the configured LLM base URL to determine if we should use Helicone
    configured_base_url =
      opts
      |> Keyword.get(:base_url)
      |> present() ||
        (Application.get_env(:smart_todo, :llm, [])
         |> Keyword.get(:base_url, @base_url))

    # Only use Helicone with Google's Gemini API, not with self-hosted servers
    using_gemini_api? = String.contains?(configured_base_url, "generativelanguage.googleapis.com")

    key =
      opts
      |> Keyword.get(:helicone_api_key)
      |> present() ||
        present(System.get_env("HELICONE_API_KEY"))

    case key do
      nil ->
        nil

      key when using_gemini_api? ->
        base_url =
          opts
          |> Keyword.get(:helicone_base_url)
          |> present() ||
            present(System.get_env("HELICONE_BASE_URL")) ||
            @helicone_base_url

        target_url =
          opts
          |> Keyword.get(:helicone_target_url)
          |> present() ||
            present(System.get_env("HELICONE_TARGET_URL")) ||
            @helicone_target_url

        properties =
          @helicone_default_properties
          |> Map.merge(normalize_properties(Keyword.get(opts, :helicone_properties, %{})))

        %{api_key: key, base_url: base_url, target_url: target_url, properties: properties}

      _key ->
        # Helicone API key is set but we're not using Gemini API, so ignore Helicone
        Logger.info("Helicone API key is set but not using Gemini API (base_url: #{configured_base_url}), bypassing Helicone")
        nil
    end
  end

  defp helicone_header_list(key, target, props) do
    base_headers = [
      {"Helicone-Auth", "Bearer #{key}"},
      {"Helicone-Target-URL", target}
    ]

    property_headers =
      props
      |> Enum.map(fn {name, value} ->
        {"Helicone-Property-#{name}", to_string(value)}
      end)

    base_headers ++ property_headers
  end

  defp helicone_header?({"Helicone-" <> _, _}), do: true
  defp helicone_header?(_), do: false

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

  defp normalize_properties(%{} = props), do: props
  defp normalize_properties(props) when is_list(props), do: Enum.into(props, %{})
  defp normalize_properties(_), do: %{}

  defp present(value) when value in [nil, ""], do: nil
  defp present(value), do: value

  defp maybe_put_api_key(opts, nil), do: opts
  defp maybe_put_api_key(opts, key), do: Keyword.put(opts, :params, %{key: key})

  defp maybe_put_headers(opts, []), do: Keyword.delete(opts, :headers)
  defp maybe_put_headers(opts, headers), do: Keyword.put(opts, :headers, headers)

  defp extract_function_call(%{"candidates" => [candidate | _]}) do
    parts = get_in(candidate, ["content", "parts"]) || []

    case Enum.find(parts, &Map.has_key?(&1, "functionCall")) do
      %{"functionCall" => %{"name" => name, "args" => args}} ->
        {:ok, %{command: name, params: normalize_args(args)}}

      _ ->
        {:error, :no_function_call}
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
        "name" => command_name(command),
        "description" => command_desc(command),
        "parameters" => tool_parameters(command)
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
      "role" => "model",
      "parts" => [
        %{
          "functionCall" => %{
            "name" => name,
            "args" => params
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

    %{
      "role" => "tool",
      "parts" => [
        %{
          "functionResponse" => %{
            "name" => name,
            "response" => %{
              "status" => outcome,
              "state" => render_state_snapshot(response),
              "echo" => params
            }
          }
        }
      ]
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
    %{
      "role" => "tool",
      "parts" => [
        %{
          "functionResponse" => %{
            "name" => name,
            "response" => %{
              "status" => "error",
              "state" => render_state_snapshot(response),
              "echo" => params
            }
          }
        }
      ]
    }
  end

  defp user_turn(user_text, response, :initial) do
    %{
      "role" => "user",
      "parts" => [%{"text" => "User request: #{user_text}\n" <> render_state_text(response)}]
    }
  end

  defp user_turn(_user_text, response, :error) do
    %{
      "role" => "user",
      "parts" => [
        %{
          "text" =>
            "The previous command failed. Review the error details and try another command.\n" <>
              render_state_text(response)
        }
      ]
    }
  end

  defp user_turn(_user_text, response, :followup) do
    %{
      "role" => "user",
      "parts" => [
        %{"text" => "State updated. Provide the next command.\n" <> render_state_text(response)}
      ]
    }
  end

  defp render_state_text(response) do
    [
      "Session message: #{response.message}",
      "State: #{response.state}",
      "Error?: #{response.error?}",
      "Open tasks:",
      render_tasks(response.open_tasks),
      "Pending operations:",
      render_ops(response.pending_operations),
      "Recorded plans:",
      render_plan_notes(response.plan_notes),
      "Available commands:",
      render_commands(response.available_commands)
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
      data = Map.get(task, :data) || Map.get(task, "data")
      target = Map.get(task, :target) || Map.get(task, "target")
      "- #{target}: #{Jason.encode!(data)}"
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

  defp system_prompt(scope) do
    base =
      """
      You manage SmartTodo tasks strictly through the provided function-call tools. Follow these rules:
      1. Every reply MUST be exactly one function call defined in `available_commands`.
      2. Read the state snapshot each turn; `available_commands` is the source of truth for what you can call.
      3. To change, complete, or delete an existing task you MUST call `select_task` first. Once a task is selected, the editing commands (update, complete, delete, exit_editing) become available. If you are not editing, those commands are unavailable.
      4. New tasks are staged with `create_task`; existing tasks accumulate staged changes until you `complete_session` (commit) or `discard_all`.
      5. Whenever solving the request requires more than one command, call `record_plan` first to capture the steps you intend to take.
      6. `complete_session` MUST be the final command you ever issue in a session; after calling it you may not send any further commands.
      """

    case preference_text(scope) do
      nil -> base
      preferences -> base <> "\n\nUser preferences:\n" <> preferences
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
