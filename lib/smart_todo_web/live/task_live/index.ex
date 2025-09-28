defmodule SmartTodoWeb.TaskLive.Index do
  use SmartTodoWeb, :live_view

  alias SmartTodo.{Tasks, Accounts}
  alias SmartTodo.Tasks.Task

  require Logger

  @impl true
  def mount(_params, _session, socket) do
    current_scope = socket.assigns.current_scope
    tasks = Tasks.list_tasks(current_scope)
    groups = Accounts.list_groups()
    assignment_opts = assignment_options(current_scope.user, groups)

    form =
      %Task{}
      |> Tasks.change_task()
      |> to_form()

    socket =
      socket
      |> assign(:page_title, "My Tasks")
      |> assign(:advanced_open?, false)
      |> assign(:quick_form, quick_form_with(""))
      |> assign(:selected_prereq_ids, [])
      |> assign(:form, form)
      |> assign(:editing_task_id, nil)
      |> assign(:edit_form, nil)
      |> assign(:edit_selected_prereq_ids, [])
      |> assign(:edit_assignment_selection, nil)
      |> assign(:assignment_selection, "")
      |> assign(:defer_option_selection, "")
      |> assign(:edit_defer_option_selection, nil)
      |> assign(:show_completed?, false)
      |> assign(:prereq_options, prereq_options(tasks))
      |> assign(:assignment_options, assignment_opts)
      |> assign(:automation_status, :idle)
      |> assign(:automation_job_ref, nil)

    {:ok, assign_task_lists(socket, tasks)}
  end

  @impl true
  def handle_event("validate", %{"task" => params}, socket) do
    assignment_value = Map.get(params, "assignment_target", "")
    defer_option = Map.get(params, "defer_option", "")
    normalized_params = normalize_task_params(params, :create)

    form =
      %Task{}
      |> Tasks.change_task(normalized_params)
      |> Map.put(:action, :validate)
      |> to_form()

    selected = Map.get(params, "prerequisite_ids", [])

    {:noreply,
     socket
     |> assign(:form, form)
     |> assign(:selected_prereq_ids, selected)
     |> assign(:assignment_selection, assignment_value)
     |> assign(:defer_option_selection, defer_option)}
  end

  @impl true
  def handle_event("toggle_advanced", _params, socket) do
    {:noreply, update(socket, :advanced_open?, &(!&1))}
  end

  @impl true
  def handle_event("quick_save", %{"quick_task" => %{"title" => raw_title}}, socket) do
    normalized =
      case raw_title do
        nil -> ""
        value when is_binary(value) -> value
        value -> to_string(value)
      end

    prompt = String.trim(normalized)

    cond do
      prompt == "" ->
        {:noreply,
         socket
         |> put_flash(:error, "Title can't be blank")
         |> assign(:quick_form, quick_form_with(normalized))}

      socket.assigns.automation_status == :running ->
        {:noreply,
         socket
         |> put_flash(:error, "Automation is already running. Please wait.")
         |> assign(:quick_form, quick_form_with(normalized))}

      true ->
        case start_automation(socket, prompt) do
          {:ok, ref} ->
            {:noreply,
             socket
             |> put_flash(:info, "Automation in progress...")
             |> assign(:quick_form, quick_form_with(""))
             |> assign(:automation_status, :running)
             |> assign(:automation_job_ref, ref)}

          {:error, reason} ->
            {:noreply,
             socket
             |> put_flash(:error, start_error_message(reason))
             |> assign(:quick_form, quick_form_with(normalized))}
        end
    end
  end

  @impl true
  def handle_event("save", %{"task" => params}, socket) do
    assignment_value = Map.get(params, "assignment_target", "")
    defer_option = Map.get(params, "defer_option", "")
    normalized_params = normalize_task_params(params, :create)

    case Tasks.create_task(socket.assigns.current_scope, normalized_params) do
      {:ok, _task} ->
        tasks = Tasks.list_tasks(socket.assigns.current_scope)
        groups = Accounts.list_groups()
        assignment_opts = assignment_options(socket.assigns.current_scope.user, groups)

        {:noreply,
         socket
         |> put_flash(:info, "Task created")
         |> assign(:advanced_open?, false)
         |> assign(:selected_prereq_ids, [])
         |> assign(:form, %Task{} |> Tasks.change_task() |> to_form())
         |> assign(:assignment_selection, "")
         |> assign(:defer_option_selection, "")
         |> assign(:prereq_options, prereq_options(tasks))
         |> assign(:assignment_options, assignment_opts)
         |> assign_task_lists(tasks, reset: true)}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply,
         socket
         |> assign(:form, to_form(changeset))
         |> assign(:assignment_selection, assignment_value)
         |> assign(:defer_option_selection, defer_option)}
    end
  end

  @impl true
  def handle_event("toggle_done", %{"id" => id}, socket) do
    task = Tasks.get_task!(socket.assigns.current_scope, String.to_integer(id))

    result =
      case task.status do
        :done -> Tasks.update_task(socket.assigns.current_scope, task, %{status: :todo})
        _ -> Tasks.complete_task(socket.assigns.current_scope, task)
      end

    case result do
      {:ok, _task_or_val} ->
        tasks = Tasks.list_tasks(socket.assigns.current_scope)

        {:noreply,
         socket
         |> assign_task_lists(tasks, reset: true)}

      {:error, %Ecto.Changeset{} = _cs} ->
        {:noreply,
         put_flash(socket, :error, "Cannot complete task with incomplete prerequisites")}
    end
  end

  @impl true
  def handle_event("toggle_completed", _params, socket) do
    {:noreply, update(socket, :show_completed?, &(!&1))}
  end

  @impl true
  def handle_event("edit_task", %{"id" => id}, socket) do
    task = Tasks.get_task!(socket.assigns.current_scope, String.to_integer(id))

    form =
      task
      |> Tasks.change_task()
      |> to_form()

    selected = Enum.map(task.prerequisites, &Integer.to_string(&1.id))
    assignment_value = assignment_value_for(task)

    {:noreply,
     socket
     |> assign(:editing_task_id, task.id)
     |> assign(:edit_form, form)
     |> assign(:edit_selected_prereq_ids, selected)
     |> assign(:edit_assignment_selection, assignment_value)
     |> assign(:edit_defer_option_selection, "")
     |> assign(:advanced_open?, false)}
  end

  @impl true
  def handle_event("cancel_edit", _params, socket) do
    {:noreply,
     socket
     |> assign(:editing_task_id, nil)
     |> assign(:edit_form, nil)
     |> assign(:edit_selected_prereq_ids, [])
     |> assign(:edit_assignment_selection, nil)
     |> assign(:edit_defer_option_selection, nil)}
  end

  @impl true
  def handle_event("edit_validate", %{"task" => params}, socket) do
    case socket.assigns.edit_form do
      nil ->
        {:noreply, socket}

      form ->
        assignment_value =
          Map.get(params, "assignment_target", socket.assigns.edit_assignment_selection || "")

        defer_option =
          Map.get(params, "defer_option", socket.assigns.edit_defer_option_selection || "")

        normalized_params = normalize_task_params(params, :update, task: form.source.data)

        changeset =
          form.source.data
          |> Tasks.change_task(normalized_params)
          |> Map.put(:action, :validate)

        {:noreply,
         socket
         |> assign(:edit_form, to_form(changeset))
         |> assign(:edit_selected_prereq_ids, Map.get(params, "prerequisite_ids", []))
         |> assign(:edit_assignment_selection, assignment_value)
         |> assign(:edit_defer_option_selection, defer_option)}
    end
  end

  @impl true
  def handle_event("update_task", %{"task" => params}, socket) do
    case socket.assigns.editing_task_id do
      nil ->
        {:noreply, socket}

      task_id ->
        task = Tasks.get_task!(socket.assigns.current_scope, task_id)
        assignment_value = Map.get(params, "assignment_target", "")
        defer_option = Map.get(params, "defer_option", "")
        normalized_params = normalize_task_params(params, :update, task: task)

        case Tasks.update_task(socket.assigns.current_scope, task, normalized_params) do
          {:ok, _task} ->
            tasks = Tasks.list_tasks(socket.assigns.current_scope)
            groups = Accounts.list_groups()
            assignment_opts = assignment_options(socket.assigns.current_scope.user, groups)

            socket =
              socket
              |> put_flash(:info, "Task updated")
              |> assign(:prereq_options, prereq_options(tasks))
              |> assign(:assignment_options, assignment_opts)
              |> assign(:editing_task_id, nil)
              |> assign(:edit_form, nil)
              |> assign(:edit_selected_prereq_ids, [])
              |> assign(:edit_assignment_selection, nil)
              |> assign(:edit_defer_option_selection, nil)

            {:noreply, assign_task_lists(socket, tasks, reset: true)}

          {:error, %Ecto.Changeset{} = changeset} ->
            {:noreply,
             socket
             |> assign(:edit_form, to_form(changeset))
             |> assign(:edit_selected_prereq_ids, Map.get(params, "prerequisite_ids", []))
             |> assign(:edit_assignment_selection, assignment_value)
             |> assign(:edit_defer_option_selection, defer_option)}
        end
    end
  end

  @impl true
  def handle_event("break_down_task", %{"id" => id}, socket) do
    cond do
      socket.assigns.automation_status == :running ->
        {:noreply,
         socket
         |> put_flash(:error, "Automation is already running. Please wait.")}

      true ->
        task =
          socket.assigns.current_scope
          |> Tasks.get_task!(String.to_integer(id))

        case start_breakdown(socket, task) do
          {:ok, ref} ->
            {:noreply,
             socket
             |> put_flash(:info, "Breaking the task into smaller steps...")
             |> assign(:automation_status, :running)
             |> assign(:automation_job_ref, ref)
             |> assign(:editing_task_id, nil)
             |> assign(:edit_form, nil)
             |> assign(:edit_selected_prereq_ids, [])
             |> assign(:edit_assignment_selection, nil)
             |> assign(:edit_defer_option_selection, nil)}

          {:error, reason} ->
            {:noreply,
             socket
             |> put_flash(:error, start_error_message(reason))}
        end
    end
  end

  @impl true
  def handle_event("trash_task", %{"id" => id}, socket) do
    task_id = String.to_integer(id)

    case Tasks.delete_task(socket.assigns.current_scope, task_id) do
      {:ok, deleted_task} ->
        tasks = Tasks.list_tasks(socket.assigns.current_scope)
        groups = Accounts.list_groups()
        assignment_opts = assignment_options(socket.assigns.current_scope.user, groups)

        socket =
          socket
          |> put_flash(:info, "Task deleted")
          |> assign(:prereq_options, prereq_options(tasks))
          |> assign(:assignment_options, assignment_opts)

        socket =
          if socket.assigns.editing_task_id == deleted_task.id do
            socket
            |> assign(:editing_task_id, nil)
            |> assign(:edit_form, nil)
            |> assign(:edit_selected_prereq_ids, [])
            |> assign(:edit_defer_option_selection, nil)
            |> assign(:edit_assignment_selection, nil)
          else
            socket
          end

        {:noreply, assign_task_lists(socket, tasks, reset: true)}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Could not delete task")}
    end
  end

  @impl true
  def handle_info(
        {:llm_session_result, ref, {:ok, result}},
        %{assigns: %{automation_job_ref: ref}} = socket
      ) do
    socket =
      socket
      |> finish_automation()
      |> put_flash(:info, automation_success_message(result))

    {:noreply, socket}
  end

  @impl true
  def handle_info(
        {:llm_session_result, ref, {:error, reason, ctx}},
        %{assigns: %{automation_job_ref: ref}} = socket
      ) do
    log_automation_failure(reason, ctx)

    socket =
      socket
      |> finish_automation()
      |> put_flash(:error, automation_error_message(reason))

    {:noreply, socket}
  end

  @impl true
  def handle_info(
        {:llm_session_result, ref, {:exception, exception, stack}},
        %{assigns: %{automation_job_ref: ref}} = socket
      ) do
    Logger.error("LLM automation crashed\n" <> Exception.format(:error, exception, stack))

    socket =
      socket
      |> finish_automation()
      |> put_flash(:error, "Automation encountered an unexpected error.")

    {:noreply, socket}
  end

  @impl true
  def handle_info(
        {:llm_session_result, ref, {:exit, reason}},
        %{assigns: %{automation_job_ref: ref}} = socket
      ) do
    Logger.error("LLM automation exited unexpectedly: #{inspect(reason)}")

    socket =
      socket
      |> finish_automation()
      |> put_flash(:error, "Automation exited unexpectedly.")

    {:noreply, socket}
  end

  @impl true
  def handle_info(
        {:llm_session_result, ref, {:caught, {kind, reason}}},
        %{assigns: %{automation_job_ref: ref}} = socket
      ) do
    Logger.error("LLM automation caught #{inspect(kind)}: #{inspect(reason)}")

    socket =
      socket
      |> finish_automation()
      |> put_flash(:error, "Automation was interrupted.")

    {:noreply, socket}
  end

  @impl true
  def handle_info({:llm_session_result, _ref, _result}, socket) do
    {:noreply, socket}
  end

  defp quick_form_with(value) do
    to_form(%{"title" => value}, as: "quick_task")
  end

  defp start_breakdown(socket, task) do
    prompt = build_breakdown_prompt(task)
    start_automation(socket, prompt)
  end

  defp start_automation(socket, prompt) do
    caller = self()
    ref = make_ref()
    scope = socket.assigns.current_scope

    start_result =
      Elixir.Task.Supervisor.start_child(SmartTodo.Agent.TaskSupervisor, fn ->
        result =
          try do
            invoke_llm_runner(scope, prompt)
          rescue
            exception ->
              {:exception, exception, __STACKTRACE__}
          catch
            :exit, reason ->
              {:exit, reason}

            kind, reason ->
              {:caught, {kind, reason}}
          end

        send(caller, {:llm_session_result, ref, result})
      end)

    case start_result do
      {:ok, _pid} -> {:ok, ref}
      {:ok, _pid, _info} -> {:ok, ref}
      {:error, reason} -> {:error, reason}
    end
  end

  defp start_error_message(reason) do
    "Could not start automation: #{inspect(reason)}"
  end

  defp finish_automation(socket) do
    socket
    |> assign(:automation_status, :idle)
    |> assign(:automation_job_ref, nil)
    |> refresh_tasks()
  end

  defp refresh_tasks(socket) do
    tasks = Tasks.list_tasks(socket.assigns.current_scope)
    groups = Accounts.list_groups()
    assignment_opts = assignment_options(socket.assigns.current_scope.user, groups)

    socket
    |> assign(:prereq_options, prereq_options(tasks))
    |> assign(:assignment_options, assignment_opts)
    |> assign_task_lists(tasks, reset: true)
  end

  defp automation_success_message(%{executed: executed}) do
    commands =
      executed
      |> Enum.map(&executed_name/1)
      |> Enum.reject(&is_nil/1)

    case commands do
      [] -> "Automation completed with no changes."
      _ -> "Automation completed (commands: #{Enum.join(commands, ", ")})."
    end
  end

  defp automation_success_message(_), do: "Automation completed."

  defp executed_name(entry) do
    entry
    |> Map.get(:name)
    |> case do
      nil -> Map.get(entry, "name")
      name -> name
    end
    |> case do
      nil -> nil
      name when is_atom(name) -> Phoenix.Naming.humanize(name)
      name when is_binary(name) -> Phoenix.Naming.humanize(name)
      _ -> nil
    end
  end

  defp automation_error_message({:unsupported_command, name}) do
    "Automation failed: command #{name} is not available right now."
  end

  defp automation_error_message(:max_rounds) do
    "Automation stopped after reaching the maximum round limit."
  end

  defp automation_error_message({:http_error, status, _body}) do
    "Automation failed due to an HTTP #{status} response from Gemini."
  end

  defp automation_error_message(reason) when is_atom(reason) do
    "Automation failed: #{Phoenix.Naming.humanize(reason)}."
  end

  defp automation_error_message(reason) do
    "Automation failed: #{inspect(reason)}."
  end

  defp llm_runner do
    Application.get_env(:smart_todo, :llm_runner, SmartTodo.Agent.LlmSession)
  end

  defp invoke_llm_runner(scope, prompt) do
    case llm_runner() do
      {module, extra} when is_atom(module) ->
        apply(module, :run, [scope, prompt, extra])

      module when is_atom(module) ->
        apply(module, :run, [scope, prompt])

      fun when is_function(fun, 2) ->
        fun.(scope, prompt)

      other ->
        raise ArgumentError, "Invalid :llm_runner configuration: #{inspect(other)}"
    end
  end

  defp prereq_options(tasks) do
    Enum.map(tasks, fn t -> {t.title, t.id} end)
  end

  defp assignment_options(user, groups) do
    user_option = {"Me", "user:#{user.id}"}

    group_options =
      Enum.map(groups, fn g -> {"Group: #{g.name}", "group:#{g.id}"} end)

    [user_option | group_options]
  end

  defp defer_option_options do
    [
      {"Tomorrow", "tomorrow"},
      {"Next week", "next_week"},
      {"In two weeks", "two_weeks"},
      {"1 week before due date", "due_minus_week"},
      {"Clear deferral", "clear"}
    ]
  end

  defp build_breakdown_prompt(task) do
    notes_prefix = "Single step in the task #{task.title}: "
    prerequisites = Enum.map(task.prerequisites, & &1.id)
    dependents = Enum.map(task.dependents, & &1.id)

    [
      "You are operating the SmartTodo task state machine.",
      "The user wants to break the existing task into a sequenced set of smaller tasks.",
      "Existing task reference: existing:#{task.id}",
      "",
      "Task context:",
      format_line("Title", task.title),
      format_line("Description", task.description),
      format_line("Notes", task.notes),
      format_line("Due date", task.due_date),
      format_line("Deferred until", task.deferred_until),
      format_line("Urgency", task.urgency),
      format_line("Recurrence", task.recurrence),
      format_assignment(task),
      format_id_list("Current prerequisites", prerequisites),
      format_id_list("Direct dependents", dependents),
      "",
      "Requirements:",
      "1. Create at least two new tasks that, in order, accomplish the same overall outcome as the original task.",
      "2. Each new task must include notes beginning with \"#{notes_prefix}\" followed by a short step-specific explanation.",
      "3. Preserve the original assignment, urgency, due date, deferred_until, and recurrence values on each new task.",
      "4. Apply the original prerequisites (if any) to the first new task. For each subsequent new task, set the immediately previous new task as its prerequisite so the steps run in sequence.",
      "5. After creating the replacements, update every dependent listed above to depend on the final new task instead of the original.",
      "6. Delete the original task once replacements are staged.",
      "7. Review your staged operations and finish with complete_session to persist the changes.",
      "",
      "When issuing commands, reference existing tasks as existing:<id> and pending tasks as pending:<ref>."
    ]
    |> Enum.join("\n")
  end

  defp format_line(label, value) do
    "- #{label}: #{describe_value(value)}"
  end

  defp format_assignment(%Task{assignee_id: assignee_id, assigned_group_id: group_id}) do
    cond do
      assignee_id -> "- Assignment: user_id #{assignee_id}"
      group_id -> "- Assignment: group_id #{group_id}"
      true -> "- Assignment: (none)"
    end
  end

  defp format_id_list(label, []), do: "- #{label}: (none)"

  defp format_id_list(label, ids) do
    formatted = ids |> Enum.map(&"existing:#{&1}") |> Enum.join(", ")
    "- #{label}: #{formatted}"
  end

  defp describe_value(nil), do: "(none)"

  defp describe_value(value) when is_binary(value) do
    case String.trim(value) do
      "" -> "(none)"
      trimmed -> trimmed
    end
  end

  defp describe_value(%Date{} = date), do: Date.to_iso8601(date)
  defp describe_value(value) when is_atom(value), do: Atom.to_string(value)
  defp describe_value(value), do: inspect(value)

  defp assignment_value_for(%Task{assignee_id: assignee_id, assigned_group_id: group_id}) do
    cond do
      assignee_id -> "user:#{assignee_id}"
      group_id -> "group:#{group_id}"
      true -> ""
    end
  end

  defp normalize_task_params(params, mode, opts \\ []) do
    params
    |> normalize_assignment_params(mode)
    |> normalize_defer_params(mode, opts)
  end

  defp normalize_assignment_params(params, mode) do
    {assignment_value, params} = pop_assignment_target(params)

    params =
      params
      |> Map.delete("assignee_id")
      |> Map.delete(:assignee_id)
      |> Map.delete("assigned_group_id")
      |> Map.delete(:assigned_group_id)

    case assignment_value do
      nil ->
        params

      "" ->
        case mode do
          :create ->
            params

          :update ->
            params
            |> Map.put("assignee_id", nil)
            |> Map.put("assigned_group_id", nil)
        end

      "user:" <> id ->
        params
        |> Map.put("assignee_id", id)
        |> Map.put("assigned_group_id", nil)

      "group:" <> id ->
        params
        |> Map.put("assignee_id", nil)
        |> Map.put("assigned_group_id", id)

      _ ->
        params
    end
  end

  defp normalize_defer_params(params, _mode, opts) do
    manual_value = Map.get(params, "deferred_until") || Map.get(params, :deferred_until)

    params =
      params
      |> Map.delete(:deferred_until)
      |> nilify_empty("deferred_until")

    {defer_option, params} = pop_defer_option(params)

    cond do
      manual_value not in [nil, ""] ->
        params

      defer_option in [nil, ""] ->
        params

      defer_option == "clear" ->
        params
        |> Map.put("deferred_until", nil)

      true ->
        due_date = resolve_due_date(params, opts)

        case apply_defer_option(defer_option, due_date) do
          {:ok, date} ->
            iso = Date.to_iso8601(date)

            Map.put(params, "deferred_until", iso)

          :error ->
            params
        end
    end
  end

  defp pop_assignment_target(params) do
    {value_string, params} = Map.pop(params, "assignment_target")
    {value_atom, params} = Map.pop(params, :assignment_target)
    {value_string || value_atom, params}
  end

  defp pop_defer_option(params) do
    {option_string, params} = Map.pop(params, "defer_option")
    {option_atom, params} = Map.pop(params, :defer_option)
    {option_string || option_atom, params}
  end

  defp nilify_empty(map, key) do
    case Map.get(map, key) do
      "" -> Map.put(map, key, nil)
      _ -> map
    end
  end

  defp resolve_due_date(params, opts) do
    with nil <- parse_date(Map.get(params, "due_date")),
         nil <- parse_date(Map.get(params, :due_date)) do
      case Keyword.get(opts, :task) do
        %Task{due_date: %Date{} = due_date} -> due_date
        _ -> nil
      end
    else
      date -> date
    end
  end

  defp parse_date(%Date{} = date), do: date

  defp parse_date(value) when is_binary(value) do
    value
    |> String.trim()
    |> case do
      "" ->
        nil

      trimmed ->
        case Date.from_iso8601(trimmed) do
          {:ok, date} -> date
          _ -> nil
        end
    end
  end

  defp parse_date(_), do: nil

  defp apply_defer_option("tomorrow", _due_date) do
    {:ok, Date.add(Date.utc_today(), 1)}
  end

  defp apply_defer_option("next_week", _due_date) do
    {:ok, Date.add(Date.utc_today(), 7)}
  end

  defp apply_defer_option("two_weeks", _due_date) do
    {:ok, Date.add(Date.utc_today(), 14)}
  end

  defp apply_defer_option("due_minus_week", nil), do: :error

  defp apply_defer_option("due_minus_week", %Date{} = due_date) do
    {:ok, Date.add(due_date, -7)}
  end

  defp apply_defer_option(_, _), do: :error

  defp log_automation_failure(reason, ctx) do
    executed =
      ctx
      |> Map.get(:executed, [])
      |> Enum.map(&command_name_string/1)

    executed_value =
      case executed do
        [] -> nil
        list -> Enum.join(list, ",")
      end

    last_response = Map.get(ctx, :last_response, %{})
    machine = Map.get(ctx, :machine, %{})

    pending_ops = fetch_list(last_response, :pending_operations)
    plan_notes = fetch_list(last_response, :plan_notes)

    metadata =
      [
        reason: inspect(reason),
        state: machine_state(machine),
        last_state: fetch_value(last_response, :state),
        last_message: fetch_value(last_response, :message),
        executed: executed_value,
        error_count: Map.get(ctx, :errors, 0),
        pending_ops_count: length(pending_ops),
        plan_notes_count: length(plan_notes),
        conversation_turns: conversation_count(ctx)
      ]
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)

    Logger.error("LLM automation failed", metadata)
  end

  defp fetch_list(map, key) do
    case fetch_value(map, key) do
      list when is_list(list) -> list
      _ -> []
    end
  end

  defp fetch_value(map, key) do
    Map.get(map, key) || Map.get(map, to_string(key))
  end

  defp machine_state(%{state: state}), do: inspect(state)
  defp machine_state(_), do: nil

  defp conversation_count(ctx) do
    case Map.get(ctx, :conversation) do
      list when is_list(list) -> length(list)
      _ -> 0
    end
  end

  defp command_name_string(%{name: name}), do: command_name_string(name)
  defp command_name_string(name) when is_atom(name), do: Atom.to_string(name)
  defp command_name_string(name) when is_binary(name), do: name
  defp command_name_string(name), do: to_string(name)

  defp assign_task_lists(socket, tasks, opts \\ []) do
    grouped = categorize_tasks(tasks)
    reset? = Keyword.get(opts, :reset, false)

    socket =
      socket
      |> assign(:tasks_empty?, Enum.all?(grouped, fn {_key, list} -> list == [] end))
      |> assign(:urgent_empty?, grouped.urgent_ready == [])
      |> assign(:ready_empty?, grouped.ready == [])
      |> assign(:blocked_empty?, grouped.blocked == [])
      |> assign(:deferred_empty?, grouped.deferred == [])
      |> assign(:completed_empty?, grouped.completed == [])
      |> assign(:urgent_count, length(grouped.urgent_ready))
      |> assign(:ready_count, length(grouped.ready))
      |> assign(:blocked_count, length(grouped.blocked))
      |> assign(:deferred_count, length(grouped.deferred))
      |> assign(:completed_count, length(grouped.completed))

    socket
    |> maybe_stream(:urgent_tasks, grouped.urgent_ready, reset?)
    |> maybe_stream(:ready_tasks, grouped.ready, reset?)
    |> maybe_stream(:blocked_tasks, grouped.blocked, reset?)
    |> maybe_stream(:deferred_tasks, grouped.deferred, reset?)
    |> maybe_stream(:completed_tasks, grouped.completed, reset?)
  end

  defp maybe_stream(socket, key, entries, true), do: stream(socket, key, entries, reset: true)
  defp maybe_stream(socket, key, entries, false), do: stream(socket, key, entries)

  defp categorize_tasks(tasks) do
    today = Date.utc_today()
    initial = %{urgent_ready: [], ready: [], blocked: [], deferred: [], completed: []}

    tasks
    |> Enum.reduce(initial, fn task, acc ->
      key =
        cond do
          task.status == :done -> :completed
          deferred_in_future?(task, today) -> :deferred
          blocked?(task) -> :blocked
          urgent?(task) -> :urgent_ready
          true -> :ready
        end

      Map.update!(acc, key, &[task | &1])
    end)
    |> Enum.into(%{}, fn {key, list} ->
      items = Enum.reverse(list)

      sorted =
        case key do
          :deferred -> Enum.sort_by(items, &(&1.deferred_until || today))
          _ -> items
        end

      {key, sorted}
    end)
  end

  defp urgent?(task), do: task.urgency in [:high, :critical]

  defp deferred_in_future?(%Task{deferred_until: %Date{} = deferred_until}, today) do
    Date.compare(deferred_until, today) == :gt
  end

  defp deferred_in_future?(_, _), do: false

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="flex items-center justify-between">
        <h1 class="text-2xl font-semibold">My Tasks</h1>
        <button class="btn btn-ghost" phx-click="toggle_advanced">
          <.icon name="hero-cog-6-tooth" class="w-5 h-5 mr-1" /> Advanced task create
        </button>
      </div>

      <div class="card bg-base-200 border border-base-300 mt-6">
        <div class="card-body">
          <.form for={@quick_form} id="quick-task-form" phx-submit="quick_save">
            <div class="join w-full">
              <input
                type="text"
                id={@quick_form[:title].id}
                name={@quick_form[:title].name}
                value={@quick_form[:title].value}
                placeholder="What would you like me to do?"
                class="join-item input input-bordered w-full"
                disabled={@automation_status == :running}
              />
              <button
                class="join-item btn btn-primary"
                type="submit"
                aria-label="Quick add"
                disabled={@automation_status == :running}
              >
                <.icon name="hero-paper-airplane" class="w-5 h-5" />
              </button>
            </div>
          </.form>
          <p
            :if={@automation_status == :running}
            class="mt-3 flex items-center gap-2 text-sm text-base-content/70"
          >
            <.icon name="hero-arrow-path" class="w-4 h-4 animate-spin" /> Automation in progress...
          </p>
        </div>
      </div>

      <div :if={@advanced_open?} class="card bg-base-200 border border-base-300 mt-4">
        <div class="card-body">
          <h2 class="card-title">Advanced task create</h2>
          <.form for={@form} id="advanced-task-form" phx-change="validate" phx-submit="save">
            <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
              <.input field={@form[:title]} label="Title" placeholder="e.g. Write docs" required />
              <.input field={@form[:due_date]} type="date" label="Due date" />

              <.input
                field={@form[:urgency]}
                type="select"
                label="Urgency"
                prompt="Select"
                options={for u <- Task.urgency_values(), do: {Phoenix.Naming.humanize(u), u}}
              />

              <.input
                field={@form[:recurrence]}
                type="select"
                label="Recurrence"
                prompt="None"
                options={for r <- Task.recurrence_values(), do: {Phoenix.Naming.humanize(r), r}}
              />

              <.input
                field={@form[:description]}
                type="textarea"
                label="Description"
                class="textarea textarea-bordered"
              />

              <.input
                field={@form[:notes]}
                type="textarea"
                label="Notes"
                class="textarea textarea-bordered"
              />

              <.input
                field={@form[:deferred_until]}
                type="date"
                label="Defer until"
              />

              <.input
                id="task_defer_option"
                name="task[defer_option]"
                type="select"
                label="Quick deferral"
                prompt="No quick selection"
                options={defer_option_options()}
                value={@defer_option_selection}
              />

              <.input
                type="select"
                id="task_assignment_target"
                name="task[assignment_target]"
                label="Assignment"
                prompt="No assignment"
                options={@assignment_options}
                value={@assignment_selection}
              />

              <.input
                id="task_prereq_ids"
                name="task[prerequisite_ids]"
                type="select"
                label="Prerequisites"
                multiple
                value={@selected_prereq_ids}
                options={@prereq_options}
                prompt="Select tasks that must be completed first"
              />
            </div>
            <div class="mt-4 flex justify-end">
              <button class="btn btn-primary" type="submit">
                <.icon name="hero-plus" class="w-5 h-5 mr-1" /> Create task
              </button>
            </div>
          </.form>
        </div>
      </div>

      <div :if={@edit_form} class="card bg-base-200 border border-secondary/40 mt-4">
        <div class="card-body">
          <div class="flex items-center justify-between gap-3">
            <h2 class="card-title">Edit task</h2>
            <button type="button" class="btn btn-ghost btn-sm" phx-click="cancel_edit">
              Cancel
            </button>
          </div>
          <.form
            for={@edit_form}
            id="edit-task-form"
            phx-change="edit_validate"
            phx-submit="update_task"
          >
            <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
              <.input field={@edit_form[:title]} label="Title" required />
              <.input field={@edit_form[:due_date]} type="date" label="Due date" />

              <.input
                field={@edit_form[:urgency]}
                type="select"
                label="Urgency"
                prompt="Select"
                options={for u <- Task.urgency_values(), do: {Phoenix.Naming.humanize(u), u}}
              />

              <.input
                field={@edit_form[:recurrence]}
                type="select"
                label="Recurrence"
                prompt="None"
                options={for r <- Task.recurrence_values(), do: {Phoenix.Naming.humanize(r), r}}
              />

              <.input
                field={@edit_form[:description]}
                type="textarea"
                label="Description"
                class="textarea textarea-bordered"
              />

              <.input
                field={@edit_form[:notes]}
                type="textarea"
                label="Notes"
                class="textarea textarea-bordered"
              />

              <.input
                field={@edit_form[:deferred_until]}
                type="date"
                label="Defer until"
              />

              <.input
                id="edit_task_defer_option"
                name="task[defer_option]"
                type="select"
                label="Quick deferral"
                prompt="No quick selection"
                options={defer_option_options()}
                value={@edit_defer_option_selection || ""}
              />

              <.input
                type="select"
                id="edit_task_assignment_target"
                name="task[assignment_target]"
                label="Assignment"
                prompt="No assignment"
                options={@assignment_options}
                value={@edit_assignment_selection}
              />

              <.input
                id="edit_task_prereq_ids"
                name="task[prerequisite_ids]"
                type="select"
                label="Prerequisites"
                multiple
                value={@edit_selected_prereq_ids}
                options={@prereq_options}
                prompt="Select tasks that must be completed first"
              />
            </div>
            <div class="mt-4 flex justify-end gap-2">
              <button type="button" class="btn btn-ghost" phx-click="cancel_edit">
                <.icon name="hero-x-mark" class="w-5 h-5 mr-1" /> Cancel
              </button>
              <button
                type="button"
                class="btn btn-secondary"
                phx-click="break_down_task"
                phx-value-id={@editing_task_id}
                disabled={@automation_status == :running}
              >
                Break it down into smaller steps
              </button>
              <button class="btn btn-primary" type="submit">
                <.icon name="hero-check" class="w-5 h-5 mr-1" /> Save changes
              </button>
            </div>
          </.form>
        </div>
      </div>

      <p :if={@tasks_empty?} class="mt-8 text-sm text-base-content/70">
        No tasks yet — add your first one above.
      </p>

      <div :if={!@tasks_empty?} class="mt-8 space-y-12">
        <section>
          <div class="flex items-center justify-between gap-3">
            <h2 class="text-xl font-semibold">Urgent &amp; ready</h2>
            <span class="text-sm text-base-content/70">{@urgent_count} on deck</span>
          </div>
          <p :if={@urgent_empty?} class="mt-4 text-sm text-base-content/70">
            No urgent tasks are ready right now. Clear blockers or add due dates to promote work.
          </p>
          <div :if={!@urgent_empty?} id="urgent-tasks" phx-update="stream" class="mt-4 space-y-3">
            <.task_card
              :for={{id, task} <- @streams.urgent_tasks}
              id={id}
              task={task}
              variant={:urgent}
              editing={@editing_task_id == task.id}
            />
          </div>
        </section>

        <section>
          <div class="flex items-center justify-between gap-3">
            <h2 class="text-xl font-semibold">Ready backlog</h2>
            <span class="text-sm text-base-content/70">{@ready_count} waiting</span>
          </div>
          <p :if={@ready_empty?} class="mt-4 text-sm text-base-content/70">
            Everything ready to start is already covered above.
          </p>
          <div :if={!@ready_empty?} id="ready-tasks" phx-update="stream" class="mt-4 space-y-3">
            <.task_card
              :for={{id, task} <- @streams.ready_tasks}
              id={id}
              task={task}
              editing={@editing_task_id == task.id}
            />
          </div>
        </section>

        <section>
          <div class="flex items-center justify-between gap-3">
            <h2 class="text-xl font-semibold">Blocked</h2>
            <span class="text-sm text-base-content/70">{@blocked_count} stuck</span>
          </div>
          <p :if={@blocked_empty?} class="mt-4 text-sm text-base-content/70">
            No tasks are blocked right now. Nice work keeping things moving.
          </p>
          <div :if={!@blocked_empty?} id="blocked-tasks" phx-update="stream" class="mt-4 space-y-3">
            <.task_card
              :for={{id, task} <- @streams.blocked_tasks}
              id={id}
              task={task}
              variant={:blocked}
              editing={@editing_task_id == task.id}
            />
          </div>
        </section>

        <section>
          <div class="flex items-center justify-between gap-3">
            <h2 class="text-xl font-semibold">Deferred</h2>
            <span class="text-sm text-base-content/70">{@deferred_count} snoozed</span>
          </div>
          <p :if={@deferred_empty?} class="mt-4 text-sm text-base-content/70">
            Tasks deferred into the future will show up here until the defer date passes.
          </p>
          <div :if={!@deferred_empty?} id="deferred-tasks" phx-update="stream" class="mt-4 space-y-3">
            <.task_card
              :for={{id, task} <- @streams.deferred_tasks}
              id={id}
              task={task}
              variant={:deferred}
              editing={@editing_task_id == task.id}
            />
          </div>
        </section>

        <section>
          <div class="flex items-center justify-between gap-3">
            <div>
              <h2 class="text-xl font-semibold">Completed</h2>
              <span class="text-sm text-base-content/60">{@completed_count} done</span>
            </div>
            <button
              type="button"
              class="btn btn-ghost btn-sm"
              phx-click="toggle_completed"
              disabled={@completed_empty?}
            >
              <.icon
                name={if @show_completed?, do: "hero-chevron-up", else: "hero-chevron-down"}
                class="w-4 h-4 mr-1"
              />
              {if @show_completed?, do: "Hide", else: "Show"}
            </button>
          </div>
          <p :if={@completed_empty?} class="mt-4 text-sm text-base-content/50">
            Mark tasks as done to see them here.
          </p>
          <div
            id="completed-tasks"
            phx-update="stream"
            class={[
              "mt-4 space-y-3",
              (!@show_completed? || @completed_empty?) && "hidden"
            ]}
          >
            <.task_card
              :for={{id, task} <- @streams.completed_tasks}
              id={id}
              task={task}
              variant={:completed}
              editing={@editing_task_id == task.id}
            />
          </div>
        </section>
      </div>
    </Layouts.app>
    """
  end

  attr :id, :string, required: true
  attr :task, SmartTodo.Tasks.Task, required: true
  attr :variant, :atom, default: :default
  attr :editing, :boolean, default: false

  defp task_card(assigns) do
    ~H"""
    <div id={@id} class={task_card_classes(@variant, @editing)}>
      <div class="card-body flex flex-row items-start gap-4">
        <button
          phx-click="toggle_done"
          phx-value-id={@task.id}
          class="btn btn-circle btn-sm"
          disabled={blocked?(@task)}
          title={blocked?(@task) && "Blocked by prerequisites"}
        >
          <.icon :if={@task.status == :done} name="hero-check" class="w-5 h-5" />
          <.icon
            :if={@task.status != :done and not blocked?(@task)}
            name="hero-check"
            class="w-5 h-5 opacity-40"
          />
          <.icon :if={blocked?(@task)} name="hero-lock-closed" class="w-5 h-5 opacity-60" />
        </button>

        <div class="flex-1">
          <div class="flex items-start justify-between gap-3">
            <div class="flex items-center gap-2">
              <h3 class={[
                "font-medium",
                @task.status == :done && "line-through opacity-70"
              ]}>
                {@task.title}
              </h3>
              <span class="badge badge-outline">{Phoenix.Naming.humanize(@task.urgency)}</span>
              <span :if={@task.due_date} class="badge badge-ghost">
                <.icon name="hero-calendar" class="w-4 h-4 mr-1" />
                {Calendar.strftime(@task.due_date, "%Y-%m-%d")}
              </span>
              <span
                :if={@task.assignee_id != nil and @task.assignee_id != @task.user_id}
                class="badge badge-info"
              >
                <.icon name="hero-user" class="w-3 h-3 mr-1" /> Assigned to user
              </span>
              <span :if={@task.assigned_group_id} class="badge badge-secondary">
                <.icon name="hero-user-group" class="w-3 h-3 mr-1" /> Group assigned
              </span>
              <span :if={@task.deferred_until} class={deferred_badge_classes(@task)}>
                <.icon name="hero-clock" class="w-3 h-3 mr-1" />
                Deferred until {format_date(@task.deferred_until)}
              </span>
            </div>

            <div class="flex items-center gap-1">
              <button
                type="button"
                class="btn btn-ghost btn-xs"
                phx-click="edit_task"
                phx-value-id={@task.id}
                disabled={@editing}
                aria-label="Edit task"
              >
                <.icon name="hero-pencil-square" class="w-4 h-4" />
              </button>
              <button
                type="button"
                class="btn btn-ghost btn-xs"
                phx-click="trash_task"
                phx-value-id={@task.id}
                data-confirm="Delete this task?"
                aria-label="Delete task"
              >
                <.icon name="hero-trash" class="w-4 h-4" />
              </button>
            </div>
          </div>
          <p :if={@task.description} class="text-sm text-base-content/70 mt-1">
            {@task.description}
          </p>

          <p :if={@task.notes} class="text-sm text-base-content/70 mt-1 whitespace-pre-line">
            {@task.notes}
          </p>

          <div class="mt-3 space-y-3 text-sm text-base-content/70">
            <div :if={Enum.count(@task.prerequisites) > 0} class="space-y-1">
              <div class="flex items-center gap-2 text-xs font-semibold uppercase tracking-wide text-base-content/60">
                <.icon name="hero-arrow-up-right" class="w-4 h-4" />
                Blocked by ({incomplete_count(@task)} / {Enum.count(@task.prerequisites)})
              </div>
              <ul class="space-y-1">
                <li
                  :for={pre <- @task.prerequisites}
                  class="flex items-center gap-2"
                >
                  <span class={status_badge_classes(pre.status)}>{status_label(pre.status)}</span>
                  <span class={[
                    "truncate",
                    pre.status != :done && "font-medium text-base-content"
                  ]}>
                    {pre.title}
                  </span>
                </li>
              </ul>
            </div>

            <div :if={Enum.count(@task.dependents) > 0} class="space-y-1">
              <div class="flex items-center gap-2 text-xs font-semibold uppercase tracking-wide text-base-content/60">
                <.icon name="hero-arrow-down-left" class="w-4 h-4" />
                Unlocks {Enum.count(@task.dependents)} downstream
              </div>
              <ul class="space-y-1">
                <li
                  :for={dep <- @task.dependents}
                  class="flex items-center gap-2"
                >
                  <span class={status_badge_classes(dep.status)}>{status_label(dep.status)}</span>
                  <span class={[
                    "truncate",
                    dep.status == :todo && "font-medium text-base-content"
                  ]}>
                    {dep.title}
                  </span>
                </li>
              </ul>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp task_card_classes(:urgent, editing?),
    do: decorate_classes(["card bg-base-200 border border-primary/60"], editing?)

  defp task_card_classes(:blocked, editing?),
    do: decorate_classes(["card bg-base-200 border border-warning/50"], editing?)

  defp task_card_classes(:deferred, editing?),
    do: decorate_classes(["card bg-base-200 border border-info/40 opacity-80"], editing?)

  defp task_card_classes(:completed, editing?),
    do: decorate_classes(["card bg-base-200 border border-base-300 opacity-60"], editing?)

  defp task_card_classes(:default, editing?),
    do: decorate_classes(["card bg-base-200 border border-base-300"], editing?)

  defp decorate_classes(classes, false), do: classes
  defp decorate_classes(classes, true), do: classes ++ ["ring ring-primary/60 shadow-lg"]

  defp status_badge_classes(:done), do: ["badge badge-sm badge-success"]
  defp status_badge_classes(:in_progress), do: ["badge badge-sm badge-info"]
  defp status_badge_classes(:todo), do: ["badge badge-sm badge-outline"]
  defp status_badge_classes(_), do: ["badge badge-sm badge-ghost"]

  defp status_label(status), do: Phoenix.Naming.humanize(status)

  defp blocked?(task) do
    Enum.any?(task.prerequisites, &(&1.status != :done))
  end

  defp incomplete_count(task) do
    Enum.count(task.prerequisites, &(&1.status != :done))
  end

  defp deferred_badge_classes(task) do
    if future_deferred?(task) do
      ["badge badge-warning"]
    else
      ["badge badge-ghost"]
    end
  end

  defp future_deferred?(task), do: deferred_in_future?(task, Date.utc_today())

  defp format_date(%Date{} = date), do: Calendar.strftime(date, "%Y-%m-%d")
  defp format_date(_), do: ""
end
