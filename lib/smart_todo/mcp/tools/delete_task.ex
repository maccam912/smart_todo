defmodule SmartTodo.MCP.Tools.DeleteTask do
  @moduledoc """
  MCP tool for deleting a task.
  """

  use Anubis.Server.Component, type: :tool

  alias SmartTodo.Tasks

  def definition do
    %{
      name: "delete_task",
      description: "Delete a task. This also removes all associated dependencies.",
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

    case Tasks.delete_task(scope, task) do
      {:ok, _deleted_task} ->
        {:ok, %{
          id: id,
          message: "Task deleted successfully"
        }}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:error, format_errors(changeset)}
    end
  rescue
    Ecto.NoResultsError ->
      {:error, "Task not found"}
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
