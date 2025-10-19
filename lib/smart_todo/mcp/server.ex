defmodule SmartTodo.MCP.Server do
  @moduledoc """
  MCP Server for SmartTodo task management.

  Provides tools for AI assistants to manage tasks through the Model Context Protocol.
  """

  use Anubis.Server,
    name: "smart-todo",
    version: "1.0.0",
    capabilities: [:tools]

  # Register all tool components
  component SmartTodo.MCP.Tools.ListTasks
  component SmartTodo.MCP.Tools.GetTask
  component SmartTodo.MCP.Tools.CreateTask
  component SmartTodo.MCP.Tools.UpdateTask
  component SmartTodo.MCP.Tools.CompleteTask
  component SmartTodo.MCP.Tools.DeleteTask
end
