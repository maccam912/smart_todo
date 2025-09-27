# SmartTodo

A Phoenix LiveView task management application with Model Context Protocol (MCP) integration.

## URLs

* **Web Application**: [`localhost:4000`](http://localhost:4000) - Phoenix LiveView interface
* **Streamable URL**: `http://localhost:4000` - Direct access for web browsers and tools
* **MCP Server Endpoint**: `http://localhost:8080/mcp` - Model Context Protocol HTTP endpoint

## Getting Started

To start your Phoenix server:

* Run `mix setup` to install and setup dependencies
* Start Phoenix endpoint with `mix phx.server` or inside IEx with `iex -S mix phx.server`

Now you can visit [`localhost:4000`](http://localhost:4000) from your browser.

## MCP Server Integration

This application includes a Model Context Protocol (MCP) server that exposes task management functionality as MCP tools. The MCP server provides:

* Task creation and management through state machine workflows
* Connection/disconnection lifecycle management
* 20+ MCP tools for task operations (create, list, search, update, etc.)

### MCP CLI Commands

Test the MCP functionality using the built-in CLI:

```bash
# Start MCP server (default: stdio, use "http" for HTTP endpoint)
mix run -e "SmartTodo.MCPCLI.main([\"start\"])"
mix run -e "SmartTodo.MCPCLI.main([\"start\", \"http\"])"  # HTTP on localhost:8080/mcp

# Connect a user session
mix run -e "SmartTodo.MCPCLI.main([\"connect\", \"1\"])"

# Execute task actions
mix run -e "SmartTodo.MCPCLI.main([\"exec\", \"list_tasks\"])"
mix run -e "SmartTodo.MCPCLI.main([\"exec\", \"create_task\", \"title=My Task\"])"

# View available actions and current state
mix run -e "SmartTodo.MCPCLI.main([\"actions\"])"
mix run -e "SmartTodo.MCPCLI.main([\"state\"])"
```

Ready to run in production? Please [check our deployment guides](https://hexdocs.pm/phoenix/deployment.html).

## Learn more

* Official website: https://www.phoenixframework.org/
* Guides: https://hexdocs.pm/phoenix/overview.html
* Docs: https://hexdocs.pm/phoenix
* Forum: https://elixirforum.com/c/phoenix-forum
* Source: https://github.com/phoenixframework/phoenix
