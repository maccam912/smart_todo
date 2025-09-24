defmodule SmartTodo.Repo.Migrations.EnforceUsernameNotNull do
  use Ecto.Migration

  def up do
    execute("update users set username = concat('user_', id) where username is null")

    alter table(:users) do
      modify :username, :citext, null: false
    end
  end

  def down do
    alter table(:users) do
      modify :username, :citext, null: true
    end
  end
end
