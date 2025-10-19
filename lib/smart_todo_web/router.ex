defmodule SmartTodoWeb.Router do
  use SmartTodoWeb, :router

  import SmartTodoWeb.UserAuth

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {SmartTodoWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug :fetch_current_scope_for_user
  end

  pipeline :api do
    plug :accepts, ["json"]
    plug OpenApiSpex.Plug.PutApiSpec, module: SmartTodoWeb.ApiSpec
  end

  pipeline :api_auth do
    plug SmartTodoWeb.ApiAuth
  end

  pipeline :mcp do
    plug :accepts, ["json"]
    plug SmartTodoWeb.Plugs.MCPTokenAuth
  end

  # Health check endpoint - no database access
  scope "/health" do
    get "/", SmartTodoWeb.HealthController, :check
  end

  scope "/", SmartTodoWeb do
    pipe_through :browser
    # Root redirects based on authentication state
    get "/", RootRedirectController, :index
  end

  # API routes
  scope "/api" do
    pipe_through :api

    # OpenAPI spec and Swagger UI (no auth required for documentation)
    get "/openapi", OpenApiSpex.Plug.RenderSpec, []
  end

  scope "/api", SmartTodoWeb.Api, as: :api do
    pipe_through [:api, :api_auth]

    post "/tasks/process", TaskController, :process_natural_language

    resources "/tasks", TaskController, except: [:new, :edit] do
      post "/complete", TaskController, :complete
    end
  end

  # MCP endpoint with token in path
  scope "/mcp/:token" do
    pipe_through :mcp

    forward "/", Anubis.Server.Transport.StreamableHTTP.Plug, server: :smart_todo_mcp
  end

  # Swagger UI (available at /swaggerui)
  scope "/" do
    pipe_through :browser

    get "/swaggerui", OpenApiSpex.Plug.SwaggerUI, path: "/api/openapi"
  end

  # Enable LiveDashboard and Swoosh mailbox preview in development
  if Application.compile_env(:smart_todo, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: SmartTodoWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end

  ## Authentication routes

  scope "/", SmartTodoWeb do
    pipe_through [:browser, :require_authenticated_user]

    live_session :require_authenticated_user,
      on_mount: [{SmartTodoWeb.UserAuth, :require_authenticated}] do
      live "/users/settings", UserLive.Settings, :edit
      # Authenticated routes
      live "/tasks", TaskLive.Index, :index
      live "/groups", GroupLive.Index, :index
    end

    post "/users/update-password", UserSessionController, :update_password
  end

  scope "/", SmartTodoWeb do
    pipe_through [:browser]

    live_session :current_user,
      on_mount: [{SmartTodoWeb.UserAuth, :mount_current_scope}] do
      live "/users/register", UserLive.Registration, :new
      live "/users/log-in", UserLive.Login, :new
    end

    post "/users/log-in", UserSessionController, :create
    delete "/users/log-out", UserSessionController, :delete
  end
end
