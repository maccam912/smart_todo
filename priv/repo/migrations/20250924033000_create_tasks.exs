defmodule SmartTodo.Repo.Migrations.CreateTasks do
  use Ecto.Migration

  def change do
    create table(:tasks) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :assignee_id, references(:users, on_delete: :nilify_all)

      add :title, :string, null: false
      add :description, :text
      add :status, :string, null: false, default: "todo"
      add :urgency, :string, null: false, default: "normal"
      add :due_date, :date
      add :recurrence, :string, null: false, default: "none"

      timestamps(type: :utc_datetime)
    end

    create index(:tasks, [:user_id])
    create index(:tasks, [:assignee_id])
    create index(:tasks, [:status])
    create index(:tasks, [:due_date])
  end
end
