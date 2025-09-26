defmodule SmartTodo.Accounts.UserPreference do
  use Ecto.Schema
  import Ecto.Changeset

  alias SmartTodo.Accounts.User

  schema "user_preferences" do
    field :prompt_preferences, :string
    belongs_to :user, User

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(preference, attrs) do
    preference
    |> cast(attrs, [:prompt_preferences])
    |> update_change(:prompt_preferences, &normalize_text/1)
    |> validate_length(:prompt_preferences, max: 2000)
  end

  defp normalize_text(text) when is_binary(text) do
    text
    |> String.trim()
    |> case do
      "" -> nil
      value -> value
    end
  end

  defp normalize_text(other), do: other
end
