defmodule SmartTodoWeb.UserLive.Settings do
  use SmartTodoWeb, :live_view

  on_mount {SmartTodoWeb.UserAuth, :require_sudo_mode}

  alias SmartTodo.Accounts

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="text-center">
        <.header>
          Account Settings
          <:subtitle>Manage your account password settings</:subtitle>
        </.header>
      </div>

      <div class="divider" />

      <.form
        for={@password_form}
        id="password_form"
        action={~p"/users/update-password"}
        method="post"
        phx-change="validate_password"
        phx-submit="update_password"
        phx-trigger-action={@trigger_submit}
      >
        <input
          name={@password_form[:username].name}
          type="hidden"
          id="hidden_user_username"
          autocomplete="username"
          value={@current_username}
        />
        <.input
          field={@password_form[:password]}
          type="password"
          label="New password"
          autocomplete="new-password"
          required
        />
        <.input
          field={@password_form[:password_confirmation]}
          type="password"
          label="Confirm new password"
          autocomplete="new-password"
        />
        <.button variant="primary" phx-disable-with="Saving...">
          Save Password
        </.button>
      </.form>

      <div class="divider" />

      <div class="text-center">
        <.header>
          Assistant Preferences
          <:subtitle>
            Provide optional guidance that will be sent with every automation prompt.
          </:subtitle>
        </.header>
      </div>

      <.form
        for={@preferences_form}
        id="preferences_form"
        phx-change="validate_preferences"
        phx-submit="save_preferences"
      >
        <.input
          field={@preferences_form[:prompt_preferences]}
          type="textarea"
          label="LLM instructions"
          placeholder="Share any preferences the assistant should always follow."
        />

        <.button variant="primary" phx-disable-with="Saving...">
          Save Preferences
        </.button>
      </.form>

      <div class="divider" />

      <div class="space-y-6">
        <div class="text-center">
          <.header>
            API Tokens
            <:subtitle>
              Generate, rotate, or remove personal access tokens for the upcoming API.
            </:subtitle>
          </.header>
        </div>

        <div :if={@last_token} class="alert alert-info shadow" role="status">
          <div>
            <p class="font-semibold">
              {if @last_token.action == :rotated, do: "Token rotated", else: "New token generated"}
            </p>
            <p class="mt-1 text-sm text-base-content/80">
              Copy this token now. It won't be shown again.
            </p>
            <code class="mt-2 block break-all rounded bg-base-200 p-3 font-mono text-sm">
              {@last_token.value}
            </code>
          </div>
        </div>

        <div class="flex flex-col gap-4 sm:flex-row sm:items-center sm:justify-between">
          <p class="text-sm text-base-content/80">
            Use tokens to authenticate future API requests. Rotate them regularly to keep
            your account secure.
          </p>
          <.button phx-click="generate_token" class="btn btn-primary">
            Generate token
          </.button>
        </div>

        <div class="overflow-x-auto">
          <table class="table">
            <thead>
              <tr>
                <th class="w-1/2">Token</th>
                <th>Created</th>
                <th class="text-right">Actions</th>
              </tr>
            </thead>
            <tbody>
              <tr :if={@tokens == []}>
                <td colspan="3" class="text-center text-sm text-base-content/70">
                  No tokens yet.
                </td>
              </tr>
              <tr :for={token <- @tokens} id={"token-#{token.id}"}>
                <td class="font-mono text-sm">
                  {token.token_prefix}…<span class="sr-only">hidden token</span>
                </td>
                <td class="text-sm">
                  {Calendar.strftime(token.inserted_at, "%Y-%m-%d %H:%M UTC")}
                </td>
                <td class="text-right">
                  <div class="flex justify-end gap-2">
                    <.button
                      phx-click="rotate_token"
                      phx-value-id={token.id}
                      class="btn btn-primary btn-sm"
                    >
                      Rotate
                    </.button>
                    <.button
                      phx-click="delete_token"
                      phx-value-id={token.id}
                      data-confirm="Are you sure you want to delete this token?"
                      class="btn btn-error btn-sm btn-soft"
                    >
                      Delete
                    </.button>
                  </div>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_scope.user
    password_changeset = Accounts.change_user_password(user, %{}, hash_password: false)

    socket =
      socket
      |> assign(:current_username, user.username)
      |> assign(:password_form, to_form(password_changeset))
      |> assign(:preferences_form, to_form(Accounts.change_user_preferences(user)))
      |> assign(:tokens, Accounts.list_user_access_tokens(user))
      |> assign(:last_token, nil)
      |> assign(:trigger_submit, false)

    {:ok, socket}
  end

  @impl true

  def handle_event("validate_password", params, socket) do
    %{"user" => user_params} = params

    password_form =
      socket.assigns.current_scope.user
      |> Accounts.change_user_password(user_params, hash_password: false)
      |> Map.put(:action, :validate)
      |> to_form()

    {:noreply, assign(socket, password_form: password_form)}
  end

  def handle_event("update_password", params, socket) do
    %{"user" => user_params} = params
    user = socket.assigns.current_scope.user
    true = Accounts.sudo_mode?(user)

    case Accounts.change_user_password(user, user_params) do
      %{valid?: true} = changeset ->
        {:noreply, assign(socket, trigger_submit: true, password_form: to_form(changeset))}

      changeset ->
        {:noreply, assign(socket, password_form: to_form(changeset, action: :insert))}
    end
  end

  def handle_event("validate_preferences", %{"user_preference" => pref_params}, socket) do
    preferences_form =
      socket.assigns.current_scope.user
      |> Accounts.change_user_preferences(pref_params)
      |> Map.put(:action, :validate)
      |> to_form()

    {:noreply, assign(socket, preferences_form: preferences_form)}
  end

  def handle_event("save_preferences", %{"user_preference" => pref_params}, socket) do
    user = socket.assigns.current_scope.user

    case Accounts.upsert_user_preferences(user, pref_params) do
      {:ok, preference} ->
        updated_user = %{user | preference: preference}
        updated_scope = %{socket.assigns.current_scope | user: updated_user}

        preferences_form =
          updated_user
          |> Accounts.change_user_preferences()
          |> to_form()

        {:noreply,
         socket
         |> assign(:current_scope, updated_scope)
         |> assign(:preferences_form, preferences_form)
         |> put_flash(:info, "Preferences updated successfully.")}

      {:error, changeset} ->
        {:noreply, assign(socket, preferences_form: to_form(changeset, action: :insert))}
    end
  end

  def handle_event("generate_token", _params, socket) do
    user = socket.assigns.current_scope.user

    case Accounts.create_user_access_token(user) do
      {:ok, {token, _record}} ->
        tokens = Accounts.list_user_access_tokens(user)

        {:noreply,
         socket
         |> assign(:tokens, tokens)
         |> assign(:last_token, %{value: token, action: :created})
         |> put_flash(:info, "API token generated.")}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Unable to generate a token. Please try again.")}
    end
  end

  def handle_event("rotate_token", %{"id" => token_id}, socket) do
    user = socket.assigns.current_scope.user

    case Accounts.rotate_user_access_token(user, token_id) do
      {:ok, {token, _record}} ->
        tokens = Accounts.list_user_access_tokens(user)

        {:noreply,
         socket
         |> assign(:tokens, tokens)
         |> assign(:last_token, %{value: token, action: :rotated})
         |> put_flash(:info, "Token rotated.")}

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "Token not found.")}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Unable to rotate the token. Please try again.")}
    end
  end

  def handle_event("delete_token", %{"id" => token_id}, socket) do
    user = socket.assigns.current_scope.user

    case Accounts.delete_user_access_token(user, token_id) do
      :ok ->
        tokens = Accounts.list_user_access_tokens(user)

        {:noreply,
         socket
         |> assign(:tokens, tokens)
         |> put_flash(:info, "Token deleted.")}

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "Token not found.")}
    end
  end
end
