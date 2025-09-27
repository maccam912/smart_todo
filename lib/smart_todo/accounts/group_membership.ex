defmodule SmartTodo.Accounts.GroupMembership do
  use Ecto.Schema
  import Ecto.Changeset

  alias SmartTodo.Accounts.{User, Group}

  schema "group_memberships" do
    belongs_to :group, Group
    belongs_to :user, User
    belongs_to :member_group, Group

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(membership, attrs) do
    membership
    |> cast(attrs, [:group_id, :user_id, :member_group_id])
    |> validate_required([:group_id])
    |> validate_exactly_one_member()
    |> unique_constraint([:group_id, :user_id])
    |> unique_constraint([:group_id, :member_group_id])
  end

  defp validate_exactly_one_member(changeset) do
    user_id = get_field(changeset, :user_id)
    member_group_id = get_field(changeset, :member_group_id)

    case {user_id, member_group_id} do
      {nil, nil} ->
        add_error(changeset, :base, "must specify either user_id or member_group_id")

      {_user_id, _member_group_id} when not is_nil(user_id) and not is_nil(member_group_id) ->
        add_error(changeset, :base, "cannot specify both user_id and member_group_id")

      _ ->
        changeset
    end
  end
end