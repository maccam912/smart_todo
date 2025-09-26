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
end
