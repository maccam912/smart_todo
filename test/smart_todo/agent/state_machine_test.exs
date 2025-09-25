defmodule SmartTodo.Agent.StateMachineTest do
  use SmartTodo.DataCase, async: true

  alias SmartTodo.Agent.StateMachine
  alias SmartTodo.AccountsFixtures
  alias SmartTodo.Tasks
  alias SmartTodo.TasksFixtures

  describe "start_session/1" do
    test "includes open tasks and command metadata" do
      scope = AccountsFixtures.user_scope_fixture()
      done_task = TasksFixtures.task_fixture(scope.user)
      {:ok, _done} = Tasks.update_task(scope, done_task, %{"status" => "done"})
      active_task = TasksFixtures.task_fixture(scope.user, %{title: "Active"})

      {machine, response} = StateMachine.start_session(scope)

      assert machine.state == :awaiting_command
      assert response.state == "awaiting_command"
      assert Enum.any?(response.available_commands, &(&1.name == "select_task"))
      assert Enum.any?(response.open_tasks, fn task -> task.title == active_task.title end)
      refute Enum.any?(response.open_tasks, fn task -> task.title == done_task.title end)
    end
  end

  describe "command flow" do
    setup do
      scope = AccountsFixtures.user_scope_fixture()
      {machine, _} = StateMachine.start_session(scope)
      {:ok, scope: scope, machine: machine}
    end

    test "stages task creation and allows selecting by pending_ref", %{machine: machine} do
      {:ok, machine, response} =
        StateMachine.handle_command(machine, :create_task, %{"title" => "Draft blog post"})

      assert Enum.any?(response.pending_operations, &(&1.target == "pending:1"))
      assert Enum.any?(response.open_tasks, &(&1.target == "pending:1"))

      {:ok, machine, response} =
        StateMachine.handle_command(machine, :select_task, %{"pending_ref" => 1})

      assert machine.state == {:editing_task, {:pending, 1}}
      assert response.state == "editing:pending:1"
    end

    test "updating an existing task merges staged changes and commits inside a transaction", %{
      machine: machine,
      scope: scope
    } do
      task = TasksFixtures.task_fixture(scope.user, %{title: "Review PR"})

      {:ok, machine, _} =
        StateMachine.handle_command(machine, :select_task, %{"task_id" => task.id})

      params = %{"description" => "Double-check boundary cases", "urgency" => "high"}

      {:ok, machine, response} =
        StateMachine.handle_command(machine, :update_task_fields, params)

      assert get_in(response, [:editing, :pending_changes, "description"]) ==
               "Double-check boundary cases"

      assert get_in(response, [:editing, :pending_changes, "urgency"]) == "high"

      {:ok, machine, response} = StateMachine.handle_command(machine, :complete_session, %{})

      assert machine.state == :completed
      assert response.state == "completed"
      assert response.message =~ "Session committed"

      updated = Tasks.get_task!(scope, task.id)
      assert updated.description == "Double-check boundary cases"
      assert updated.urgency == :high
    end

    test "deleting a pending task removes it from the queue", %{machine: machine} do
      {:ok, machine, _} =
        StateMachine.handle_command(machine, :create_task, %{"title" => "Temporary"})

      {:ok, machine, _} =
        StateMachine.handle_command(machine, :select_task, %{"pending_ref" => 1})

      {:ok, machine, response} = StateMachine.handle_command(machine, :delete_task, %{})

      assert response.message =~ "Pending task creation removed"
      assert machine.pending_ops == []
      assert response.state == "awaiting_command"
    end

    test "marking a task for completion removes it from the open preview", %{
      machine: machine,
      scope: scope
    } do
      task = TasksFixtures.task_fixture(scope.user)

      {:ok, machine, _} =
        StateMachine.handle_command(machine, :select_task, %{"task_id" => task.id})

      {:ok, machine, response} = StateMachine.handle_command(machine, :complete_task, %{})

      assert Enum.any?(machine.pending_ops, fn
               %{type: :complete_task, target: {:existing, id}} -> id == task.id
               _ -> false
             end)

      refute Enum.any?(response.open_tasks, fn item -> item.target == "existing:#{task.id}" end)
      assert response.message =~ "completed"
    end

    test "invalid staged changes keep the session active and report errors", %{
      machine: machine,
      scope: scope
    } do
      task = TasksFixtures.task_fixture(scope.user)

      {:ok, machine, _} =
        StateMachine.handle_command(machine, :select_task, %{"task_id" => task.id})

      too_long = String.duplicate("a", 300)

      {:ok, machine, _} =
        StateMachine.handle_command(machine, :update_task_fields, %{"title" => too_long})

      {:error, same_machine, response} =
        StateMachine.handle_command(machine, :complete_session, %{})

      assert same_machine.state == {:editing_task, {:existing, task.id}}
      assert response.error?
      assert response.state == "editing:existing:#{task.id}"
      assert response.message =~ "failed"

      reloaded = Tasks.get_task!(scope, task.id)
      refute reloaded.title == too_long
    end

    test "complete_session with no pending work closes the session", %{machine: machine} do
      {:ok, machine, response} = StateMachine.handle_command(machine, :complete_session, %{})

      assert machine.state == :completed
      assert response.state == "completed"
      assert response.available_commands == []
    end
  end
end
