defmodule SmartTodo.AccountsFixtures do
  @moduledoc """
  This module defines test helpers for creating
  entities via the `SmartTodo.Accounts` context.
  """

  import Ecto.Query

  alias SmartTodo.Accounts
  alias SmartTodo.Accounts.Scope

  def unique_user_email, do: "user#{System.unique_integer()}@example.com"
  def unique_username, do: "user_#{System.unique_integer()}"
  def valid_user_password, do: "hello world!"

  def valid_registration_attributes(attrs \\ %{}) do
    Enum.into(attrs, %{
      username: unique_username(),
      password: valid_user_password()
    })
  end

  def unconfirmed_user_fixture(attrs \\ %{}) do
    attrs = valid_registration_attributes(attrs)
    {:ok, user} = Accounts.register_user(attrs)
    user
  end

  def user_fixture(attrs \\ %{}) do
    # For new flow, user is registered with password already.
    unconfirmed_user_fixture(attrs)
  end

  def user_scope_fixture do
    user = user_fixture()
    user_scope_fixture(user)
  end

  def user_scope_fixture(user) do
    Scope.for_user(user)
  end

  def set_password(user) do
    {:ok, {user, _expired_tokens}} =
      Accounts.update_user_password(user, %{password: valid_user_password()})

    user
  end

  def extract_user_token(fun) do
    {:ok, captured_email} = fun.(&"[TOKEN]#{&1}[TOKEN]")
    [_, token | _] = String.split(captured_email.text_body, "[TOKEN]")
    token
  end

  def override_token_authenticated_at(token, authenticated_at) when is_binary(token) do
    SmartTodo.Repo.update_all(
      from(t in Accounts.UserToken,
        where: t.token == ^token
      ),
      set: [authenticated_at: authenticated_at]
    )
  end

  # Magic link helpers removed in username/password flow

  def offset_user_token(token, amount_to_add, unit) do
    dt = DateTime.add(DateTime.utc_now(:second), amount_to_add, unit)

    SmartTodo.Repo.update_all(
      from(ut in Accounts.UserToken, where: ut.token == ^token),
      set: [inserted_at: dt, authenticated_at: dt]
    )
  end

  def user_access_token_fixture(user \\ user_fixture()) do
    {:ok, {token, access_token}} = Accounts.create_user_access_token(user)

    %{token: token, access_token: access_token}
  end
end
