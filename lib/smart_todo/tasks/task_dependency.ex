defmodule SmartTodo.Tasks.TaskDependency do
  use Ecto.Schema
  import Ecto.Changeset

  alias SmartTodo.Tasks.Task

  @moduledoc """
  Self-referential join between tasks to express prerequisites.
  `prereq` must be completed before `blocked`.
  """

  schema "task_dependencies" do
    belongs_to :blocked, Task, foreign_key: :blocked_task_id
    belongs_to :prereq, Task, foreign_key: :prereq_task_id

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(dep, attrs) do
    dep
    |> cast(attrs, [:blocked_task_id, :prereq_task_id])
    |> validate_required([:blocked_task_id, :prereq_task_id])
    |> check_constraint(:blocked_task_id, name: :task_dependency_no_self_ref)
    |> unique_constraint([:blocked_task_id, :prereq_task_id], name: :task_dependencies_unique)
  end
end
