# SmartTodo

To start your Phoenix server:

* Run `mix setup` to install and setup dependencies
* Start Phoenix endpoint with `mix phx.server` or inside IEx with `iex -S mix phx.server`

Now you can visit [`localhost:4000`](http://localhost:4000) from your browser.

Ready to run in production? Please [check our deployment guides](https://hexdocs.pm/phoenix/deployment.html).

## LLM Configuration

SmartTodo uses an OpenAI-compatible API for all LLM functionality. Configure your LLM provider using environment variables:

### OpenAI Compatible Endpoint

```bash
export OPENAI_API_BASE="https://api.openai.com/v1" # Or your custom endpoint
export OPENAI_API_KEY="your-api-key-here"
export OPENAI_MODEL="gpt-4-turbo" # Or any other compatible model
```

### Environment Variables Reference

- `OPENAI_API_BASE`: The base URL for the OpenAI-compatible API. Defaults to `https://api.openai.com/v1`.
- `OPENAI_API_KEY`: Your API key for the OpenAI-compatible service.
- `OPENAI_MODEL`: The model to use for LLM operations. Defaults to `gpt-4-turbo`.

## Phoenix Arize Observability

SmartTodo integrates with Phoenix Arize for comprehensive observability using OpenTelemetry. To enable Phoenix Arize:

```bash
export PHOENIX_API_KEY="eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJqdGkiOiJBcGlLZXk6MSJ9.L_n-LclXtLE1_d7b3g6f5Jwmj-5f2552KCZ53uzQvG0"
export PHOENIX_COLLECTOR_ENDPOINT="https://phoenix.rackspace.koski.co"
```

Or use the OTEL_EXPORTER_OTLP_HEADERS format:

```bash
export OTEL_EXPORTER_OTLP_HEADERS='Authorization=Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJqdGkiOiJBcGlLZXk6MSJ9.L_n-LclXtLE1_d7b3g6f5Jwmj-5f2552KCZ53uzQvG0'
```

When configured, SmartTodo will automatically export:
- Phoenix HTTP request traces
- Ecto database query traces
- Custom application spans and metrics

View your traces and metrics at: https://phoenix.rackspace.koski.co

## Learn more

* Official website: https://www.phoenixframework.org/
* Guides: https://hexdocs.pm/phoenix/overview.html
* Docs: https://hexdocs.pm/phoenix
* Forum: https://elixirforum.com/c/phoenix-forum
* Source: https://github.com/phoenixframework/phoenix
