defmodule SmartTodo.MCP.Tools.ListTasks do
  @moduledoc """
  MCP tool for listing tasks.
  """

  use Anubis.Server.Component, type: :tool

  alias SmartTodo.Tasks

  def definition do
    %{
      name: "list_tasks",
      description: "List all tasks accessible by the authenticated user",
      input_schema: %{
        type: "object",
        properties: %{
          status: %{
            type: "string",
            enum: ["todo", "in_progress", "done"],
            description: "Optional status filter"
          }
        }
      }
    }
  end

  def call(params, frame) do
    scope = frame.context.assigns[:current_scope]

    opts =
      if status = params["status"] do
        [status: String.to_existing_atom(status)]
      else
        []
      end

    tasks = Tasks.list_tasks(scope, opts)

    result = %{
      tasks: Enum.map(tasks, &format_task/1)
    }

    {:ok, result}
  end

  defp format_task(task) do
    %{
      id: task.id,
      title: task.title,
      description: task.description,
      status: task.status,
      urgency: task.urgency,
      due_date: task.due_date,
      deferred_until: task.deferred_until,
      recurrence: task.recurrence,
      notes: task.notes,
      user_id: task.user_id,
      assignee_id: task.assignee_id,
      assigned_group_id: task.assigned_group_id,
      prerequisites: Enum.map(task.prerequisites, & &1.id),
      dependents: Enum.map(task.dependents, & &1.id)
    }
  end
end
