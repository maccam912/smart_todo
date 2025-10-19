defmodule SmartTodo.MCP.Tools.UpdateTask do
  @moduledoc """
  MCP tool for updating an existing task.
  """

  use Anubis.Server.Component, type: :tool

  alias SmartTodo.Tasks

  def definition do
    %{
      name: "update_task",
      description: "Update an existing task. All fields are optional except id.",
      input_schema: %{
        type: "object",
        properties: %{
          id: %{
            type: "integer",
            description: "Task ID (required)"
          },
          title: %{
            type: "string",
            description: "Task title",
            maxLength: 200
          },
          description: %{
            type: "string",
            description: "Detailed description"
          },
          status: %{
            type: "string",
            enum: ["todo", "in_progress", "done"],
            description: "Task status"
          },
          urgency: %{
            type: "string",
            enum: ["low", "normal", "high", "critical"],
            description: "Priority level"
          },
          due_date: %{
            type: "string",
            format: "date",
            description: "Due date (YYYY-MM-DD)"
          },
          recurrence: %{
            type: "string",
            enum: ["none", "daily", "weekly", "monthly", "yearly"],
            description: "Recurrence pattern"
          },
          deferred_until: %{
            type: "string",
            format: "date",
            description: "Defer until date (YYYY-MM-DD)"
          },
          notes: %{
            type: "string",
            description: "Additional notes"
          },
          assignee_id: %{
            type: "integer",
            description: "Assigned user ID"
          },
          assigned_group_id: %{
            type: "integer",
            description: "Assigned group ID"
          },
          prerequisite_ids: %{
            type: "array",
            items: %{type: "integer"},
            description: "IDs of tasks that must be completed first"
          }
        },
        required: ["id"]
      }
    }
  end

  def call(%{"id" => id} = params, frame) do
    scope = frame.context.assigns[:current_scope]

    task = Tasks.get_task!(scope, id)

    task_params =
      params
      |> Map.delete("id")
      |> normalize_params()

    case Tasks.update_task(scope, task, task_params) do
      {:ok, updated_task} ->
        {:ok, %{
          id: updated_task.id,
          title: updated_task.title,
          status: updated_task.status
        }}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:error, format_errors(changeset)}
    end
  rescue
    Ecto.NoResultsError ->
      {:error, "Task not found"}
  end

  defp normalize_params(params) do
    Enum.into(params, %{}, fn {k, v} ->
      {String.to_existing_atom(k), v}
    end)
  rescue
    ArgumentError -> params
  end

  defp format_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
    |> Enum.map(fn {field, errors} ->
      "#{field}: #{Enum.join(errors, ", ")}"
    end)
    |> Enum.join("; ")
  end
end
