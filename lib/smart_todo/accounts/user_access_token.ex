defmodule SmartTodo.Accounts.UserAccessToken do
  use Ecto.Schema
  import Ecto.Changeset

  schema "user_access_tokens" do
    field :token_hash, :binary
    field :token_prefix, :string

    belongs_to :user, SmartTodo.Accounts.User

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(user_access_token, attrs) do
    user_access_token
    |> cast(attrs, [:token_hash, :token_prefix])
    |> validate_required([:token_hash, :token_prefix])
    |> validate_length(:token_prefix, min: 4, max: 32)
    |> unique_constraint(:token_hash)
  end
end
