defmodule SmartTodo.Repo.Migrations.AddNotesToTasks do
  use Ecto.Migration

  def change do
    alter table(:tasks) do
      add :notes, :text
    end
  end
end
