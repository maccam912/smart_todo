defmodule SmartTodo.Tasks do
  @moduledoc """
  The Tasks context. All functions take `current_scope` as first argument.
  """
  import Ecto.Query
  alias SmartTodo.Repo

  alias SmartTodo.Accounts.Scope
  alias SmartTodo.Tasks.{Task, TaskDependency}

  @type scope :: %Scope{user: SmartTodo.Accounts.User.t()}

  defp user_id!(%Scope{user: %{id: id}}), do: id
  defp user_id!(nil), do: raise(ArgumentError, "current_scope required")

  @doc """
  Lists tasks for the current user. Accepts optional filters:
    - status: one of Task.status_values()
  Preloads prerequisites and dependents for UI.
  """
  def list_tasks(current_scope, opts \\ []) do
    uid = user_id!(current_scope)

    base =
      from t in Task,
        where: t.user_id == ^uid,
        preload: [
          prerequisites: [],
          dependents: []
        ]

    base =
      case Keyword.get(opts, :status) do
        nil ->
          base

        status ->
          if status in Task.status_values() do
            from t in base, where: t.status == ^status
          else
            base
          end
      end

    base
    |> order_by([t], asc: t.status, asc_nulls_last: t.due_date, desc: t.urgency)
    |> Repo.all()
  end

  @doc """
  Returns a single task (owned by current user) raising if not found.
  """
  def get_task!(current_scope, id) do
    uid = user_id!(current_scope)

    Task
    |> where([t], t.user_id == ^uid and t.id == ^id)
    |> preload([:prerequisites, :dependents])
    |> Repo.one!()
  end

  @doc """
  Builds a changeset for forms.
  """
  def change_task(%Task{} = task, attrs \\ %{}) do
    Task.changeset(task, attrs)
  end

  @doc """
  Creates a task for the current user.
  Accepts `:prerequisite_ids` for initial dependencies.
  """
  def create_task(current_scope, attrs) when is_map(attrs) do
    uid = user_id!(current_scope)

    prereq_ids = Map.get(attrs, "prerequisite_ids") || Map.get(attrs, :prerequisite_ids) || []
    attrs = Map.drop(attrs, ["prerequisite_ids", :prerequisite_ids])

    %Task{user_id: uid, assignee_id: uid}
    |> Task.changeset(attrs)
    |> Repo.insert()
    |> case do
      {:ok, task} ->
        _ = upsert_dependencies(current_scope, task.id, prereq_ids)
        {:ok, get_task!(current_scope, task.id)}

      error ->
        error
    end
  end

  @doc """
  Updates a task owned by the current user.
  """
  def update_task(current_scope, %Task{} = task, attrs) do
    _uid = user_id!(current_scope)

    task
    |> Task.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Marks a task as done if all prerequisites are complete. If the task has a
  recurrence, it will create the next instance with the due date advanced.
  """
  def complete_task(current_scope, %Task{} = task) do
    _uid = user_id!(current_scope)

    task = Repo.preload(task, :prerequisites)
    prerequisites_done? = Enum.all?(task.prerequisites, &(&1.status == :done))

    cs =
      task
      |> Task.changeset(%{status: :done})
      |> Task.validate_can_complete(prerequisites_done?)

    Repo.transaction(fn ->
      case Repo.update(cs) do
        {:ok, task} ->
          if task.recurrence != :none do
            next_due = advance_due_date(task.due_date, task.recurrence)
            _ =
              %Task{user_id: task.user_id, assignee_id: task.assignee_id}
              |> Task.changeset(%{
                title: task.title,
                description: task.description,
                urgency: task.urgency,
                due_date: next_due,
                recurrence: task.recurrence,
                status: :todo
              })
              |> Repo.insert()
          end

          task

        {:error, cs} ->
          Repo.rollback(cs)
      end
    end)
  end

  defp advance_due_date(nil, _), do: nil
  defp advance_due_date(%Date{} = d, :daily), do: Date.add(d, 1)
  defp advance_due_date(%Date{} = d, :weekly), do: Date.add(d, 7)
  defp advance_due_date(%Date{} = d, :monthly), do: Date.add(d, 30)
  defp advance_due_date(%Date{} = d, :yearly), do: Date.add(d, 365)
  defp advance_due_date(d, _), do: d

  @doc """
  Adds a dependency: `prereq` must complete before `blocked`.
  Validates both tasks belong to current user.
  """
  def add_dependency(current_scope, blocked_task_id, prereq_task_id) do
    uid = user_id!(current_scope)

    with true <- task_owned_by?(uid, blocked_task_id),
         true <- task_owned_by?(uid, prereq_task_id) do
      %TaskDependency{}
      |> TaskDependency.changeset(%{
        blocked_task_id: blocked_task_id,
        prereq_task_id: prereq_task_id
      })
      |> Repo.insert()
    else
      _ -> {:error, :not_found}
    end
  end

  @doc """
  Replaces the set of prerequisites for a given blocked task.
  """
  def upsert_dependencies(current_scope, blocked_task_id, prereq_ids) when is_list(prereq_ids) do
    uid = user_id!(current_scope)
    # Only allow deps within the same owner
    valid_ids =
      from(t in Task, where: t.user_id == ^uid and t.id in ^prereq_ids, select: t.id)
      |> Repo.all()

    Repo.transaction(fn ->
      from(d in TaskDependency, where: d.blocked_task_id == ^blocked_task_id)
      |> Repo.delete_all()

      now = DateTime.utc_now(:second)
      inserts =
        Enum.map(valid_ids, fn id ->
          %{
            blocked_task_id: blocked_task_id,
            prereq_task_id: id,
            inserted_at: now,
            updated_at: now
          }
        end)

      Repo.insert_all(TaskDependency, inserts)
      :ok
    end)
  end

  def remove_dependency(current_scope, blocked_task_id, prereq_task_id) do
    _uid = user_id!(current_scope)

    from(d in TaskDependency,
      where: d.blocked_task_id == ^blocked_task_id and d.prereq_task_id == ^prereq_task_id
    )
    |> Repo.delete_all()

    :ok
  end

  defp task_owned_by?(uid, id) do
    from(t in Task, where: t.user_id == ^uid and t.id == ^id, select: 1)
    |> Repo.one()
    |> Kernel.==(1)
  end
end
