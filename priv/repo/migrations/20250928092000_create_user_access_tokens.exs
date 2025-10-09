defmodule SmartTodo.Repo.Migrations.CreateUserAccessTokens do
  use Ecto.Migration

  def change do
    create table(:user_access_tokens) do
      add :token_hash, :binary, null: false
      add :token_prefix, :string, null: false
      add :user_id, references(:users, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime)
    end

    create index(:user_access_tokens, [:user_id])
    create unique_index(:user_access_tokens, [:token_hash])
  end
end
