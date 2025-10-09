defmodule SmartTodo.Repo.Migrations.AddGroupAssignmentToTasks do
  use Ecto.Migration

  def change do
    alter table(:tasks) do
      add :assigned_group_id, references(:groups, on_delete: :nilify_all)
    end

    create index(:tasks, [:assigned_group_id])

    # Ensure task is assigned to either a user OR a group, not both
    create constraint(:tasks, :exactly_one_assignee_type,
             check:
               "(assignee_id IS NOT NULL AND assigned_group_id IS NULL) OR (assignee_id IS NULL AND assigned_group_id IS NOT NULL) OR (assignee_id IS NULL AND assigned_group_id IS NULL)"
           )
  end
end
