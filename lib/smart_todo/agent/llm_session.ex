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

  @max_rounds 20
  @default_model "gemini-2.5-flash"
  @base_url "https://generativelanguage.googleapis.com/v1beta"

  @spec start(Scope.t(), String.t(), keyword()) :: {:ok, pid()}
  def start(scope, user_text, opts \\ []) do
    Task.Supervisor.start_child(SmartTodo.Agent.TaskSupervisor, fn ->
      run(scope, user_text, opts)
    end)
  end

  @spec run(Scope.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term(), map()}
  def run(scope, user_text, opts \\ []) do
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
       user_text: user_text
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

    if round >= max_rounds do
      {:error, :max_rounds, failure_context(ctx)}
    else
      tools = tools_from_response(ctx.last_response)

      payload =
        %{
          "systemInstruction" => %{"role" => "system", "parts" => [%{"text" => system_prompt(ctx.scope)}]},
          "contents" => ctx.conversation,
          "tools" => [%{"functionDeclarations" => tools}],
          "toolConfig" => %{"functionCallingConfig" => %{"mode" => "ANY"}}
        }

      with {:ok, call, body} <- request_command(payload, ctx.last_response, opts),
           {:ok, after_call} <- apply_command(ctx, call, body) do
        conversation_loop(after_call, opts, round + 1)
      else
        {:error, reason, extra} -> {:error, reason, failure_context(ctx, extra)}
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
        updated =
          ctx
          |> Map.put(:machine, machine)
          |> Map.put(:last_response, response)
          |> Map.put(:conversation, add_error_turn(ctx.conversation, command, params, response))

        {:error, {:state_machine, command},
         %{
           machine: machine,
           last_response: response,
           executed: Enum.reverse(ctx.executed),
           conversation: updated.conversation
         }}
    end
  end

  defp command_entry(command, params) do
    %{name: command, params: params}
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
      conversation: ctx.conversation
    }

    Map.merge(base, extra)
  end

  defp call_model(payload, opts) do
    url = model_endpoint(Keyword.get(opts, :model, @default_model), opts)
    request_fun = Keyword.get(opts, :request_fun, &default_request/3)

    request_fun.(url, payload, opts)
  end

  defp default_request(url, payload, opts) do
    api_key = Keyword.get(opts, :api_key, api_key!())

    case Req.post(url: url, params: %{key: api_key}, json: payload) do
      {:ok, %Req.Response{status: 200, body: body}} -> {:ok, body}
      {:ok, %Req.Response{status: status, body: body}} -> {:error, {:http_error, status, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp api_key! do
    case System.get_env("GEMINI_API_KEY") do
      nil -> raise "Environment variable GEMINI_API_KEY is required"
      key -> key
    end
  end

  defp model_endpoint(model, opts) do
    base = Keyword.get(opts, :base_url, @base_url)
    "#{base}/models/#{model}:generateContent"
  end

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

  @supported_commands ~w(select_task create_task update_task_fields delete_task complete_task exit_editing discard_all complete_session)a

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
    params = command_params(command)

    properties =
      Enum.into(params, %{}, fn {key, desc} ->
        {key, %{"type" => "string", "description" => desc}}
      end)

    required =
      params
      |> Enum.filter(fn {_key, desc} -> String.contains?(String.downcase(desc), "required") end)
      |> Enum.map(fn {key, _} -> key end)

    base = %{"type" => "object", "properties" => properties}

    if required == [] do
      base
    else
      Map.put(base, "required", required)
    end
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

  defp add_error_turn(conversation, command, params, response) do
    tool_message =
      %{
        "role" => "tool",
        "parts" => [
          %{
            "functionResponse" => %{
              "name" => Atom.to_string(command),
              "response" => %{
                "status" => "error",
                "state" => render_state_snapshot(response),
                "echo" => params
              }
            }
          }
        ]
      }

    conversation ++ [tool_message]
  end

  defp user_turn(user_text, response, :initial) do
    %{
      "role" => "user",
      "parts" => [%{"text" => "User request: #{user_text}\n" <> render_state_text(response)}]
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
      5. Keep issuing calls until the session confirms completion or reports an error. Never send free-form text.
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
