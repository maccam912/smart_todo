defmodule SmartTodoWeb.GroupLive.Index do
  use SmartTodoWeb, :live_view

  alias SmartTodo.Accounts
  alias SmartTodo.Accounts.Group

  @impl true
  def mount(_params, _session, socket) do
    current_scope = socket.assigns.current_scope
    groups = Accounts.list_groups()
    user_groups = groups |> Enum.filter(&(&1.created_by_user_id == current_scope.user.id))
    member_groups = get_member_groups(current_scope.user.id, groups)

    form =
      %Group{}
      |> Accounts.change_group()
      |> to_form()

    socket =
      socket
      |> assign(:page_title, "Groups")
      |> assign(:groups, groups)
      |> assign(:user_groups, user_groups)
      |> assign(:member_groups, member_groups)
      |> assign(:form, form)
      |> assign(:show_create_form?, false)
      |> assign(:selected_group, nil)
      |> assign(:add_member_username, "")
      |> assign(:add_group_name, "")

    {:ok, socket}
  end

  @impl true
  def handle_event("toggle_create_form", _params, socket) do
    {:noreply, update(socket, :show_create_form?, &(!&1))}
  end

  @impl true
  def handle_event("validate_group", %{"group" => params}, socket) do
    form =
      %Group{}
      |> Accounts.change_group(params)
      |> Map.put(:action, :validate)
      |> to_form()

    {:noreply, assign(socket, form: form)}
  end

  @impl true
  def handle_event("create_group", %{"group" => params}, socket) do
    case Accounts.create_group(socket.assigns.current_scope.user, params) do
      {:ok, _group} ->
        groups = Accounts.list_groups()
        user_groups = groups |> Enum.filter(&(&1.created_by_user_id == socket.assigns.current_scope.user.id))

        {:noreply,
         socket
         |> put_flash(:info, "Group created successfully")
         |> assign(:groups, groups)
         |> assign(:user_groups, user_groups)
         |> assign(:form, %Group{} |> Accounts.change_group() |> to_form())
         |> assign(:show_create_form?, false)}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end

  @impl true
  def handle_event("select_group", %{"group-id" => group_id}, socket) do
    group_id = String.to_integer(group_id)
    group = Accounts.get_group!(group_id)

    {:noreply, assign(socket, selected_group: group)}
  end

  @impl true
  def handle_event("close_group_details", _params, socket) do
    {:noreply, assign(socket, selected_group: nil)}
  end

  @impl true
  def handle_event("add_user_to_group", %{"username" => username}, socket) do
    case socket.assigns.selected_group do
      nil ->
        {:noreply, put_flash(socket, :error, "No group selected")}

      group ->
        case Accounts.get_user_by_username(username) do
          nil ->
            {:noreply, put_flash(socket, :error, "User '#{username}' not found")}

          user ->
            case Accounts.add_user_to_group(group, user) do
              {:ok, _membership} ->
                updated_group = Accounts.get_group!(group.id)
                groups = Accounts.list_groups()

                {:noreply,
                 socket
                 |> put_flash(:info, "User '#{username}' added to group")
                 |> assign(:selected_group, updated_group)
                 |> assign(:groups, groups)
                 |> assign(:add_member_username, "")}

              {:error, _changeset} ->
                {:noreply, put_flash(socket, :error, "Could not add user to group")}
            end
        end
    end
  end

  @impl true
  def handle_event("add_group_to_group", %{"group_name" => group_name}, socket) do
    case socket.assigns.selected_group do
      nil ->
        {:noreply, put_flash(socket, :error, "No group selected")}

      parent_group ->
        case Accounts.get_group_by_name(group_name) do
          nil ->
            {:noreply, put_flash(socket, :error, "Group '#{group_name}' not found")}

          member_group ->
            case Accounts.add_group_to_group(parent_group, member_group) do
              {:ok, _membership} ->
                updated_group = Accounts.get_group!(parent_group.id)
                groups = Accounts.list_groups()

                {:noreply,
                 socket
                 |> put_flash(:info, "Group '#{group_name}' added to group")
                 |> assign(:selected_group, updated_group)
                 |> assign(:groups, groups)
                 |> assign(:add_group_name, "")}

              {:error, reason} when is_binary(reason) ->
                {:noreply, put_flash(socket, :error, reason)}

              {:error, _changeset} ->
                {:noreply, put_flash(socket, :error, "Could not add group to group")}
            end
        end
    end
  end

  @impl true
  def handle_event("remove_user_from_group", %{"user-id" => user_id}, socket) do
    case socket.assigns.selected_group do
      nil ->
        {:noreply, put_flash(socket, :error, "No group selected")}

      group ->
        user_id = String.to_integer(user_id)
        user = Accounts.get_user!(user_id)

        :ok = Accounts.remove_user_from_group(group, user)
        updated_group = Accounts.get_group!(group.id)
        groups = Accounts.list_groups()

        {:noreply,
         socket
         |> put_flash(:info, "User removed from group")
         |> assign(:selected_group, updated_group)
         |> assign(:groups, groups)}
    end
  end

  @impl true
  def handle_event("remove_group_from_group", %{"member-group-id" => member_group_id}, socket) do
    case socket.assigns.selected_group do
      nil ->
        {:noreply, put_flash(socket, :error, "No group selected")}

      parent_group ->
        member_group_id = String.to_integer(member_group_id)
        member_group = Accounts.get_group!(member_group_id)

        :ok = Accounts.remove_group_from_group(parent_group, member_group)
        updated_group = Accounts.get_group!(parent_group.id)
        groups = Accounts.list_groups()

        {:noreply,
         socket
         |> put_flash(:info, "Group removed from group")
         |> assign(:selected_group, updated_group)
         |> assign(:groups, groups)}
    end
  end

  @impl true
  def handle_event("delete_group", %{"group-id" => group_id}, socket) do
    group_id = String.to_integer(group_id)
    group = Accounts.get_group!(group_id)

    if group.created_by_user_id == socket.assigns.current_scope.user.id do
      case Accounts.delete_group(group) do
        {:ok, _group} ->
          groups = Accounts.list_groups()
          user_groups = groups |> Enum.filter(&(&1.created_by_user_id == socket.assigns.current_scope.user.id))

          {:noreply,
           socket
           |> put_flash(:info, "Group deleted successfully")
           |> assign(:groups, groups)
           |> assign(:user_groups, user_groups)
           |> assign(:selected_group, nil)}

        {:error, _changeset} ->
          {:noreply, put_flash(socket, :error, "Could not delete group")}
      end
    else
      {:noreply, put_flash(socket, :error, "You can only delete groups you created")}
    end
  end

  @impl true
  def handle_event("do_nothing", _params, socket) do
    {:noreply, socket}
  end

  defp get_member_groups(user_id, groups) do
    groups
    |> Enum.filter(fn group ->
      Enum.any?(group.user_members, &(&1.id == user_id))
    end)
    |> Enum.reject(&(&1.created_by_user_id == user_id))
  end

  @impl true
  def render(assigns) do
    ~H"""
    <SmartTodoWeb.Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="flex items-center justify-between">
        <h1 class="text-2xl font-semibold">Groups</h1>
        <button class="btn btn-primary" phx-click="toggle_create_form">
          <.icon name="hero-plus" class="w-5 h-5 mr-1" /> Create Group
        </button>
      </div>

      <!-- Create Group Form -->
      <div :if={@show_create_form?} class="card bg-base-200 border border-base-300 mt-6">
        <div class="card-body">
          <h2 class="card-title">Create New Group</h2>
          <.form for={@form} id="create-group-form" phx-change="validate_group" phx-submit="create_group">
            <div class="grid grid-cols-1 gap-4">
              <.input field={@form[:name]} label="Group Name" placeholder="e.g. Development Team" required />
              <.input
                field={@form[:description]}
                type="textarea"
                label="Description (optional)"
                placeholder="Describe the purpose of this group"
                class="textarea textarea-bordered"
              />
            </div>
            <div class="mt-4 flex justify-end gap-2">
              <button type="button" class="btn btn-ghost" phx-click="toggle_create_form">
                Cancel
              </button>
              <button class="btn btn-primary" type="submit">
                <.icon name="hero-plus" class="w-5 h-5 mr-1" /> Create Group
              </button>
            </div>
          </.form>
        </div>
      </div>

      <!-- Groups Overview -->
      <div class="mt-8 space-y-8">
        <!-- My Groups -->
        <section>
          <h2 class="text-xl font-semibold mb-4">My Groups</h2>
          <p :if={Enum.empty?(@user_groups)} class="text-sm text-base-content/70">
            You haven't created any groups yet. Create your first group above to get started!
          </p>
          <div :if={!Enum.empty?(@user_groups)} class="grid grid-cols-1 md:grid-cols-2 gap-4">
            <.group_card
              :for={group <- @user_groups}
              group={group}
              is_owner={true}
              current_user_id={@current_scope.user.id}
            />
          </div>
        </section>

        <!-- Groups I'm a Member Of -->
        <section>
          <h2 class="text-xl font-semibold mb-4">Groups I'm a Member Of</h2>
          <p :if={Enum.empty?(@member_groups)} class="text-sm text-base-content/70">
            You're not a member of any groups yet. Ask someone to add you to their group!
          </p>
          <div :if={!Enum.empty?(@member_groups)} class="grid grid-cols-1 md:grid-cols-2 gap-4">
            <.group_card
              :for={group <- @member_groups}
              group={group}
              is_owner={false}
              current_user_id={@current_scope.user.id}
            />
          </div>
        </section>
      </div>

      <!-- Group Details Modal -->
      <div
        :if={@selected_group}
        class="fixed inset-0 bg-black bg-opacity-50 flex items-center justify-center z-50"
        phx-click="close_group_details"
      >
        <div class="bg-base-100 rounded-lg shadow-xl max-w-2xl w-full mx-4 max-h-[90vh] overflow-y-auto" phx-click="do_nothing">
          <!-- Modal content - prevent click propagation -->
          <div class="p-6">
            <div class="flex items-center justify-between mb-6">
              <div>
                <h3 class="text-xl font-semibold">{@selected_group.name}</h3>
                <p :if={@selected_group.description} class="text-sm text-base-content/70 mt-1">
                  {@selected_group.description}
                </p>
                <p class="text-xs text-base-content/50 mt-2">
                  Created by {@selected_group.created_by_user.username}
                </p>
              </div>
              <button class="btn btn-ghost btn-sm" phx-click="close_group_details">
                <.icon name="hero-x-mark" class="w-5 h-5" />
              </button>
            </div>

            <!-- Add Members Section (only for group owners) -->
            <div :if={@selected_group.created_by_user_id == @current_scope.user.id} class="mb-6 space-y-4">
              <h4 class="font-medium">Add Members</h4>

              <!-- Add User -->
              <!-- Add User Form -->
              <form phx-submit="add_user_to_group">
                <div class="flex gap-2">
                  <input
                    type="text"
                    name="username"
                    placeholder="Username"
                    class="input input-bordered flex-1"
                    value={@add_member_username}
                  />
                  <button type="submit" class="btn btn-primary">
                    Add User
                  </button>
                </div>
              </form>

              <!-- Add Group Form -->
              <form phx-submit="add_group_to_group">
                <div class="flex gap-2">
                  <input
                    type="text"
                    name="group_name"
                    placeholder="Group name"
                    class="input input-bordered flex-1"
                    value={@add_group_name}
                  />
                  <button type="submit" class="btn btn-secondary">
                    Add Group
                  </button>
                </div>
              </form>
            </div>

            <!-- Members List -->
            <div class="space-y-4">
              <!-- User Members -->
              <div :if={!Enum.empty?(@selected_group.user_members)}>
                <h4 class="font-medium mb-2">User Members ({length(@selected_group.user_members)})</h4>
                <div class="space-y-2">
                  <div
                    :for={user <- @selected_group.user_members}
                    class="flex items-center justify-between p-3 bg-base-200 rounded"
                  >
                    <div>
                      <span class="font-medium">{user.username}</span>
                    </div>
                    <button
                      :if={@selected_group.created_by_user_id == @current_scope.user.id}
                      class="btn btn-ghost btn-xs text-error"
                      phx-click="remove_user_from_group"
                      phx-value-user-id={user.id}
                      data-confirm="Remove this user from the group?"
                    >
                      Remove
                    </button>
                  </div>
                </div>
              </div>

              <!-- Group Members -->
              <div :if={!Enum.empty?(@selected_group.group_members)}>
                <h4 class="font-medium mb-2">Group Members ({length(@selected_group.group_members)})</h4>
                <div class="space-y-2">
                  <div
                    :for={group <- @selected_group.group_members}
                    class="flex items-center justify-between p-3 bg-base-200 rounded"
                  >
                    <div>
                      <span class="font-medium">{group.name}</span>
                      <p :if={group.description} class="text-sm text-base-content/70">{group.description}</p>
                    </div>
                    <button
                      :if={@selected_group.created_by_user_id == @current_scope.user.id}
                      class="btn btn-ghost btn-xs text-error"
                      phx-click="remove_group_from_group"
                      phx-value-member-group-id={group.id}
                      data-confirm="Remove this group from the group?"
                    >
                      Remove
                    </button>
                  </div>
                </div>
              </div>

              <p :if={Enum.empty?(@selected_group.user_members) and Enum.empty?(@selected_group.group_members)} class="text-sm text-base-content/70">
                This group has no members yet.
              </p>
            </div>
          </div>
        </div>
      </div>
    </SmartTodoWeb.Layouts.app>
    """
  end

  attr :group, SmartTodo.Accounts.Group, required: true
  attr :is_owner, :boolean, required: true
  attr :current_user_id, :integer, required: true

  defp group_card(assigns) do
    ~H"""
    <div class="card bg-base-200 border border-base-300 hover:border-primary/60 transition-colors cursor-pointer"
         phx-click="select_group"
         phx-value-group-id={@group.id}>
      <div class="card-body">
        <div class="flex items-start justify-between">
          <div class="flex-1">
            <h3 class="card-title text-base">{@group.name}</h3>
            <p :if={@group.description} class="text-sm text-base-content/70 mt-1 line-clamp-2">
              {@group.description}
            </p>
            <div class="mt-3 flex items-center gap-4 text-xs text-base-content/60">
              <span class="flex items-center gap-1">
                <.icon name="hero-users" class="w-4 h-4" />
                {length(@group.user_members)} users
              </span>
              <span class="flex items-center gap-1">
                <.icon name="hero-user-group" class="w-4 h-4" />
                {length(@group.group_members)} groups
              </span>
            </div>
          </div>
          <div class="flex items-center gap-2">
            <span :if={@is_owner} class="badge badge-primary badge-sm">Owner</span>
            <button
              :if={@is_owner}
              class="btn btn-ghost btn-xs text-error"
              phx-click="delete_group"
              phx-value-group-id={@group.id}
              data-confirm="Delete this group? This action cannot be undone."
              onclick="event.stopPropagation()"
            >
              <.icon name="hero-trash" class="w-4 h-4" />
            </button>
          </div>
        </div>
      </div>
    </div>
    """
  end
end