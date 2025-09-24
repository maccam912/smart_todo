defmodule SmartTodo.Repo.Migrations.AddUsernameAndMakeEmailOptional do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :username, :citext, null: true
      modify :email, :citext, null: true
    end

    create unique_index(:users, [:username])
  end
end
