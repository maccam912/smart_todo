defmodule SmartTodo.TasksTest do
  use SmartTodo.DataCase, async: true

  import SmartTodo.AccountsFixtures
  import SmartTodo.TasksFixtures

  alias SmartTodo.Tasks
  alias SmartTodo.Accounts.Scope

  describe "create_task/2" do
    test "creates a task for current user and assigns owner as assignee" do
      user = user_fixture()
      scope = Scope.for_user(user)

      {:ok, task} = Tasks.create_task(scope, %{title: "Write tests"})

      assert task.user_id == user.id
      assert task.assignee_id == user.id
      assert task.title == "Write tests"
    end

    test "accepts prerequisite_ids and persists dependencies" do
      user = user_fixture()
      scope = Scope.for_user(user)
      a = task_fixture(user, %{title: "A"})
      b = task_fixture(user, %{title: "B"})

      {:ok, t} = Tasks.create_task(scope, %{title: "T", prerequisite_ids: [a.id, b.id]})
      t = Tasks.get_task!(scope, t.id)
      assert Enum.sort(Enum.map(t.prerequisites, & &1.id)) == Enum.sort([a.id, b.id])
    end
  end

  describe "scoping and access" do
    test "get_task!/2 raises for other users' tasks" do
      owner = user_fixture()
      other = user_fixture()
      t = task_fixture(owner)

      assert_raise Ecto.NoResultsError, fn ->
        Tasks.get_task!(Scope.for_user(other), t.id)
      end
    end

    test "list_tasks/2 returns only the current user's tasks" do
      u1 = user_fixture()
      u2 = user_fixture()
      t1 = task_fixture(u1)
      _t2 = task_fixture(u2)

      ids = Tasks.list_tasks(Scope.for_user(u1)) |> Enum.map(& &1.id)
      assert ids == [t1.id]
    end
  end

  describe "dependencies and completion" do
    test "cannot complete when prerequisites are incomplete" do
      user = user_fixture()
      scope = Scope.for_user(user)

      a = task_fixture(user, %{title: "A"})
      b = task_with_prereqs_fixture(user, 0, %{title: "B"})
      assert {:ok, :ok} = Tasks.upsert_dependencies(scope, b.id, [a.id])
      b = Tasks.get_task!(scope, b.id)

      assert {:error, %Ecto.Changeset{} = cs} = Tasks.complete_task(scope, b)

      assert {"cannot complete: has incomplete prerequisites", _} =
               Keyword.get(cs.errors, :status)
    end

    test "completing a task with recurrence creates next instance" do
      user = user_fixture()
      scope = Scope.for_user(user)
      due = ~D[2025-09-24]

      t = task_fixture(user, %{title: "R", recurrence: :daily, due_date: due})
      {:ok, done} = Tasks.complete_task(scope, t)
      assert done.status == :done

      # The next instance should exist with advanced due date and todo status
      next_titles =
        Tasks.list_tasks(scope) |> Enum.filter(&(&1.title == "R" and &1.status == :todo))

      assert Enum.any?(next_titles)
      assert Enum.any?(next_titles, &(&1.due_date == Date.add(due, 1)))
    end

    test "upsert_dependencies replaces the full set" do
      user = user_fixture()
      scope = Scope.for_user(user)
      a = task_fixture(user, %{title: "A"})
      b = task_fixture(user, %{title: "B"})
      t = task_fixture(user, %{title: "T"})

      assert {:ok, :ok} = Tasks.upsert_dependencies(scope, t.id, [a.id])
      t = Tasks.get_task!(scope, t.id)
      assert Enum.map(t.prerequisites, & &1.id) == [a.id]

      assert {:ok, :ok} = Tasks.upsert_dependencies(scope, t.id, [b.id])
      t = Tasks.get_task!(scope, t.id)
      assert Enum.map(t.prerequisites, & &1.id) == [b.id]
    end
  end
end
