defmodule SmartTodoWeb.ApiSpec do
  @moduledoc """
  OpenAPI specification for the SmartTodo REST API.
  """

  alias OpenApiSpex.{Info, OpenApi, Paths, Server, Components, SecurityScheme}
  alias SmartTodoWeb.{Endpoint, Router}
  @behaviour OpenApi

  @impl OpenApi
  def spec do
    %OpenApi{
      info: %Info{
        title: "SmartTodo API",
        version: "1.0.0",
        description: """
        REST API for managing tasks in SmartTodo.

        ## Authentication

        All API endpoints require authentication using a Bearer token.
        You can generate an API token from the user settings page in the web interface.

        Include the token in the `Authorization` header:
        ```
        Authorization: Bearer <your-token>
        ```
        """
      },
      servers: [
        Server.from_endpoint(Endpoint)
      ],
      paths: Paths.from_router(Router),
      components: %Components{
        securitySchemes: %{
          "bearerAuth" => %SecurityScheme{
            type: "http",
            scheme: "bearer",
            bearerFormat: "API Token",
            description: "API access token from user settings"
          }
        }
      },
      security: [
        %{"bearerAuth" => []}
      ]
    }
    |> OpenApiSpex.resolve_schema_modules()
  end
end
