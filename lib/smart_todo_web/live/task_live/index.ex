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
      |> assign(:show_completed?, false)
      |> assign(:prereq_options, prereq_options(tasks))
      |> assign(:group_options, group_options(groups))
      |> assign(:automation_status, :idle)
      |> assign(:automation_job_ref, nil)

    {:ok, assign_task_lists(socket, tasks)}
  end

  @impl true
  def handle_event("validate", %{"task" => params}, socket) do
    form =
      %Task{}
      |> Tasks.change_task(params)
      |> Map.put(:action, :validate)
      |> to_form()

    selected = Map.get(params, "prerequisite_ids", [])
    {:noreply, assign(socket, form: form, selected_prereq_ids: selected)}
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
    case Tasks.create_task(socket.assigns.current_scope, params) do
      {:ok, _task} ->
        tasks = Tasks.list_tasks(socket.assigns.current_scope)
        groups = Accounts.list_groups()

        {:noreply,
         socket
         |> put_flash(:info, "Task created")
         |> assign(:advanced_open?, false)
         |> assign(:selected_prereq_ids, [])
         |> assign(:form, %Task{} |> Tasks.change_task() |> to_form())
         |> assign(:prereq_options, prereq_options(tasks))
         |> assign(:group_options, group_options(groups))
         |> assign_task_lists(tasks, reset: true)}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset))}
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

    {:noreply,
     socket
     |> assign(:editing_task_id, task.id)
     |> assign(:edit_form, form)
     |> assign(:edit_selected_prereq_ids, selected)
     |> assign(:advanced_open?, false)}
  end

  @impl true
  def handle_event("cancel_edit", _params, socket) do
    {:noreply,
     socket
     |> assign(:editing_task_id, nil)
     |> assign(:edit_form, nil)
     |> assign(:edit_selected_prereq_ids, [])}
  end

  @impl true
  def handle_event("edit_validate", %{"task" => params}, socket) do
    case socket.assigns.edit_form do
      nil ->
        {:noreply, socket}

      form ->
        changeset = form.source.data |> Tasks.change_task(params) |> Map.put(:action, :validate)

        {:noreply,
         socket
         |> assign(:edit_form, to_form(changeset))
         |> assign(:edit_selected_prereq_ids, Map.get(params, "prerequisite_ids", []))}
    end
  end

  @impl true
  def handle_event("update_task", %{"task" => params}, socket) do
    case socket.assigns.editing_task_id do
      nil ->
        {:noreply, socket}

      task_id ->
        task = Tasks.get_task!(socket.assigns.current_scope, task_id)

        case Tasks.update_task(socket.assigns.current_scope, task, params) do
          {:ok, _task} ->
            tasks = Tasks.list_tasks(socket.assigns.current_scope)
            groups = Accounts.list_groups()

            socket =
              socket
              |> put_flash(:info, "Task updated")
              |> assign(:prereq_options, prereq_options(tasks))
              |> assign(:group_options, group_options(groups))
              |> assign(:editing_task_id, nil)
              |> assign(:edit_form, nil)
              |> assign(:edit_selected_prereq_ids, [])

            {:noreply, assign_task_lists(socket, tasks, reset: true)}

          {:error, %Ecto.Changeset{} = changeset} ->
            {:noreply,
             socket
             |> assign(:edit_form, to_form(changeset))
             |> assign(:edit_selected_prereq_ids, Map.get(params, "prerequisite_ids", []))}
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

        socket =
          socket
          |> put_flash(:info, "Task deleted")
          |> assign(:prereq_options, prereq_options(tasks))
          |> assign(:group_options, group_options(groups))

        socket =
          if socket.assigns.editing_task_id == deleted_task.id do
            socket
            |> assign(:editing_task_id, nil)
            |> assign(:edit_form, nil)
            |> assign(:edit_selected_prereq_ids, [])
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

    socket
    |> assign(:prereq_options, prereq_options(tasks))
    |> assign(:group_options, group_options(groups))
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

  defp group_options(groups) do
    Enum.map(groups, fn g -> {g.name, g.id} end)
  end

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
      |> assign(:completed_empty?, grouped.completed == [])
      |> assign(:urgent_count, length(grouped.urgent_ready))
      |> assign(:ready_count, length(grouped.ready))
      |> assign(:blocked_count, length(grouped.blocked))
      |> assign(:completed_count, length(grouped.completed))

    socket
    |> maybe_stream(:urgent_tasks, grouped.urgent_ready, reset?)
    |> maybe_stream(:ready_tasks, grouped.ready, reset?)
    |> maybe_stream(:blocked_tasks, grouped.blocked, reset?)
    |> maybe_stream(:completed_tasks, grouped.completed, reset?)
  end

  defp maybe_stream(socket, key, entries, true), do: stream(socket, key, entries, reset: true)
  defp maybe_stream(socket, key, entries, false), do: stream(socket, key, entries)

  defp categorize_tasks(tasks) do
    initial = %{urgent_ready: [], ready: [], blocked: [], completed: []}

    tasks
    |> Enum.reduce(initial, fn task, acc ->
      key =
        cond do
          task.status == :done -> :completed
          blocked?(task) -> :blocked
          urgent?(task) -> :urgent_ready
          true -> :ready
        end

      Map.update!(acc, key, &[task | &1])
    end)
    |> Enum.into(%{}, fn {key, list} -> {key, Enum.reverse(list)} end)
  end

  defp urgent?(task), do: task.urgency in [:high, :critical]

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
                field={@form[:assignee_id]}
                type="select"
                label="Assign to User"
                prompt="Assign to me"
                options={[{"Me", @current_scope.user.id}]}
              />

              <.input
                field={@form[:assigned_group_id]}
                type="select"
                label="Assign to Group"
                prompt="No group assignment"
                options={@group_options}
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
                field={@edit_form[:assignee_id]}
                type="select"
                label="Assign to User"
                prompt="No user assignment"
                options={[{"Me", @current_scope.user.id}]}
              />

              <.input
                field={@edit_form[:assigned_group_id]}
                type="select"
                label="Assign to Group"
                prompt="No group assignment"
                options={@group_options}
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
              <span :if={@task.assignee_id != nil and @task.assignee_id != @task.user_id} class="badge badge-info">
                <.icon name="hero-user" class="w-3 h-3 mr-1" />
                Assigned to user
              </span>
              <span :if={@task.assigned_group_id} class="badge badge-secondary">
                <.icon name="hero-user-group" class="w-3 h-3 mr-1" />
                Group assigned
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
end
