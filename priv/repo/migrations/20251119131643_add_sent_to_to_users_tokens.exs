defmodule SmartTodo.Repo.Migrations.AddSentToToUsersTokens do
  use Ecto.Migration

  def change do
    alter table(:users_tokens) do
      add :sent_to, :string
    end
  end
end
