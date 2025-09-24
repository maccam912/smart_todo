defmodule SmartTodo.Repo.Migrations.CreateTaskDependencies do
  use Ecto.Migration

  def change do
    create table(:task_dependencies) do
      add :blocked_task_id, references(:tasks, on_delete: :delete_all), null: false
      add :prereq_task_id, references(:tasks, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:task_dependencies, [:blocked_task_id, :prereq_task_id],
             name: :task_dependencies_unique
           )

    create constraint(:task_dependencies, :task_dependency_no_self_ref,
             check: "blocked_task_id <> prereq_task_id"
           )

    create index(:task_dependencies, [:blocked_task_id])
    create index(:task_dependencies, [:prereq_task_id])
  end
end
