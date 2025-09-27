defmodule SmartTodo.Accounts.Group do
  use Ecto.Schema
  import Ecto.Changeset

  alias SmartTodo.Accounts.{User, GroupMembership}

  schema "groups" do
    field :name, :string
    field :description, :string
    belongs_to :created_by_user, User

    has_many :memberships, GroupMembership
    has_many :user_members, through: [:memberships, :user]
    has_many :group_members, through: [:memberships, :member_group]

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(group, attrs) do
    group
    |> cast(attrs, [:name, :description, :created_by_user_id])
    |> validate_required([:name, :created_by_user_id])
    |> validate_length(:name, min: 1, max: 100)
    |> validate_length(:description, max: 1000)
    |> unique_constraint(:name)
  end
end