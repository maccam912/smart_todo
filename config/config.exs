# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

llm_provider =
  System.get_env("SMART_TODO_LLM_PROVIDER", "gemini")
  |> String.downcase()
  |> case do
    "gemma3" -> :gemma3_local
    "gemma3_local" -> :gemma3_local
    "local" -> :gemma3_local
    _ -> :gemini
  end

config :smart_todo, :llm_provider, llm_provider

local_llm_dir =
  System.get_env("SMART_TODO_LOCAL_MODEL_DIR") ||
    Path.expand("../priv/local_llm", __DIR__)

local_model_file =
  System.get_env("SMART_TODO_LOCAL_MODEL_FILE") || "gemma-3-12b-it-Q4_K_M.gguf"

local_model_path =
  Path.join(local_llm_dir, local_model_file)
  |> Path.expand()

local_model_name =
  System.get_env("SMART_TODO_LOCAL_MODEL_NAME") ||
    Path.rootname(Path.basename(local_model_file))

local_download_url =
  System.get_env("SMART_TODO_LOCAL_MODEL_URL") ||
    "https://huggingface.co/google/gemma-3-12b-it-GGUF/resolve/main/gemma-3-12b-it-Q4_K_M.gguf?download=1"

local_server_host =
  System.get_env("SMART_TODO_LOCAL_SERVER_HOST") || "127.0.0.1"

local_server_port =
  System.get_env("SMART_TODO_LOCAL_SERVER_PORT")
  |> case do
    nil -> 11_434
    value -> String.to_integer(value)
  end

local_server_bin =
  System.get_env("LLAMA_CPP_SERVER_BIN") ||
    Path.expand("../llama.cpp/server", __DIR__)

local_server_args =
  System.get_env("SMART_TODO_LOCAL_SERVER_ARGS", "")
  |> String.trim()
  |> case do
    "" -> []
    value -> OptionParser.split(value)
  end

local_startup_timeout =
  System.get_env("SMART_TODO_LOCAL_STARTUP_TIMEOUT_MS")
  |> case do
    nil -> 180_000
    value -> String.to_integer(value)
  end

local_receive_timeout =
  System.get_env("SMART_TODO_LOCAL_RECEIVE_TIMEOUT_MS")
  |> case do
    nil -> :timer.minutes(10)
    value -> String.to_integer(value)
  end

local_health_path =
  System.get_env("SMART_TODO_LOCAL_HEALTH_PATH") || "/health"

config :smart_todo, :local_llm,
  model_path: local_model_path,
  model_name: local_model_name,
  download_url: local_download_url,
  server_host: local_server_host,
  server_port: local_server_port,
  server_binary: local_server_bin,
  extra_server_args: local_server_args,
  startup_timeout: local_startup_timeout,
  receive_timeout: local_receive_timeout,
  health_path: local_health_path

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
