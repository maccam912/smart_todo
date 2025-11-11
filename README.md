# SmartTodo

To start your Phoenix server:

* Run `mix setup` to install and setup dependencies
* Start Phoenix endpoint with `mix phx.server` or inside IEx with `iex -S mix phx.server`

Now you can visit [`localhost:4000`](http://localhost:4000) from your browser.

Ready to run in production? Please [check our deployment guides](https://hexdocs.pm/phoenix/deployment.html).

## Configuring the LLM provider

SmartTodo can be compiled to use either the hosted Gemini API or a local
Gemma 3 12B model served by [`llama.cpp`](https://github.com/ggerganov/llama.cpp).

### Build-time selection

Set `SMART_TODO_LLM_PROVIDER` **before compiling**:

* `SMART_TODO_LLM_PROVIDER=gemini` (default) keeps the existing Gemini
  integration and requires either `GEMINI_API_KEY` or `GOOGLE_API_KEY` at runtime.
* `SMART_TODO_LLM_PROVIDER=gemma3_local` (or `local`/`gemma3`) embeds the
  llama.cpp integration. At runtime the application downloads the Gemma model
  (if needed) and launches the local server automatically.

Re-run `mix deps.get` and `mix compile` after changing the provider so the
compile-time configuration takes effect.

### Local Gemma settings

When building with the local provider you can customise the llama.cpp runtime
using the following environment variables:

| Variable | Purpose | Default |
| --- | --- | --- |
| `SMART_TODO_LOCAL_MODEL_DIR` | Directory that will store downloaded models | `priv/local_llm` |
| `SMART_TODO_LOCAL_MODEL_FILE` | Gemma 3 GGUF filename | `gemma-3-12b-it-Q4_K_M.gguf` |
| `SMART_TODO_LOCAL_MODEL_URL` | Download URL for the GGUF file | Google Gemma 3 12B instruct Q4_K_M |
| `SMART_TODO_LOCAL_MODEL_NAME` | Name advertised to the llama.cpp API | Root name of the model file |
| `SMART_TODO_LOCAL_SERVER_HOST` / `SMART_TODO_LOCAL_SERVER_PORT` | Host/port for the llama.cpp server | `127.0.0.1:11434` |
| `LLAMA_CPP_SERVER_BIN` | Path to the `server` executable from llama.cpp | `../llama.cpp/server` relative to project root |
| `SMART_TODO_LOCAL_SERVER_ARGS` | Extra CLI arguments for llama.cpp | _none_ |
| `SMART_TODO_LOCAL_STARTUP_TIMEOUT_MS` | How long to wait for the server to boot | `180000` |
| `SMART_TODO_LOCAL_RECEIVE_TIMEOUT_MS` | Request timeout when talking to llama.cpp | `600000` |
| `SMART_TODO_LOCAL_HEALTH_PATH` | Endpoint used for readiness checks | `/health` |

The application stores downloaded weights under `priv/local_llm/` and keeps the
server process supervised so it is restarted if it exits. Logs from the server
are forwarded to the application’s stdout/stderr stream for easier debugging.

## Learn more

* Official website: https://www.phoenixframework.org/
* Guides: https://hexdocs.pm/phoenix/overview.html
* Docs: https://hexdocs.pm/phoenix
* Forum: https://elixirforum.com/c/phoenix-forum
* Source: https://github.com/phoenixframework/phoenix
