import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# Configure OpenTelemetry
# Supports standard OTEL env vars (preferred) or Phoenix Arize-specific configuration (fallback)
otel_endpoint = System.get_env("OTEL_EXPORTER_OTLP_ENDPOINT")
otel_traces_endpoint = System.get_env("OTEL_EXPORTER_OTLP_TRACES_ENDPOINT")
otel_metrics_endpoint = System.get_env("OTEL_EXPORTER_OTLP_METRICS_ENDPOINT")
otel_logs_endpoint = System.get_env("OTEL_EXPORTER_OTLP_LOGS_ENDPOINT")
otel_headers_str = System.get_env("OTEL_EXPORTER_OTLP_HEADERS", "")
otel_protocol = System.get_env("OTEL_EXPORTER_OTLP_PROTOCOL", "http/protobuf")
otel_service_name = System.get_env("OTEL_SERVICE_NAME", "smart_todo")
otel_resource_attributes = System.get_env("OTEL_RESOURCE_ATTRIBUTES", "")

# Phoenix Arize fallback configuration
phoenix_collector_endpoint = System.get_env("PHOENIX_COLLECTOR_ENDPOINT", "https://phoenix.rackspace.koski.co")
phoenix_api_key = System.get_env("PHOENIX_API_KEY")

# Parse headers from string format "key1=value1,key2=value2"
otel_headers =
  if otel_headers_str != "" do
    otel_headers_str
    |> String.split(",")
    |> Enum.map(fn pair ->
      [key, value] = String.split(pair, "=", parts: 2)
      {String.trim(key), String.trim(value)}
    end)
  else
    []
  end

# Determine final configuration (standard OTLP takes precedence)
{final_traces_endpoint, final_headers, final_protocol} =
  cond do
    otel_traces_endpoint || otel_endpoint ->
      endpoint = otel_traces_endpoint || otel_endpoint
      protocol = if otel_protocol == "grpc", do: :grpc, else: :http_protobuf
      {endpoint, otel_headers, protocol}

    phoenix_api_key ->
      {
        "#{phoenix_collector_endpoint}/v1/traces",
        [{"Authorization", "Bearer #{phoenix_api_key}"}],
        :http_protobuf
      }

    true ->
      {nil, [], :http_protobuf}
  end

# Configure metrics endpoint
final_metrics_endpoint =
  otel_metrics_endpoint || otel_endpoint || (phoenix_api_key && "#{phoenix_collector_endpoint}/v1/metrics")

# Configure logs endpoint
final_logs_endpoint =
  otel_logs_endpoint || otel_endpoint || (phoenix_api_key && "#{phoenix_collector_endpoint}/v1/logs")

# Set up resource attributes
resource_attrs =
  [{"service.name", otel_service_name}] ++
    if otel_resource_attributes != "" do
      otel_resource_attributes
      |> String.split(",")
      |> Enum.map(fn pair ->
        [key, value] = String.split(pair, "=", parts: 2)
        {String.trim(key), String.trim(value)}
      end)
    else
      []
    end

# Configure OpenTelemetry resource
config :opentelemetry, :resource, resource_attrs

# Configure trace exporter
if final_traces_endpoint do
  config :opentelemetry, :processors,
    otel_batch_processor: %{
      exporter: {:opentelemetry_exporter, %{
        endpoints: [final_traces_endpoint],
        headers: final_headers
      }}
    }

  config :opentelemetry_exporter,
    otlp_protocol: final_protocol,
    otlp_endpoint: final_traces_endpoint,
    otlp_headers: final_headers
end

# Configure metrics exporter
if final_metrics_endpoint do
  config :opentelemetry_exporter,
    otlp_metrics_endpoint: final_metrics_endpoint,
    otlp_metrics_headers: final_headers,
    otlp_metrics_protocol: final_protocol
end

# Configure logs exporter
if final_logs_endpoint do
  config :opentelemetry_exporter,
    otlp_logs_endpoint: final_logs_endpoint,
    otlp_logs_headers: final_headers,
    otlp_logs_protocol: final_protocol
end

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/smart_todo start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :smart_todo, SmartTodoWeb.Endpoint, server: true
end

if config_env() == :prod do
  database_url =
    System.get_env("DATABASE_URL") ||
      raise """
      environment variable DATABASE_URL is missing.
      For example: ecto://USER:PASS@HOST/DATABASE
      """

  maybe_ipv6 = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []

  config :smart_todo, SmartTodo.Repo,
    ssl: [
      verify: :verify_none
    ],
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
    # For machines with several cores, consider starting multiple pools of `pool_size`
    # pool_count: 4,
    socket_options: maybe_ipv6,
    # PgBouncer transaction mode settings
    prepare: :unnamed,
    parameters: []

  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST") || "example.com"
  port = String.to_integer(System.get_env("PORT") || "4000")

  config :smart_todo, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :smart_todo, SmartTodoWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      # Enable IPv6 and bind on all interfaces.
      # Set it to  {0, 0, 0, 0, 0, 0, 0, 1} for local network only access.
      # See the documentation on https://hexdocs.pm/bandit/Bandit.html#t:options/0
      # for details about using IPv6 vs IPv4 and loopback vs public addresses.
      ip: {0, 0, 0, 0, 0, 0, 0, 0},
      port: port
    ],
    secret_key_base: secret_key_base

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :smart_todo, SmartTodoWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://hexdocs.pm/plug/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :smart_todo, SmartTodoWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.

  # ## Configuring the mailer
  #
  # In production you need to configure the mailer to use a different adapter.
  # Here is an example configuration for Mailgun:
  #
  #     config :smart_todo, SmartTodo.Mailer,
  #       adapter: Swoosh.Adapters.Mailgun,
  #       api_key: System.get_env("MAILGUN_API_KEY"),
  #       domain: System.get_env("MAILGUN_DOMAIN")
  #
  # Most non-SMTP adapters require an API client. Swoosh supports Req, Hackney,
  # and Finch out-of-the-box. This configuration is typically done at
  # compile-time in your config/prod.exs:
  #
  #     config :swoosh, :api_client, Swoosh.ApiClient.Req
  #
  # See https://hexdocs.pm/swoosh/Swoosh.html#module-installation for details.
end
