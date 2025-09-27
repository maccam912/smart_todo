defmodule SmartTodo.MCPCLI do
  @moduledoc """
  Command-line interface for managing the MCP server and testing state machine actions.
  """

  alias SmartTodo.{MCPManager, TaskStateMachine}

  def commands do
    %{
      "start" => &start_server/1,
      "stop" => &stop_server/1,
      "status" => &show_status/1,
      "connect" => &connect_user/1,
      "disconnect" => &disconnect_user/1,
      "users" => &list_users/1,
      "actions" => &show_actions/1,
      "state" => &show_state/1,
      "exec" => &execute_action/1,
      "help" => &show_help/1
    }
  end

  def main(args \\ []) do
    case args do
      [] ->
        show_help([])

      [command | rest] ->
        case Map.get(commands(), command) do
          nil ->
            IO.puts("Unknown command: #{command}")
            show_help([])

          fun ->
            fun.(rest)
        end
    end
  end

  defp start_server(args) do
    transport = case args do
      ["stdio"] -> :stdio
      ["http"] -> :http
      [] -> :stdio
      [other] ->
        IO.puts("Unknown transport: #{other}. Using stdio.")
        :stdio
    end

    IO.puts("Starting MCP server with transport: #{transport}...")

    case MCPManager.start_mcp_server(transport) do
      {:ok, pid} ->
        IO.puts("✅ MCP Server started successfully!")
        IO.puts("   PID: #{inspect(pid)}")
        IO.puts("   Transport: #{transport}")

      {:error, reason} ->
        IO.puts("❌ Failed to start MCP server: #{inspect(reason)}")
    end
  end

  defp stop_server(_args) do
    IO.puts("Stopping MCP server...")

    case MCPManager.stop_mcp_server() do
      :ok ->
        IO.puts("✅ MCP Server stopped successfully!")

      {:error, reason} ->
        IO.puts("❌ Failed to stop MCP server: #{inspect(reason)}")
    end
  end

  defp show_status(_args) do
    status = MCPManager.get_server_status()

    IO.puts("📊 MCP Server Status:")
    IO.puts("   Running: #{status.running}")
    IO.puts("   PID: #{inspect(status.pid)}")
    IO.puts("   Transport: #{status.transport}")
    IO.puts("   Connected Users: #{status.user_count}")

    if status.user_count > 0 do
      IO.puts("   User IDs: #{inspect(status.connected_users)}")
    end
  end

  defp connect_user(args) do
    user_id = case args do
      [id_str] ->
        case Integer.parse(id_str) do
          {id, ""} -> id
          _ ->
            IO.puts("❌ Invalid user ID: #{id_str}")
            return_error()
        end

      [] ->
        1 # Default user

      _ ->
        IO.puts("❌ Usage: connect <user_id>")
        return_error()
    end

    IO.puts("Connecting user #{user_id}...")

    case MCPManager.connect_user(user_id) do
      {:ok, pid} ->
        IO.puts("✅ User #{user_id} connected successfully!")
        IO.puts("   State Machine PID: #{inspect(pid)}")

      {:error, reason} ->
        IO.puts("❌ Failed to connect user #{user_id}: #{inspect(reason)}")
    end
  end

  defp disconnect_user(args) do
    user_id = case args do
      [id_str] ->
        case Integer.parse(id_str) do
          {id, ""} -> id
          _ ->
            IO.puts("❌ Invalid user ID: #{id_str}")
            return_error()
        end

      [] ->
        1 # Default user

      _ ->
        IO.puts("❌ Usage: disconnect <user_id>")
        return_error()
    end

    IO.puts("Disconnecting user #{user_id}...")

    case MCPManager.disconnect_user(user_id) do
      :ok ->
        IO.puts("✅ User #{user_id} disconnected successfully!")

      {:error, reason} ->
        IO.puts("❌ Failed to disconnect user #{user_id}: #{inspect(reason)}")
    end
  end

  defp list_users(_args) do
    users = MCPManager.list_connected_users()

    IO.puts("👥 Connected Users (#{length(users)}):")

    if Enum.empty?(users) do
      IO.puts("   No users connected")
    else
      Enum.each(users, fn user ->
        status = if user.state_machine_alive, do: "🟢 Active", else: "🔴 Dead"
        IO.puts("   User #{user.user_id}: #{status}")
        IO.puts("     Connected: #{format_datetime(user.connected_at)}")
        IO.puts("     Last Activity: #{format_datetime(user.last_activity)}")
      end)
    end
  end

  defp show_actions(args) do
    user_id = parse_user_id(args, 1)

    IO.puts("🔧 Available Actions for User #{user_id}:")
    actions = TaskStateMachine.get_available_actions(user_id)

    if Enum.empty?(actions) do
      IO.puts("   No actions available (user may not be connected)")
    else
      Enum.with_index(actions, 1)
      |> Enum.each(fn {action, index} ->
        IO.puts("   #{index}. #{action.name}")
        IO.puts("      Description: #{action.description}")
        if length(action.params) > 0 do
          IO.puts("      Parameters: #{Enum.join(action.params, ", ")}")
        end
      end)
    end
  end

  defp show_state(args) do
    user_id = parse_user_id(args, 1)

    state = TaskStateMachine.get_current_state(user_id)
    IO.puts("📍 Current State for User #{user_id}: #{state}")
  end

  defp execute_action(args) do
    case args do
      [user_id_str, action | param_pairs] ->
        user_id = case Integer.parse(user_id_str) do
          {id, ""} -> id
          _ ->
            IO.puts("❌ Invalid user ID: #{user_id_str}")
            return_error()
        end

        params = parse_params(param_pairs)

        IO.puts("🚀 Executing action '#{action}' for user #{user_id}")
        IO.puts("   Parameters: #{inspect(params)}")

        case TaskStateMachine.execute_action(user_id, action, params) do
          {:ok, result} ->
            IO.puts("✅ Action executed successfully!")
            IO.puts("   Result: #{inspect(result, pretty: true)}")

            # Show new state and actions
            new_state = TaskStateMachine.get_current_state(user_id)
            IO.puts("   New State: #{new_state}")

          {:error, reason} ->
            IO.puts("❌ Action failed: #{inspect(reason)}")
        end

      [action | param_pairs] ->
        # Default to user 1
        execute_action(["1", action | param_pairs])

      [] ->
        IO.puts("❌ Usage: exec [user_id] <action> [key=value ...]")
        IO.puts("   Example: exec 1 create_task title=\"My Task\" urgency=3")
        IO.puts("   Example: exec list_tasks")
    end
  end

  defp show_help(_args) do
    IO.puts("""
    🤖 SmartTodo MCP CLI

    Commands:
      start [transport]     - Start MCP server (stdio|http, default: stdio)
      stop                  - Stop MCP server
      status                - Show server status
      connect [user_id]     - Connect user (default: 1)
      disconnect [user_id]  - Disconnect user (default: 1)
      users                 - List connected users
      actions [user_id]     - Show available actions (default: 1)
      state [user_id]       - Show current state (default: 1)
      exec [user_id] <action> [params] - Execute action
      help                  - Show this help

    Examples:
      mix run -e "SmartTodo.MCPCLI.main([\\"start\\"])"
      mix run -e "SmartTodo.MCPCLI.main([\\"connect\\", \\"1\\"])"
      mix run -e "SmartTodo.MCPCLI.main([\\"exec\\", \\"1\\", \\"list_tasks\\"])"
      mix run -e "SmartTodo.MCPCLI.main([\\"exec\\", \\"create_task\\", \\"title=Test Task\\"])"
    """)
  end

  # Helper functions
  defp parse_user_id([], default), do: default
  defp parse_user_id([id_str], _default) do
    case Integer.parse(id_str) do
      {id, ""} -> id
      _ ->
        IO.puts("❌ Invalid user ID: #{id_str}")
        1
    end
  end

  defp parse_params(param_pairs) do
    Enum.reduce(param_pairs, %{}, fn pair, acc ->
      case String.split(pair, "=", parts: 2) do
        [key, value] ->
          # Try to parse as integer, otherwise keep as string
          parsed_value = case Integer.parse(value) do
            {int, ""} -> int
            _ -> value
          end
          Map.put(acc, key, parsed_value)

        [key] ->
          Map.put(acc, key, true)

        _ ->
          acc
      end
    end)
  end

  defp format_datetime(dt) do
    DateTime.to_string(dt)
  end

  defp return_error, do: :error
end