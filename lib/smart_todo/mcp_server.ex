defmodule SmartTodo.MCPServer do
  @moduledoc """
  Model Context Protocol (MCP) server for SmartTodo application.
  Exposes task management state machine actions as MCP tools.
  """

  use Anubis.Server,
    name: "smart-todo-server",
    version: "1.0.0",
    capabilities: [:tools]

  alias SmartTodo.TaskStateMachine

  @impl true
  def init(_args) do
    {:ok, %{connected_users: %{}}}
  end

  @impl true
  def handle_initialize(req, state) do
    # Store client info and initialize user session if authentication provided
    client_info = %{
      protocol_version: req.protocol_version,
      client_info: req.client_info,
      connected_at: DateTime.utc_now()
    }

    # For demo purposes, we'll use a default user ID
    # In production, you'd extract this from authentication
    user_id = get_user_id_from_request(req)

    case start_user_session(user_id) do
      {:ok, _pid} ->
        new_state = put_in(state.connected_users[user_id], client_info)
        {:ok, new_state}

      {:error, reason} ->
        {:error, "Failed to start user session: #{reason}"}
    end
  end

  @impl true
  def handle_tool_call(tool_name, params, state) do
    # Extract user_id from params or use default
    user_id = get_current_user_id(params)

    case tool_name do
      "get_available_actions" ->
        actions = TaskStateMachine.get_available_actions(user_id)
        {:ok, %{actions: actions}, state}

      "get_current_state" ->
        current_state = TaskStateMachine.get_current_state(user_id)
        {:ok, %{state: current_state}, state}

      "transition_to" ->
        new_state = Map.get(params, "state")
        transition_params = Map.get(params, "params", %{})

        case TaskStateMachine.transition_to(user_id, String.to_atom(new_state), transition_params) do
          {:ok, result} ->
            {:ok, %{success: true, new_state: result}, state}
          {:error, reason} ->
            {:ok, %{success: false, error: reason}, state}
        end

      "execute_action" ->
        action = Map.get(params, "action")
        action_params = Map.get(params, "params", %{})

        case TaskStateMachine.execute_action(user_id, action, action_params) do
          {:ok, result} ->
            {:ok, %{success: true, result: result}, state}
          {:error, reason} ->
            {:ok, %{success: false, error: reason}, state}
        end

      # Task management actions
      "create_task" ->
        execute_task_action(user_id, "create_task", params, state)

      "list_tasks" ->
        execute_task_action(user_id, "list_tasks", params, state)

      "search_tasks" ->
        execute_task_action(user_id, "search_tasks", params, state)

      "view_task" ->
        execute_task_action(user_id, "view_task", params, state)

      "get_task_stats" ->
        execute_task_action(user_id, "get_task_stats", params, state)

      "set_title" ->
        execute_task_action(user_id, "set_title", params, state)

      "set_description" ->
        execute_task_action(user_id, "set_description", params, state)

      "set_urgency" ->
        execute_task_action(user_id, "set_urgency", params, state)

      "save_task" ->
        execute_task_action(user_id, "save_task", params, state)

      "cancel" ->
        execute_task_action(user_id, "cancel", params, state)

      "update_title" ->
        execute_task_action(user_id, "update_title", params, state)

      "update_status" ->
        execute_task_action(user_id, "update_status", params, state)

      "save_changes" ->
        execute_task_action(user_id, "save_changes", params, state)

      "cancel_edit" ->
        execute_task_action(user_id, "cancel_edit", params, state)

      _ ->
        {:error, "Unknown tool: #{tool_name}"}
    end
  end

  @impl true
  def handle_notification("disconnect", _params, state) do
    # Clean up user sessions
    Enum.each(state.connected_users, fn {user_id, _info} ->
      TaskStateMachine.stop(user_id)
    end)

    {:ok, %{connected_users: %{}}}
  end

  def handle_notification(_notification, _params, state) do
    {:ok, state}
  end

  # Tool definitions
  def tools do
    [
      %{
        name: "get_available_actions",
        description: "Get available actions for current state",
        input_schema: %{
          type: "object",
          properties: %{
            user_id: %{type: "integer", description: "User ID (optional)"}
          }
        }
      },
      %{
        name: "get_current_state",
        description: "Get current state machine state",
        input_schema: %{
          type: "object",
          properties: %{
            user_id: %{type: "integer", description: "User ID (optional)"}
          }
        }
      },
      %{
        name: "transition_to",
        description: "Transition to a new state",
        input_schema: %{
          type: "object",
          properties: %{
            state: %{type: "string", description: "Target state name"},
            params: %{type: "object", description: "Transition parameters"},
            user_id: %{type: "integer", description: "User ID (optional)"}
          },
          required: ["state"]
        }
      },
      %{
        name: "execute_action",
        description: "Execute an action in current state",
        input_schema: %{
          type: "object",
          properties: %{
            action: %{type: "string", description: "Action name"},
            params: %{type: "object", description: "Action parameters"},
            user_id: %{type: "integer", description: "User ID (optional)"}
          },
          required: ["action"]
        }
      },
      %{
        name: "create_task",
        description: "Start creating a new task",
        input_schema: %{
          type: "object",
          properties: %{
            title: %{type: "string", description: "Task title"},
            description: %{type: "string", description: "Task description"},
            urgency: %{type: "integer", minimum: 1, maximum: 5, description: "Task urgency"},
            user_id: %{type: "integer", description: "User ID (optional)"}
          }
        }
      },
      %{
        name: "list_tasks",
        description: "List all tasks",
        input_schema: %{
          type: "object",
          properties: %{
            user_id: %{type: "integer", description: "User ID (optional)"}
          }
        }
      },
      %{
        name: "search_tasks",
        description: "Search tasks by title or description",
        input_schema: %{
          type: "object",
          properties: %{
            query: %{type: "string", description: "Search query"},
            user_id: %{type: "integer", description: "User ID (optional)"}
          },
          required: ["query"]
        }
      },
      %{
        name: "view_task",
        description: "View and edit a specific task",
        input_schema: %{
          type: "object",
          properties: %{
            task_id: %{type: "integer", description: "Task ID"},
            user_id: %{type: "integer", description: "User ID (optional)"}
          },
          required: ["task_id"]
        }
      },
      %{
        name: "get_task_stats",
        description: "Get task statistics",
        input_schema: %{
          type: "object",
          properties: %{
            user_id: %{type: "integer", description: "User ID (optional)"}
          }
        }
      },
      %{
        name: "set_title",
        description: "Set title while creating task",
        input_schema: %{
          type: "object",
          properties: %{
            title: %{type: "string", description: "Task title"},
            user_id: %{type: "integer", description: "User ID (optional)"}
          },
          required: ["title"]
        }
      },
      %{
        name: "set_description",
        description: "Set description while creating task",
        input_schema: %{
          type: "object",
          properties: %{
            description: %{type: "string", description: "Task description"},
            user_id: %{type: "integer", description: "User ID (optional)"}
          },
          required: ["description"]
        }
      },
      %{
        name: "set_urgency",
        description: "Set urgency while creating task",
        input_schema: %{
          type: "object",
          properties: %{
            urgency: %{type: "integer", minimum: 1, maximum: 5, description: "Task urgency"},
            user_id: %{type: "integer", description: "User ID (optional)"}
          },
          required: ["urgency"]
        }
      },
      %{
        name: "save_task",
        description: "Save the task being created",
        input_schema: %{
          type: "object",
          properties: %{
            user_id: %{type: "integer", description: "User ID (optional)"}
          }
        }
      },
      %{
        name: "cancel",
        description: "Cancel current operation",
        input_schema: %{
          type: "object",
          properties: %{
            user_id: %{type: "integer", description: "User ID (optional)"}
          }
        }
      },
      %{
        name: "update_title",
        description: "Update task title while editing",
        input_schema: %{
          type: "object",
          properties: %{
            title: %{type: "string", description: "New task title"},
            user_id: %{type: "integer", description: "User ID (optional)"}
          },
          required: ["title"]
        }
      },
      %{
        name: "update_status",
        description: "Update task status while editing",
        input_schema: %{
          type: "object",
          properties: %{
            status: %{
              type: "string",
              enum: ["pending", "in_progress", "completed"],
              description: "New task status"
            },
            user_id: %{type: "integer", description: "User ID (optional)"}
          },
          required: ["status"]
        }
      },
      %{
        name: "save_changes",
        description: "Save changes to task",
        input_schema: %{
          type: "object",
          properties: %{
            user_id: %{type: "integer", description: "User ID (optional)"}
          }
        }
      },
      %{
        name: "cancel_edit",
        description: "Cancel editing task",
        input_schema: %{
          type: "object",
          properties: %{
            user_id: %{type: "integer", description: "User ID (optional)"}
          }
        }
      }
    ]
  end

  # Private helper functions
  defp start_user_session(user_id) do
    spec = {TaskStateMachine, user_id}
    DynamicSupervisor.start_child(SmartTodo.TaskStateMachineSupervisor, spec)
  end

  defp get_user_id_from_request(_req) do
    # For demo purposes, use a default user ID
    # In production, extract from authentication headers or client info
    1
  end

  defp get_current_user_id(params) do
    Map.get(params, "user_id", 1)
  end

  defp execute_task_action(user_id, action, params, state) do
    case TaskStateMachine.execute_action(user_id, action, params) do
      {:ok, result} ->
        current_state = TaskStateMachine.get_current_state(user_id)
        available_actions = TaskStateMachine.get_available_actions(user_id)

        response = %{
          success: true,
          result: result,
          current_state: current_state,
          available_actions: available_actions
        }
        {:ok, response, state}

      {:error, reason} ->
        current_state = TaskStateMachine.get_current_state(user_id)
        available_actions = TaskStateMachine.get_available_actions(user_id)

        response = %{
          success: false,
          error: reason,
          current_state: current_state,
          available_actions: available_actions
        }
        {:ok, response, state}
    end
  end
end