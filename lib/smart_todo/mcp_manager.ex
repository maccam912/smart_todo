defmodule SmartTodo.MCPManager do
  @moduledoc """
  Manager for the MCP server lifecycle and client connections.
  Handles starting/stopping the MCP server and managing user sessions.
  """

  use GenServer
  require Logger

  alias SmartTodo.{MCPServer, TaskStateMachine}

  # Client API
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def start_mcp_server(transport \\ :stdio) do
    GenServer.call(__MODULE__, {:start_mcp_server, transport})
  end

  def stop_mcp_server do
    GenServer.call(__MODULE__, :stop_mcp_server)
  end

  def get_server_status do
    GenServer.call(__MODULE__, :get_server_status)
  end

  def connect_user(user_id) do
    GenServer.call(__MODULE__, {:connect_user, user_id})
  end

  def disconnect_user(user_id) do
    GenServer.call(__MODULE__, {:disconnect_user, user_id})
  end

  def list_connected_users do
    GenServer.call(__MODULE__, :list_connected_users)
  end

  # GenServer callbacks
  @impl true
  def init(opts) do
    auto_start = Keyword.get(opts, :auto_start, false)

    state = %{
      mcp_server_pid: nil,
      connected_users: %{},
      transport: :stdio,
      auto_start: auto_start
    }

    if auto_start do
      {:ok, state, {:continue, :start_mcp_server}}
    else
      {:ok, state}
    end
  end

  @impl true
  def handle_continue(:start_mcp_server, state) do
    case start_mcp_server_internal(state.transport) do
      {:ok, pid} ->
        Logger.info("MCP Server started automatically with PID: #{inspect(pid)}")
        {:noreply, %{state | mcp_server_pid: pid}}

      {:error, reason} ->
        Logger.error("Failed to auto-start MCP Server: #{inspect(reason)}")
        {:noreply, state}
    end
  end

  @impl true
  def handle_call({:start_mcp_server, transport}, _from, state) do
    case state.mcp_server_pid do
      nil ->
        case start_mcp_server_internal(transport) do
          {:ok, pid} ->
            new_state = %{state | mcp_server_pid: pid, transport: transport}
            {:reply, {:ok, pid}, new_state}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end

      pid ->
        {:reply, {:error, "MCP Server already running with PID: #{inspect(pid)}"}, state}
    end
  end

  def handle_call(:stop_mcp_server, _from, state) do
    case state.mcp_server_pid do
      nil ->
        {:reply, {:error, "MCP Server not running"}, state}

      pid ->
        # Stop all connected user sessions
        Enum.each(state.connected_users, fn {user_id, _info} ->
          TaskStateMachine.stop(user_id)
        end)

        # Stop the MCP server
        if Process.alive?(pid) do
          Process.exit(pid, :normal)
        end

        new_state = %{state | mcp_server_pid: nil, connected_users: %{}}
        {:reply, :ok, new_state}
    end
  end

  def handle_call(:get_server_status, _from, state) do
    status = %{
      running: state.mcp_server_pid != nil,
      pid: state.mcp_server_pid,
      transport: state.transport,
      connected_users: Map.keys(state.connected_users),
      user_count: map_size(state.connected_users)
    }
    {:reply, status, state}
  end

  def handle_call({:connect_user, user_id}, _from, state) do
    case Map.get(state.connected_users, user_id) do
      nil ->
        # Start user's state machine
        case start_user_state_machine(user_id) do
          {:ok, sm_pid} ->
            user_info = %{
              state_machine_pid: sm_pid,
              connected_at: DateTime.utc_now(),
              last_activity: DateTime.utc_now()
            }

            new_state = put_in(state.connected_users[user_id], user_info)
            Logger.info("User #{user_id} connected with state machine PID: #{inspect(sm_pid)}")
            {:reply, {:ok, sm_pid}, new_state}

          {:error, reason} ->
            Logger.error("Failed to start state machine for user #{user_id}: #{inspect(reason)}")
            {:reply, {:error, reason}, state}
        end

      _existing ->
        {:reply, {:error, "User #{user_id} already connected"}, state}
    end
  end

  def handle_call({:disconnect_user, user_id}, _from, state) do
    case Map.get(state.connected_users, user_id) do
      nil ->
        {:reply, {:error, "User #{user_id} not connected"}, state}

      _user_info ->
        # Stop user's state machine
        TaskStateMachine.stop(user_id)

        new_state = %{state | connected_users: Map.delete(state.connected_users, user_id)}
        Logger.info("User #{user_id} disconnected")
        {:reply, :ok, new_state}
    end
  end

  def handle_call(:list_connected_users, _from, state) do
    users = Enum.map(state.connected_users, fn {user_id, info} ->
      %{
        user_id: user_id,
        connected_at: info.connected_at,
        last_activity: info.last_activity,
        state_machine_alive: Process.alive?(info.state_machine_pid)
      }
    end)
    {:reply, users, state}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, reason}, state) do
    cond do
      pid == state.mcp_server_pid ->
        Logger.warning("MCP Server process died: #{inspect(reason)}")
        new_state = %{state | mcp_server_pid: nil, connected_users: %{}}
        {:noreply, new_state}

      true ->
        # Check if it's a user state machine that died
        case find_user_by_sm_pid(state.connected_users, pid) do
          nil ->
            {:noreply, state}

          user_id ->
            Logger.warning("State machine for user #{user_id} died: #{inspect(reason)}")
            new_state = %{state | connected_users: Map.delete(state.connected_users, user_id)}
            {:noreply, new_state}
        end
    end
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # Private functions
  defp start_mcp_server_internal(transport) do
    opts = case transport do
      :http ->
        [
          transport: :http,
          port: 8080,
          path: "/mcp"
        ]
      _ ->
        [transport: transport]
    end

    case Anubis.Server.start_link(MCPServer, [], opts) do
      {:ok, pid} ->
        # Monitor the MCP server process
        Process.monitor(pid)
        Logger.info("MCP Server started with transport: #{transport}, PID: #{inspect(pid)}")
        {:ok, pid}

      {:error, reason} ->
        Logger.error("Failed to start MCP Server: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp start_user_state_machine(user_id) do
    spec = {TaskStateMachine, user_id}

    case DynamicSupervisor.start_child(SmartTodo.TaskStateMachineSupervisor, spec) do
      {:ok, pid} ->
        # Monitor the state machine process
        Process.monitor(pid)
        {:ok, pid}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp find_user_by_sm_pid(connected_users, sm_pid) do
    connected_users
    |> Enum.find(fn {_user_id, info} -> info.state_machine_pid == sm_pid end)
    |> case do
      nil -> nil
      {user_id, _info} -> user_id
    end
  end
end