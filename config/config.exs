# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :mime, :types, %{"application/manifest+json" => ["webmanifest"]}

config :smart_todo, :scopes,
  user: [
    default: true,
    module: SmartTodo.Accounts.Scope,
    assign_key: :current_scope,
    access_path: [:user, :id],
    schema_key: :user_id,
    schema_type: :id,
    schema_table: :users,
    test_data_fixture: SmartTodo.AccountsFixtures,
    test_setup_helper: :register_and_log_in_user
  ]

config :smart_todo,
  ecto_repos: [SmartTodo.Repo],
  generators: [timestamp_type: :utc_datetime]

# LLM Provider configuration
# OPENAI_API_BASE: Base URL for the OpenAI compatible API
# OPENAI_API_KEY: API key for the OpenAI compatible API
# OPENAI_MODEL: The model to use for the LLM
config :smart_todo, :llm,
  model: System.get_env("OPENAI_MODEL", "gpt-4-turbo")

# Configures the endpoint
config :smart_todo, SmartTodoWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: SmartTodoWeb.ErrorHTML, json: SmartTodoWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: SmartTodo.PubSub,
  live_view: [signing_salt: "Lf+s4l57"]

# Configures the mailer
#
# By default it uses the "Local" adapter which stores the emails
# locally. You can see the emails in your browser, at "/dev/mailbox".
#
# For production it's recommended to configure a different adapter
# at the `config/runtime.exs`.
config :smart_todo, SmartTodo.Mailer, adapter: Swoosh.Adapters.Local

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  smart_todo: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.1.7",
  smart_todo: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__)
  ]

# Configures Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
