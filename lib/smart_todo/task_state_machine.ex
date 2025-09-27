defmodule SmartTodo.TaskStateMachine do
  @moduledoc """
  A GenStateMachine for managing task workflow states and transitions.
  Each connected client gets their own state machine instance.
  """

  use GenStateMachine
  alias SmartTodo.{Tasks, Accounts}

  # States
  @states [:idle, :creating_task, :editing_task, :managing_dependencies, :viewing_tasks]

  # Client API
  def start_link(user_id) do
    GenStateMachine.start_link(__MODULE__, %{user_id: user_id}, name: via_tuple(user_id))
  end

  def get_available_actions(user_id) do
    case GenStateMachine.call(via_tuple(user_id), :get_available_actions) do
      {:ok, actions} -> actions
      {:error, _} -> []
    end
  end

  def transition_to(user_id, new_state, params \\ %{}) do
    GenStateMachine.call(via_tuple(user_id), {:transition_to, new_state, params})
  end

  def execute_action(user_id, action, params \\ %{}) do
    GenStateMachine.call(via_tuple(user_id), {:execute_action, action, params})
  end

  def get_current_state(user_id) do
    case GenStateMachine.call(via_tuple(user_id), :get_current_state) do
      {:ok, state} -> state
      {:error, _} -> :idle
    end
  end

  def stop(user_id) do
    case Registry.lookup(SmartTodo.TaskStateMachineRegistry, user_id) do
      [] -> :ok
      [{pid, _}] -> GenStateMachine.stop(pid)
    end
  end

  # GenStateMachine callbacks
  @impl true
  def init(%{user_id: user_id}) do
    scope = %Accounts.Scope{user: Accounts.get_user!(user_id)}
    {:ok, :idle, %{user_id: user_id, scope: scope, current_task: nil, context: %{}}}
  end

  @impl true
  def handle_event({:call, from}, :get_available_actions, state, _data) do
    actions = get_actions_for_state(state)
    {:keep_state_and_data, [{:reply, from, {:ok, actions}}]}
  end

  def handle_event({:call, from}, :get_current_state, state, _data) do
    {:keep_state_and_data, [{:reply, from, {:ok, state}}]}
  end

  def handle_event({:call, from}, {:transition_to, new_state, params}, _state, data) do
    if new_state in @states do
      new_data = Map.merge(data, %{context: params})
      {:next_state, new_state, new_data, [{:reply, from, {:ok, new_state}}]}
    else
      {:keep_state_and_data, [{:reply, from, {:error, "Invalid state: #{new_state}"}}]}
    end
  end

  def handle_event({:call, from}, {:execute_action, action, params}, state, data) do
    case execute_state_action(state, action, params, data) do
      {:ok, result, new_data} ->
        {:keep_state, new_data, [{:reply, from, {:ok, result}}]}

      {:ok, result, new_state, new_data} ->
        {:next_state, new_state, new_data, [{:reply, from, {:ok, result}}]}

      {:error, reason} ->
        {:keep_state_and_data, [{:reply, from, {:error, reason}}]}
    end
  end

  # Private functions
  defp via_tuple(user_id) do
    {:via, Registry, {SmartTodo.TaskStateMachineRegistry, user_id}}
  end

  defp get_actions_for_state(:idle) do
    [
      %{name: "create_task", description: "Create a new task", params: ["title", "description"]},
      %{name: "list_tasks", description: "List all tasks", params: []},
      %{name: "search_tasks", description: "Search tasks by title or description", params: ["query"]},
      %{name: "view_task", description: "View a specific task", params: ["task_id"]},
      %{name: "get_task_stats", description: "Get task statistics", params: []}
    ]
  end

  defp get_actions_for_state(:creating_task) do
    [
      %{name: "set_title", description: "Set task title", params: ["title"]},
      %{name: "set_description", description: "Set task description", params: ["description"]},
      %{name: "set_urgency", description: "Set task urgency (1-5)", params: ["urgency"]},
      %{name: "set_due_date", description: "Set due date (YYYY-MM-DD)", params: ["due_date"]},
      %{name: "assign_to_user", description: "Assign task to user", params: ["username"]},
      %{name: "assign_to_group", description: "Assign task to group", params: ["group_name"]},
      %{name: "save_task", description: "Save the task", params: []},
      %{name: "cancel", description: "Cancel task creation", params: []}
    ]
  end

  defp get_actions_for_state(:editing_task) do
    [
      %{name: "update_title", description: "Update task title", params: ["title"]},
      %{name: "update_description", description: "Update task description", params: ["description"]},
      %{name: "update_urgency", description: "Update task urgency (1-5)", params: ["urgency"]},
      %{name: "update_due_date", description: "Update due date (YYYY-MM-DD)", params: ["due_date"]},
      %{name: "update_status", description: "Update task status", params: ["status"]},
      %{name: "reassign_user", description: "Reassign to different user", params: ["username"]},
      %{name: "reassign_group", description: "Reassign to different group", params: ["group_name"]},
      %{name: "unassign_task", description: "Remove assignment", params: []},
      %{name: "save_changes", description: "Save changes", params: []},
      %{name: "cancel_edit", description: "Cancel editing", params: []}
    ]
  end

  defp get_actions_for_state(:managing_dependencies) do
    [
      %{name: "add_dependency", description: "Add task dependency", params: ["prereq_task_id"]},
      %{name: "remove_dependency", description: "Remove task dependency", params: ["prereq_task_id"]},
      %{name: "list_dependencies", description: "List task dependencies", params: []},
      %{name: "find_blocked_tasks", description: "Find tasks blocked by this task", params: []},
      %{name: "finish_dependencies", description: "Finish managing dependencies", params: []}
    ]
  end

  defp get_actions_for_state(:viewing_tasks) do
    [
      %{name: "filter_by_status", description: "Filter tasks by status", params: ["status"]},
      %{name: "filter_by_urgency", description: "Filter by urgency level", params: ["urgency"]},
      %{name: "sort_by", description: "Sort tasks by field", params: ["field", "direction"]},
      %{name: "select_task", description: "Select a task to edit", params: ["task_id"]},
      %{name: "export_tasks", description: "Export tasks to format", params: ["format"]},
      %{name: "back_to_idle", description: "Return to main menu", params: []}
    ]
  end

  # Action execution
  defp execute_state_action(:idle, "create_task", params, data) do
    task_attrs = %{
      "title" => Map.get(params, "title", ""),
      "description" => Map.get(params, "description", ""),
      "urgency" => Map.get(params, "urgency", "normal"),
      "status" => "todo"
    }

    new_data = Map.put(data, :task_draft, task_attrs)
    {:ok, "Task creation started. Use actions to set properties and then save.", :creating_task, new_data}
  end

  defp execute_state_action(:idle, "list_tasks", _params, data) do
    tasks = Tasks.list_tasks(data.scope)
    task_summaries = Enum.map(tasks, fn task ->
      %{
        id: task.id,
        title: task.title,
        status: task.status,
        urgency: task.urgency,
        due_date: task.due_date
      }
    end)
    {:ok, %{tasks: task_summaries, count: length(task_summaries)}, data}
  end

  defp execute_state_action(:idle, "search_tasks", %{"query" => query}, data) do
    tasks = Tasks.search_tasks(data.scope, query)
    task_summaries = Enum.map(tasks, fn task ->
      %{
        id: task.id,
        title: task.title,
        description: task.description,
        status: task.status
      }
    end)
    {:ok, %{tasks: task_summaries, query: query, count: length(task_summaries)}, data}
  end

  defp execute_state_action(:idle, "view_task", %{"task_id" => task_id}, data) do
    try do
      task = Tasks.get_task!(data.scope, task_id)
      task_details = %{
        id: task.id,
        title: task.title,
        description: task.description,
        status: task.status,
        urgency: task.urgency,
        due_date: task.due_date,
        assignee_id: task.assignee_id,
        assigned_group_id: task.assigned_group_id,
        inserted_at: task.inserted_at,
        updated_at: task.updated_at
      }
      new_data = Map.put(data, :current_task, task)
      {:ok, task_details, :editing_task, new_data}
    rescue
      Ecto.NoResultsError ->
        {:error, "Task not found"}
    end
  end

  defp execute_state_action(:idle, "get_task_stats", _params, data) do
    tasks = Tasks.list_tasks(data.scope)
    stats = %{
      total: length(tasks),
      pending: Enum.count(tasks, &(&1.status == "pending")),
      in_progress: Enum.count(tasks, &(&1.status == "in_progress")),
      completed: Enum.count(tasks, &(&1.status == "completed")),
      high_urgency: Enum.count(tasks, &(&1.urgency >= 4)),
      overdue: Enum.count(tasks, fn task ->
        task.due_date && Date.compare(task.due_date, Date.utc_today()) == :lt
      end)
    }
    {:ok, stats, data}
  end

  defp execute_state_action(:creating_task, "set_title", %{"title" => title}, data) do
    draft = Map.put(data.task_draft, "title", title)
    new_data = Map.put(data, :task_draft, draft)
    {:ok, "Title set to: #{title}", new_data}
  end

  defp execute_state_action(:creating_task, "set_description", %{"description" => description}, data) do
    draft = Map.put(data.task_draft, "description", description)
    new_data = Map.put(data, :task_draft, draft)
    {:ok, "Description set", new_data}
  end

  defp execute_state_action(:creating_task, "set_urgency", %{"urgency" => urgency}, data) when urgency in ["low", "normal", "high", "critical"] do
    draft = Map.put(data.task_draft, "urgency", urgency)
    new_data = Map.put(data, :task_draft, draft)
    {:ok, "Urgency set to: #{urgency}", new_data}
  end

  defp execute_state_action(:creating_task, "save_task", _params, data) do
    # Ensure all keys are strings for Ecto
    task_attrs = for {key, value} <- data.task_draft, into: %{} do
      {to_string(key), value}
    end

    case Tasks.create_task(data.scope, task_attrs) do
      {:ok, task} ->
        new_data = Map.delete(data, :task_draft)
        {:ok, %{message: "Task created successfully", task_id: task.id}, :idle, new_data}
      {:error, changeset} ->
        errors = get_changeset_errors(changeset)
        {:error, "Failed to create task: #{inspect(errors)}"}
    end
  end

  defp execute_state_action(:creating_task, "cancel", _params, data) do
    new_data = Map.delete(data, :task_draft)
    {:ok, "Task creation cancelled", :idle, new_data}
  end

  defp execute_state_action(:editing_task, "update_title", %{"title" => title}, data) do
    case Tasks.update_task(data.scope, data.current_task, %{"title" => title}) do
      {:ok, updated_task} ->
        new_data = Map.put(data, :current_task, updated_task)
        {:ok, "Title updated to: #{title}", new_data}
      {:error, changeset} ->
        errors = get_changeset_errors(changeset)
        {:error, "Failed to update title: #{inspect(errors)}"}
    end
  end

  defp execute_state_action(:editing_task, "update_status", %{"status" => status}, data) when status in ["todo", "in_progress", "done"] do
    case Tasks.update_task(data.scope, data.current_task, %{"status" => status}) do
      {:ok, updated_task} ->
        new_data = Map.put(data, :current_task, updated_task)
        {:ok, "Status updated to: #{status}", new_data}
      {:error, changeset} ->
        errors = get_changeset_errors(changeset)
        {:error, "Failed to update status: #{inspect(errors)}"}
    end
  end

  defp execute_state_action(:editing_task, "save_changes", _params, data) do
    {:ok, "Changes saved", :idle, Map.delete(data, :current_task)}
  end

  defp execute_state_action(:editing_task, "cancel_edit", _params, data) do
    {:ok, "Edit cancelled", :idle, Map.delete(data, :current_task)}
  end

  # Default fallback
  defp execute_state_action(_state, action, _params, _data) do
    {:error, "Action '#{action}' not available in current state"}
  end

  defp get_changeset_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {key, value}, acc ->
        safe_value = case value do
          v when is_binary(v) or is_atom(v) or is_number(v) -> to_string(v)
          _ -> inspect(value)
        end
        String.replace(acc, "%{#{key}}", safe_value)
      end)
    end)
  end
end