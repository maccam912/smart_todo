defmodule SmartTodo.TasksTest do
  use SmartTodo.DataCase, async: true

  import SmartTodo.AccountsFixtures
  import SmartTodo.TasksFixtures

  alias SmartTodo.{Accounts, Tasks}
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

    test "stores optional notes" do
      user = user_fixture()
      scope = Scope.for_user(user)

      {:ok, task} =
        Tasks.create_task(scope, %{
          "title" => "Call client",
          "notes" => "Reach out at 555-1234"
        })

      assert task.notes == "Reach out at 555-1234"
    end

    test "accepts deferred_until date" do
      user = user_fixture()
      scope = Scope.for_user(user)
      tomorrow = Date.add(Date.utc_today(), 1)

      {:ok, task} =
        Tasks.create_task(scope, %{
          title: "Snoozed",
          deferred_until: Date.to_iso8601(tomorrow)
        })

      assert task.deferred_until == tomorrow
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

  describe "update_task/3" do
    test "updates task attributes" do
      user = user_fixture()
      scope = Scope.for_user(user)
      task = task_fixture(user, %{title: "Initial"})

      assert {:ok, updated} =
               Tasks.update_task(scope, task, %{
                 "title" => "Revised",
                 "notes" => "Discuss blockers"
               })

      assert updated.title == "Revised"
      assert updated.notes == "Discuss blockers"
    end

    test "replaces prerequisites when ids provided" do
      user = user_fixture()
      scope = Scope.for_user(user)
      prereq = task_fixture(user, %{title: "Prep"})
      other = task_fixture(user, %{title: "Other"})
      task = task_fixture(user, %{title: "Main"})

      assert {:ok, :ok} = Tasks.upsert_dependencies(scope, task.id, [other.id])

      assert {:ok, updated} =
               Tasks.update_task(scope, task, %{
                 "prerequisite_ids" => [Integer.to_string(prereq.id)]
               })

      assert Enum.map(updated.prerequisites, & &1.id) == [prereq.id]
    end
  end

  describe "delete_task/2" do
    test "removes the task and cascading dependencies" do
      user = user_fixture()
      scope = Scope.for_user(user)
      prereq = task_fixture(user)
      task = task_fixture(user)

      assert {:ok, :ok} = Tasks.upsert_dependencies(scope, task.id, [prereq.id])

      assert {:ok, deleted} = Tasks.delete_task(scope, task.id)
      assert deleted.id == task.id
      assert_raise Ecto.NoResultsError, fn -> Tasks.get_task!(scope, task.id) end
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

    test "list_tasks/2 returns owned and assigned tasks for a user" do
      owner = user_fixture()
      member = user_fixture()
      outsider = user_fixture()

      scope_owner = Scope.for_user(owner)
      scope_member = Scope.for_user(member)
      scope_outsider = Scope.for_user(outsider)

      {:ok, group} = Accounts.create_group(owner, %{"name" => "Team", "description" => "Test"})
      {:ok, _membership} = Accounts.add_user_to_group(group, member)

      owner_task = task_fixture(owner, %{title: "Owner"})
      direct_assignment = task_fixture(owner, %{title: "Direct", assignee_id: member.id})
      group_assignment = task_fixture(owner, %{title: "Group", assigned_group_id: group.id})
      member_task = task_fixture(member, %{title: "Member"})
      outsider_task = task_fixture(outsider, %{title: "Outsider"})

      owner_titles =
        Tasks.list_tasks(scope_owner)
        |> Enum.map(& &1.title)
        |> Enum.sort()

      assert owner_titles ==
               Enum.sort([owner_task.title, direct_assignment.title, group_assignment.title])

      member_titles =
        Tasks.list_tasks(scope_member)
        |> Enum.map(& &1.title)
        |> Enum.sort()

      assert member_titles ==
               Enum.sort([member_task.title, direct_assignment.title, group_assignment.title])

      outsider_titles =
        Tasks.list_tasks(scope_outsider)
        |> Enum.map(& &1.title)
        |> Enum.sort()

      assert outsider_titles == [outsider_task.title]
    end

    test "list_tasks/2 returns an empty list when scope is nil" do
      assert Tasks.list_tasks(nil) == []
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
