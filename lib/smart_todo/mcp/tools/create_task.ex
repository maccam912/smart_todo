defmodule SmartTodo.MCP.Tools.CreateTask do
  @moduledoc """
  MCP tool for creating a new task.
  """

  use Anubis.Server.Component, type: :tool

  alias SmartTodo.Tasks

  def definition do
    %{
      name: "create_task",
      description: "Create a new task",
      input_schema: %{
        type: "object",
        properties: %{
          title: %{
            type: "string",
            description: "Task title (required)",
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
        required: ["title"]
      }
    }
  end

  def call(params, frame) do
    scope = frame.context.assigns[:current_scope]

    case Tasks.create_task(scope, normalize_params(params)) do
      {:ok, task} ->
        {:ok, %{
          id: task.id,
          title: task.title,
          status: task.status
        }}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:error, format_errors(changeset)}
    end
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
