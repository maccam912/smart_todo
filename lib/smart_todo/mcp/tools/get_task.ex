defmodule SmartTodo.MCP.Tools.GetTask do
  @moduledoc """
  MCP tool for getting a single task.
  """

  use Anubis.Server.Component, type: :tool

  alias SmartTodo.Tasks

  def definition do
    %{
      name: "get_task",
      description: "Get a single task by ID",
      input_schema: %{
        type: "object",
        properties: %{
          id: %{
            type: "integer",
            description: "Task ID"
          }
        },
        required: ["id"]
      }
    }
  end

  def call(%{"id" => id}, frame) do
    scope = frame.context.assigns[:current_scope]

    task = Tasks.get_task!(scope, id)

    result = %{
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

    {:ok, result}
  rescue
    Ecto.NoResultsError ->
      {:error, "Task not found"}
  end
end
