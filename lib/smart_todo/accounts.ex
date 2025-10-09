defmodule SmartTodo.Accounts do
  @moduledoc """
  The Accounts context.
  """

  import Ecto.Query, warn: false
  alias SmartTodo.Repo

  alias SmartTodo.Accounts.{User, UserPreference, UserToken, Group, GroupMembership, UserAccessToken}

  ## Database getters

  # Email-based APIs removed

  @doc """
  Gets a user by username.
  """
  def get_user_by_username(username) when is_binary(username) do
    User
    |> Repo.get_by(username: username)
    |> preload_user_preference()
  end

  @doc """
  Gets a user by username and password.
  """
  def get_user_by_username_and_password(username, password)
      when is_binary(username) and is_binary(password) do
    user =
      User
      |> Repo.get_by(username: username)
      |> preload_user_preference()

    if User.valid_password?(user, password), do: user
  end

  @doc """
  Gets a single user.

  Raises `Ecto.NoResultsError` if the User does not exist.

  ## Examples

      iex> get_user!(123)
      %User{}

      iex> get_user!(456)
      ** (Ecto.NoResultsError)

  """
  def get_user!(id) do
    User
    |> Repo.get!(id)
    |> preload_user_preference()
  end

  ## User registration

  @doc """
  Registers a user with username and password (no email required).
  """
  def register_user(attrs) do
    %User{}
    |> User.registration_changeset(attrs)
    |> Repo.insert()
  end

  ## Settings

  @doc """
  Checks whether the user is in sudo mode.

  The user is in sudo mode when the last authentication was done no further
  than 20 minutes ago. The limit can be given as second argument in minutes.
  """
  def sudo_mode?(user, minutes \\ -20)

  def sudo_mode?(%User{authenticated_at: ts}, minutes) when is_struct(ts, DateTime) do
    DateTime.after?(ts, DateTime.utc_now() |> DateTime.add(minutes, :minute))
  end

  def sudo_mode?(_user, _minutes), do: false

  # Email change flows removed

  @doc """
  Returns an `%Ecto.Changeset{}` for changing the user password.

  See `SmartTodo.Accounts.User.password_changeset/3` for a list of supported options.

  ## Examples

      iex> change_user_password(user)
      %Ecto.Changeset{data: %User{}}

  """
  def change_user_password(user, attrs \\ %{}, opts \\ []) do
    User.password_changeset(user, attrs, opts)
  end

  @doc """
  Updates the user password.

  Returns a tuple with the updated user, as well as a list of expired tokens.

  ## Examples

      iex> update_user_password(user, %{password: ...})
      {:ok, {%User{}, [...]}}

      iex> update_user_password(user, %{password: "too short"})
      {:error, %Ecto.Changeset{}}

  """
  def update_user_password(user, attrs) do
    user
    |> User.password_changeset(attrs)
    |> update_user_and_delete_all_tokens()
  end

  ## Session

  @doc """
  Generates a session token.
  """
  def generate_user_session_token(user) do
    {token, user_token} = UserToken.build_session_token(user)
    Repo.insert!(user_token)
    token
  end

  @doc """
  Gets the user with the given signed token.

  If the token is valid `{user, token_inserted_at}` is returned, otherwise `nil` is returned.
  """
  def get_user_by_session_token(token) do
    {:ok, query} = UserToken.verify_session_token_query(token)

    case Repo.one(query) do
      nil -> nil
      {user, inserted_at} -> {preload_user_preference(user), inserted_at}
    end
  end

  # Email notifications removed

  @doc """
  Deletes the signed token with the given context.
  """
  def delete_user_session_token(token) do
    Repo.delete_all(from(UserToken, where: [token: ^token, context: "session"]))
    :ok
  end

  ## API tokens

  @doc """
  Lists the personal access tokens owned by the given user, sorted newest first.
  """
  def list_user_access_tokens(%User{id: user_id}) do
    UserAccessToken
    |> where(user_id: ^user_id)
    |> order_by([t], desc: t.inserted_at)
    |> Repo.all()
  end

  @doc """
  Generates and persists a new personal access token for the user.

  The plaintext token is returned alongside the persisted record so it can be
  shown to the caller once.
  """
  def create_user_access_token(%User{} = user) do
    {plaintext, attrs} = build_access_token_attrs()

    user
    |> Ecto.build_assoc(:access_tokens)
    |> UserAccessToken.changeset(attrs)
    |> Repo.insert()
    |> case do
      {:ok, access_token} -> {:ok, {plaintext, access_token}}
      {:error, changeset} -> {:error, changeset}
    end
  end

  @doc """
  Rotates (regenerates) the secret for the given token belonging to the user.

  Returns the fresh plaintext token if successful.
  """
  def rotate_user_access_token(%User{} = user, token_id) when is_integer(token_id) do
    case Repo.get_by(UserAccessToken, id: token_id, user_id: user.id) do
      %UserAccessToken{} = token ->
        {plaintext, attrs} = build_access_token_attrs()

        token
        |> UserAccessToken.changeset(attrs)
        |> Repo.update()
        |> case do
          {:ok, updated_token} -> {:ok, {plaintext, updated_token}}
          {:error, changeset} -> {:error, changeset}
        end

      nil ->
        {:error, :not_found}
    end
  end

  def rotate_user_access_token(%User{} = user, token_id) when is_binary(token_id) do
    case Integer.parse(token_id) do
      {id, ""} -> rotate_user_access_token(user, id)
      _ -> {:error, :not_found}
    end
  end

  @doc """
  Deletes the given personal access token owned by the user.
  """
  def delete_user_access_token(%User{} = user, token_id) when is_integer(token_id) do
    case Repo.get_by(UserAccessToken, id: token_id, user_id: user.id) do
      %UserAccessToken{} = token ->
        case Repo.delete(token) do
          {:ok, _} -> :ok
          {:error, _} = error -> error
        end

      nil ->
        {:error, :not_found}
    end
  end

  def delete_user_access_token(%User{} = user, token_id) when is_binary(token_id) do
    case Integer.parse(token_id) do
      {id, ""} -> delete_user_access_token(user, id)
      _ -> {:error, :not_found}
    end
  end

  ## Token helper

  defp update_user_and_delete_all_tokens(changeset) do
    Repo.transact(fn ->
      with {:ok, user} <- Repo.update(changeset) do
        tokens_to_expire = Repo.all_by(UserToken, user_id: user.id)

        Repo.delete_all(from(t in UserToken, where: t.id in ^Enum.map(tokens_to_expire, & &1.id)))

        {:ok, {user, tokens_to_expire}}
      end
    end)
  end

  @api_token_size 32
  @token_prefix_length 8

  defp build_access_token_attrs do
    plaintext =
      :crypto.strong_rand_bytes(@api_token_size)
      |> Base.url_encode64(padding: false)

    hash = :crypto.hash(:sha256, plaintext)
    prefix = String.slice(plaintext, 0, @token_prefix_length)

    {plaintext, %{token_hash: hash, token_prefix: prefix}}
  end

  ## User preferences

  @doc """
  Returns a changeset for updating the user's LLM preferences.
  """
  def change_user_preferences(%User{} = user, attrs \\ %{}) do
    user
    |> preference_struct()
    |> UserPreference.changeset(attrs)
  end

  @doc """
  Creates or updates the user's LLM preferences.
  """
  def upsert_user_preferences(%User{} = user, attrs) when is_map(attrs) do
    changeset = change_user_preferences(user, attrs)

    if changeset.data.id do
      Repo.update(changeset)
    else
      Repo.insert(changeset)
    end
  end

  @doc """
  Fetches the persisted user preferences if they exist.
  """
  def get_user_preferences(%User{} = user) do
    case preload_user_preference(user).preference do
      %UserPreference{} = preference -> preference
      _ -> nil
    end
  end

  defp preload_user_preference(nil), do: nil

  defp preload_user_preference(%User{} = user) do
    Repo.preload(user, :preference)
  end

  defp preference_struct(%User{preference: %UserPreference{} = pref}), do: pref

  defp preference_struct(%User{} = user) do
    preloaded = preload_user_preference(user)

    case preloaded.preference do
      %UserPreference{} = preference -> preference
      _ -> Ecto.build_assoc(preloaded, :preference)
    end
  end

  ## Group management

  @doc """
  Gets a group by id.
  """
  def get_group!(id) do
    Group
    |> Repo.get!(id)
    |> Repo.preload([:created_by_user, :user_members, :group_members])
  end

  @doc """
  Gets a group by name.
  """
  def get_group_by_name(name) when is_binary(name) do
    Group
    |> Repo.get_by(name: name)
    |> case do
      nil -> nil
      group -> Repo.preload(group, [:created_by_user, :user_members, :group_members])
    end
  end

  @doc """
  Creates a new group.
  """
  def create_group(%User{} = creator, attrs) do
    %Group{}
    |> Group.changeset(Map.put(attrs, "created_by_user_id", creator.id))
    |> Repo.insert()
  end

  @doc """
  Updates a group.
  """
  def update_group(%Group{} = group, attrs) do
    group
    |> Group.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Deletes a group.
  """
  def delete_group(%Group{} = group) do
    Repo.delete(group)
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking group changes.
  """
  def change_group(%Group{} = group, attrs \\ %{}) do
    Group.changeset(group, attrs)
  end

  @doc """
  Adds a user to a group.
  """
  def add_user_to_group(%Group{} = group, %User{} = user) do
    %GroupMembership{}
    |> GroupMembership.changeset(%{group_id: group.id, user_id: user.id})
    |> Repo.insert()
  end

  @doc """
  Adds a group to another group (nested groups).
  """
  def add_group_to_group(%Group{} = parent_group, %Group{} = member_group) do
    if parent_group.id == member_group.id do
      {:error, "cannot add group to itself"}
    else
      %GroupMembership{}
      |> GroupMembership.changeset(%{group_id: parent_group.id, member_group_id: member_group.id})
      |> Repo.insert()
    end
  end

  @doc """
  Removes a user from a group.
  """
  def remove_user_from_group(%Group{} = group, %User{} = user) do
    from(gm in GroupMembership,
      where: gm.group_id == ^group.id and gm.user_id == ^user.id
    )
    |> Repo.delete_all()

    :ok
  end

  @doc """
  Removes a group from another group.
  """
  def remove_group_from_group(%Group{} = parent_group, %Group{} = member_group) do
    from(gm in GroupMembership,
      where: gm.group_id == ^parent_group.id and gm.member_group_id == ^member_group.id
    )
    |> Repo.delete_all()

    :ok
  end

  @doc """
  Lists all groups.
  """
  def list_groups do
    Group
    |> Repo.all()
    |> Repo.preload([:created_by_user, :user_members, :group_members])
  end

  @doc """
  Lists groups created by a specific user.
  """
  def list_groups_created_by(%User{} = user) do
    from(g in Group, where: g.created_by_user_id == ^user.id)
    |> Repo.all()
    |> Repo.preload([:created_by_user, :user_members, :group_members])
  end

  @doc """
  Gets all users that are members of a group (including through nested groups).
  This function resolves nested group memberships recursively.
  """
  def get_all_group_members(%Group{} = group) do
    get_all_group_members_recursive([group.id], MapSet.new())
  end

  defp get_all_group_members_recursive(group_ids, visited_groups) do
    # Avoid infinite loops in case of circular group references
    new_group_ids = Enum.reject(group_ids, &MapSet.member?(visited_groups, &1))

    if Enum.empty?(new_group_ids) do
      []
    else
      updated_visited = Enum.reduce(new_group_ids, visited_groups, &MapSet.put(&2, &1))

      # Get direct user members
      direct_users =
        from(gm in GroupMembership,
          join: u in User, on: gm.user_id == u.id,
          where: gm.group_id in ^new_group_ids and not is_nil(gm.user_id),
          select: u
        )
        |> Repo.all()

      # Get nested group IDs
      nested_group_ids =
        from(gm in GroupMembership,
          where: gm.group_id in ^new_group_ids and not is_nil(gm.member_group_id),
          select: gm.member_group_id
        )
        |> Repo.all()

      # Recursively get users from nested groups
      nested_users = get_all_group_members_recursive(nested_group_ids, updated_visited)

      (direct_users ++ nested_users)
      |> Enum.uniq_by(& &1.id)
    end
  end
end
