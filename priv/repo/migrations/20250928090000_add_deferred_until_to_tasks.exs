defmodule SmartTodo.Repo.Migrations.AddDeferredUntilToTasks do
  use Ecto.Migration

  def change do
    alter table(:tasks) do
      add :deferred_until, :date
    end

    create index(:tasks, [:deferred_until])
  end
end
