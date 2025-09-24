defmodule SmartTodo.TasksFixtures do
  @moduledoc false

  alias SmartTodo.Tasks
  alias SmartTodo.Accounts.Scope

  def task_fixture(user, attrs \\ %{}) do
    scope = Scope.for_user(user)
    attrs = Map.new(attrs)

    {:ok, task} =
      Tasks.create_task(scope, Map.put_new(attrs, :title, unique_task_title()))

    task
  end

  def task_with_prereqs_fixture(user, prereqs_count \\ 1, attrs \\ %{}) do
    prereqs =
      if prereqs_count > 0 do
        for _ <- 1..prereqs_count, do: task_fixture(user)
      else
        []
      end
    task = task_fixture(user, attrs)

    {:ok, :ok} =
      Tasks.upsert_dependencies(
        SmartTodo.Accounts.Scope.for_user(user),
        task.id,
        Enum.map(prereqs, & &1.id)
      )
    SmartTodo.Tasks.get_task!(Scope.for_user(user), task.id)
  end

  def unique_task_title do
    "task-" <> Integer.to_string(System.unique_integer([:positive]))
  end
end
