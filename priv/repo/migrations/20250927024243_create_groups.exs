defmodule SmartTodo.Repo.Migrations.CreateGroups do
  use Ecto.Migration

  def change do
    create table(:groups) do
      add :name, :string, null: false
      add :description, :text
      add :created_by_user_id, references(:users, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:groups, [:name])
    create index(:groups, [:created_by_user_id])

    # Group membership table - supports both users and nested groups
    create table(:group_memberships) do
      add :group_id, references(:groups, on_delete: :delete_all), null: false
      add :user_id, references(:users, on_delete: :delete_all)
      add :member_group_id, references(:groups, on_delete: :delete_all)

      timestamps(type: :utc_datetime)
    end

    create index(:group_memberships, [:group_id])
    create index(:group_memberships, [:user_id])
    create index(:group_memberships, [:member_group_id])
    create unique_index(:group_memberships, [:group_id, :user_id], where: "user_id IS NOT NULL")
    create unique_index(:group_memberships, [:group_id, :member_group_id], where: "member_group_id IS NOT NULL")

    # Ensure each membership has exactly one type (user OR group)
    create constraint(:group_memberships, :exactly_one_member_type,
      check: "(user_id IS NOT NULL AND member_group_id IS NULL) OR (user_id IS NULL AND member_group_id IS NOT NULL)"
    )
  end
end
