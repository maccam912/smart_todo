defmodule SmartTodo.GroupAssignmentTest do
  use SmartTodo.DataCase

  alias SmartTodo.{Accounts, Tasks}
  alias SmartTodo.Accounts.Scope

  describe "group functionality" do
    setup do
      # Create test users
      {:ok, user1} =
        Accounts.register_user(%{"username" => "user1", "password" => "password123456"})

      {:ok, user2} =
        Accounts.register_user(%{"username" => "user2", "password" => "password123456"})

      {:ok, user3} =
        Accounts.register_user(%{"username" => "user3", "password" => "password123456"})

      scope1 = %Scope{user: user1}
      scope2 = %Scope{user: user2}

      %{user1: user1, user2: user2, user3: user3, scope1: scope1, scope2: scope2}
    end

    test "creates groups and manages memberships", %{user1: user1, user2: user2, user3: user3} do
      # Create a group
      {:ok, group} =
        Accounts.create_group(user1, %{
          "name" => "Development Team",
          "description" => "Main dev team"
        })

      assert group.name == "Development Team"
      assert group.created_by_user_id == user1.id

      # Add users to group
      {:ok, _membership1} = Accounts.add_user_to_group(group, user2)
      {:ok, _membership2} = Accounts.add_user_to_group(group, user3)

      # Get group members
      members = Accounts.get_all_group_members(group)
      member_ids = Enum.map(members, & &1.id) |> Enum.sort()

      assert member_ids == [user2.id, user3.id] |> Enum.sort()
    end

    test "creates nested groups", %{user1: user1, user2: user2} do
      # Create parent and child groups
      {:ok, parent_group} =
        Accounts.create_group(user1, %{"name" => "Engineering", "description" => "All engineers"})

      {:ok, child_group} =
        Accounts.create_group(user1, %{
          "name" => "Frontend Team",
          "description" => "Frontend developers"
        })

      # Add user to child group
      {:ok, _membership} = Accounts.add_user_to_group(child_group, user2)

      # Add child group to parent group
      {:ok, _group_membership} = Accounts.add_group_to_group(parent_group, child_group)

      # Get all members of parent group (should include members from child group)
      members = Accounts.get_all_group_members(parent_group)
      member_ids = Enum.map(members, & &1.id)

      assert user2.id in member_ids
    end

    test "assigns tasks to groups and users", %{user1: user1, user2: user2, scope1: scope1} do
      # Create a group and add user2 to it
      {:ok, group} =
        Accounts.create_group(user1, %{"name" => "QA Team", "description" => "Quality assurance"})

      {:ok, _membership} = Accounts.add_user_to_group(group, user2)

      # Create task assigned to group
      {:ok, task1} =
        Tasks.create_task(scope1, %{
          "title" => "Test group assignment",
          "assigned_group_id" => group.id
        })

      assert task1.assigned_group_id == group.id
      assert task1.assignee_id == nil

      # Create task assigned to user
      {:ok, task2} =
        Tasks.create_task(scope1, %{
          "title" => "Test user assignment",
          "assignee_id" => user2.id
        })

      assert task2.assignee_id == user2.id
      assert task2.assigned_group_id == nil

      # Test reassignment
      {:ok, updated_task} = Tasks.assign_task_to_group(scope1, task2, group.id)
      assert updated_task.assigned_group_id == group.id
      assert updated_task.assignee_id == nil

      # Test unassignment
      {:ok, unassigned_task} = Tasks.unassign_task(scope1, updated_task)
      assert unassigned_task.assigned_group_id == nil
      assert unassigned_task.assignee_id == nil
    end

    test "lists tasks assigned to users and groups", %{user1: user1, user2: user2, scope1: scope1} do
      # Create group and add user2
      {:ok, group} =
        Accounts.create_group(user1, %{
          "name" => "Backend Team",
          "description" => "Backend developers"
        })

      {:ok, _membership} = Accounts.add_user_to_group(group, user2)

      # Create tasks
      {:ok, _task1} =
        Tasks.create_task(scope1, %{
          "title" => "Direct user task",
          "assignee_id" => user2.id
        })

      {:ok, _task2} =
        Tasks.create_task(scope1, %{
          "title" => "Group task",
          "assigned_group_id" => group.id
        })

      # Get tasks assigned to user2 (should include both direct and group assignments)
      assigned_tasks = Tasks.list_tasks_assigned_to_user(scope1, user2.id)
      task_titles = Enum.map(assigned_tasks, & &1.title) |> Enum.sort()

      assert "Direct user task" in task_titles
      assert "Group task" in task_titles

      # Get tasks assigned to group
      group_tasks = Tasks.list_tasks_assigned_to_group(scope1, group.id)
      group_task_titles = Enum.map(group_tasks, & &1.title)

      assert "Group task" in group_task_titles
      assert "Direct user task" not in group_task_titles
    end
  end
end
