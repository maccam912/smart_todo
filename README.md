# SmartTodo

To start your Phoenix server:

* Run `mix setup` to install and setup dependencies
* Start Phoenix endpoint with `mix phx.server` or inside IEx with `iex -S mix phx.server`

Now you can visit [`localhost:4000`](http://localhost:4000) from your browser.

Ready to run in production? Please [check our deployment guides](https://hexdocs.pm/phoenix/deployment.html).

## LLM Configuration

SmartTodo supports both Google Gemini API and local llama.cpp servers for LLM functionality. Configure your LLM provider using environment variables:

### llama.cpp (Default)

By default, SmartTodo is configured to use a llama.cpp server running Qwen 2.5 3B:

```bash
export LLM_BASE_URL="https://llama-cpp.rackspace.koski.co"
export LLAMA_CPP_MODEL="qwen2.5-3b-instruct"  # Optional: model identifier
export LLAMA_CPP_TOOL_CHOICE="auto"  # Optional: "auto", "required", or "none"
```

### Google Gemini API

To use Google's Gemini API instead:

```bash
export LLM_BASE_URL="https://generativelanguage.googleapis.com/v1beta"
export GEMINI_API_KEY="your-api-key-here"
# Optional: Use Helicone for observability
export HELICONE_API_KEY="your-helicone-key"
```

### Environment Variables Reference

- `LLM_BASE_URL`: Base URL for the LLM API (default: `https://llama-cpp.rackspace.koski.co`)
- `LLAMA_CPP_MODEL`: Model identifier for llama.cpp server (default: `qwen2.5-3b-instruct`)
- `LLAMA_CPP_TOOL_CHOICE`: Tool choice mode for function calling (default: `auto`)
  - `auto`: Let the model decide when to use tools
  - `required`: Force the model to use tools (may not be supported by all servers)
  - `none`: Disable tool use
- `GEMINI_API_KEY` or `GOOGLE_API_KEY`: API key for Google Gemini
- `HELICONE_API_KEY`: Optional API key for Helicone observability (Gemini only)
- `HELICONE_BASE_URL`: Helicone base URL (default: `https://gateway.helicone.ai/v1beta`)
- `HELICONE_TARGET_URL`: Target URL for Helicone proxy (default: `https://generativelanguage.googleapis.com`)

## Langfuse Integration

SmartTodo integrates with Langfuse for comprehensive LLM observability and monitoring. Langfuse tracks all API calls (both Gemini and local llama.cpp) including:

- Request/response payloads
- Token usage statistics
- Latency metrics
- Error tracking
- Conversation traces

### Configuration

To enable Langfuse tracking, configure the following environment variables:

```bash
export LANGFUSE_HOST="https://langfuse.rackspace.koski.co"
export LANGFUSE_PUBLIC_KEY="your-public-key"
export LANGFUSE_SECRET_KEY="your-secret-key"
export LANGFUSE_ENABLED="true"  # Optional: defaults to true
```

You can find your Langfuse API keys in your organization settings within the Langfuse dashboard.

### Disabling Langfuse

To temporarily disable Langfuse tracking without removing your credentials:

```bash
export LANGFUSE_ENABLED="false"
```

Langfuse will also be automatically disabled if the public or secret keys are not configured.

### What Gets Tracked

Each LLM session creates a trace in Langfuse containing:

- **Trace metadata**: User ID, scope type, original user request
- **Generation data**: For each API call:
  - Model name (e.g., `gemini-2.0-flash`, `qwen2.5-3b-instruct`)
  - Input payload (system prompts, conversation history, tools)
  - Output response
  - Token usage (for supported models)
  - Request duration
  - Provider information (Gemini or llama.cpp)
  - Error details (if the request failed)

This data is sent to your configured Langfuse instance for analysis and monitoring.

## Learn more

* Official website: https://www.phoenixframework.org/
* Guides: https://hexdocs.pm/phoenix/overview.html
* Docs: https://hexdocs.pm/phoenix
* Forum: https://elixirforum.com/c/phoenix-forum
* Source: https://github.com/phoenixframework/phoenix
