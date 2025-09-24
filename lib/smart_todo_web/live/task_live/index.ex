defmodule SmartTodoWeb.TaskLive.Index do
  use SmartTodoWeb, :live_view

  alias SmartTodo.Tasks
  alias SmartTodo.Tasks.Task

  @impl true
  def mount(_params, _session, socket) do
    current_scope = socket.assigns.current_scope
    tasks = Tasks.list_tasks(current_scope)

    form =
      %Task{}
      |> Tasks.change_task()
      |> to_form()

    socket =
      socket
      |> assign(:page_title, "My Tasks")
      |> assign(:advanced_open?, false)
      |> assign(:quick_form, to_form(%{"title" => ""}, as: "quick_task"))
      |> assign(:selected_prereq_ids, [])
      |> assign(:form, form)
      |> assign(:show_completed?, false)
      |> assign(:prereq_options, prereq_options(tasks))

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
  def handle_event("quick_save", %{"quick_task" => %{"title" => title}}, socket) do
    if String.trim(to_string(title)) == "" do
      {:noreply, put_flash(socket, :error, "Title can't be blank")}
    else
      case Tasks.create_task(socket.assigns.current_scope, %{title: title}) do
        {:ok, _task} ->
          tasks = Tasks.list_tasks(socket.assigns.current_scope)

          {:noreply,
           socket
           |> put_flash(:info, "Task created")
           |> assign(:quick_form, to_form(%{"title" => ""}, as: "quick_task"))
           |> assign(:prereq_options, prereq_options(tasks))
           |> assign_task_lists(tasks, reset: true)}

        {:error, %Ecto.Changeset{} = _cs} ->
          {:noreply, put_flash(socket, :error, "Could not create task")}
      end
    end
  end

  @impl true
  def handle_event("save", %{"task" => params}, socket) do
    case Tasks.create_task(socket.assigns.current_scope, params) do
      {:ok, _task} ->
        tasks = Tasks.list_tasks(socket.assigns.current_scope)

        {:noreply,
         socket
         |> put_flash(:info, "Task created")
         |> assign(:advanced_open?, false)
         |> assign(:selected_prereq_ids, [])
         |> assign(:form, %Task{} |> Tasks.change_task() |> to_form())
         |> assign(:prereq_options, prereq_options(tasks))
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

  defp prereq_options(tasks) do
    Enum.map(tasks, fn t -> {t.title, t.id} end)
  end

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
              />
              <button class="join-item btn btn-primary" type="submit" aria-label="Quick add">
                <.icon name="hero-paper-airplane" class="w-5 h-5" />
              </button>
            </div>
          </.form>
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
            <.task_card :for={{id, task} <- @streams.ready_tasks} id={id} task={task} />
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
            :if={@show_completed? and not @completed_empty?}
            id="completed-tasks"
            phx-update="stream"
            class="mt-4 space-y-3"
          >
            <.task_card
              :for={{id, task} <- @streams.completed_tasks}
              id={id}
              task={task}
              variant={:completed}
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

  defp task_card(assigns) do
    ~H"""
    <div id={@id} class={task_card_classes(@variant)}>
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
          </div>
          <p :if={@task.description} class="text-sm text-base-content/70 mt-1">
            {@task.description}
          </p>

          <div class="mt-2 text-sm text-base-content/70 flex items-center gap-4">
            <div :if={Enum.count(@task.prerequisites) > 0} class="flex items-center gap-1">
              <.icon name="hero-arrow-up-right" class="w-4 h-4" />
              Blocked by {incomplete_count(@task)} / {Enum.count(@task.prerequisites)}
            </div>
            <div :if={Enum.count(@task.dependents) > 0} class="flex items-center gap-1">
              <.icon name="hero-arrow-down-left" class="w-4 h-4" />
              Unlocks {Enum.count(@task.dependents)} downstream
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp task_card_classes(:urgent), do: ["card bg-base-200 border border-primary/60"]
  defp task_card_classes(:blocked), do: ["card bg-base-200 border border-warning/50"]
  defp task_card_classes(:completed), do: ["card bg-base-200 border border-base-300 opacity-60"]
  defp task_card_classes(:default), do: ["card bg-base-200 border border-base-300"]

  defp blocked?(task) do
    Enum.any?(task.prerequisites, &(&1.status != :done))
  end

  defp incomplete_count(task) do
    Enum.count(task.prerequisites, &(&1.status != :done))
  end
end
