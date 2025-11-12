# SmartTodo

To start your Phoenix server:

* Run `mix setup` to install and setup dependencies
* Start Phoenix endpoint with `mix phx.server` or inside IEx with `iex -S mix phx.server`

Now you can visit [`localhost:4000`](http://localhost:4000) from your browser.

Ready to run in production? Please [check our deployment guides](https://hexdocs.pm/phoenix/deployment.html).

## LLM Provider Configuration

SmartTodo supports two LLM providers for task automation:

### 1. Local Gemma 3 12B Model (Default)

Uses a local Gemma 3 12B model via llama.cpp for fully offline operation.

**Default Setup:**
```bash
# Local provider is the default, just start the server
mix phx.server
```

On first startup, the app will automatically:
1. Download the Gemma 3 12B model (~7GB) if not present
2. Start the llama.cpp server
3. Wait for the server to be ready before accepting requests

### 2. Gemini API

Uses Google's Gemini 2.5 Flash model via API.

**Setup:**
```bash
export LLM_PROVIDER=gemini
export GEMINI_API_KEY=your_api_key_here
mix clean
mix compile
mix phx.server
```

## Docker Deployment

The Dockerfile is pre-configured for the local Gemma 3 model:

**Build and run:**
```bash
docker build -t smart_todo .
docker run -p 4000:4000 -p 8080:8080 \
  -v smart_todo_models:/app/priv/models \
  -e SECRET_KEY_BASE=$(mix phx.gen.secret) \
  -e DATABASE_URL=your_database_url \
  smart_todo
```

**What happens on first startup:**
1. llama.cpp is already built into the image
2. The Gemma 3 12B model (~7GB) downloads automatically to the volume
3. llama-server starts on port 8080 using 3 CPU threads
4. Phoenix server starts on port 4000 once llama-server is ready

**To use Gemini API instead in Docker:**
```bash
docker build --build-arg LLM_PROVIDER=gemini -t smart_todo .
docker run -p 4000:4000 \
  -e LLM_PROVIDER=gemini \
  -e GEMINI_API_KEY=your_key \
  -e SECRET_KEY_BASE=$(mix phx.gen.secret) \
  -e DATABASE_URL=your_database_url \
  smart_todo
```

## Requirements

**For local model (default):**
- ~10GB disk space (model + build artifacts)
- 16GB+ RAM recommended
- CUDA-capable GPU optional (for faster inference)
- CMake and Git (for building llama.cpp - handled automatically in Docker)

**For Gemini API:**
- Internet connection
- Gemini API key

## Performance Notes
- **Local Gemma:** Slower (~5-30s per inference on CPU), offline, free, private
- **Gemini API:** Fast (<2s per inference), requires internet, API costs
- GPU acceleration recommended for local model

## Learn more

* Official website: https://www.phoenixframework.org/
* Guides: https://hexdocs.pm/phoenix/overview.html
* Docs: https://hexdocs.pm/phoenix
* Forum: https://elixirforum.com/c/phoenix-forum
* Source: https://github.com/phoenixframework/phoenix
