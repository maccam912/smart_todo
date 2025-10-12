defmodule SmartTodoWeb.Api.TaskJSON do
  alias SmartTodo.Tasks.Task

  @doc """
  Renders a list of tasks.
  """
  def index(%{tasks: tasks}) do
    %{data: for(task <- tasks, do: data(task))}
  end

  @doc """
  Renders a single task.
  """
  def show(%{task: task}) do
    %{data: data(task)}
  end

  @doc """
  Renders the result of natural language processing.
  """
  def natural_language(%{actions: actions}) do
    action_count = length(actions)

    message =
      case action_count do
        0 -> "No actions were performed"
        1 -> "Successfully performed 1 action"
        n -> "Successfully performed #{n} actions"
      end

    %{
      actions: Enum.map(actions, &format_action/1),
      message: message
    }
  end

  defp data(%Task{} = task) do
    %{
      id: task.id,
      title: task.title,
      description: task.description,
      status: task.status,
      urgency: task.urgency,
      due_date: task.due_date,
      recurrence: task.recurrence,
      deferred_until: task.deferred_until,
      notes: task.notes,
      user_id: task.user_id,
      assignee_id: task.assignee_id,
      assigned_group_id: task.assigned_group_id,
      prerequisites: render_prerequisites(task),
      dependents: render_dependents(task),
      inserted_at: task.inserted_at,
      updated_at: task.updated_at
    }
  end

  defp render_prerequisites(%Task{prerequisites: prerequisites})
       when is_list(prerequisites) do
    Enum.map(prerequisites, &%{id: &1.id, title: &1.title, status: &1.status})
  end

  defp render_prerequisites(_), do: []

  defp render_dependents(%Task{dependents: dependents}) when is_list(dependents) do
    Enum.map(dependents, &%{id: &1.id, title: &1.title, status: &1.status})
  end

  defp render_dependents(_), do: []

  defp format_action(%{name: name, params: params}) do
    %{name: format_action_name(name), params: params}
  end

  defp format_action(%{"name" => name, "params" => params}) do
    %{name: format_action_name(name), params: params}
  end

  defp format_action(action) when is_map(action) do
    name = Map.get(action, :name) || Map.get(action, "name")
    params = Map.get(action, :params) || Map.get(action, "params") || %{}
    %{name: format_action_name(name), params: params}
  end

  defp format_action_name(name) when is_atom(name), do: Atom.to_string(name)
  defp format_action_name(name) when is_binary(name), do: name
  defp format_action_name(name), do: to_string(name)
end
