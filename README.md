# SmartTodo

To start your Phoenix server:

* Run `mix setup` to install and setup dependencies
* Start Phoenix endpoint with `mix phx.server` or inside IEx with `iex -S mix phx.server`

Now you can visit [`localhost:4000`](http://localhost:4000) from your browser.

Ready to run in production? Please [check our deployment guides](https://hexdocs.pm/phoenix/deployment.html).

## LLM Provider Configuration

SmartTodo supports two LLM providers for task automation:

### 1. Gemini API (Default)

Uses Google's Gemini 2.5 Flash model via API.

**Setup:**
```bash
export GEMINI_API_KEY=your_api_key_here
mix phx.server
```

### 2. Local Gemma 3 12B Model

Uses a local Gemma 3 12B model via llama.cpp for fully offline operation.

**Build-time Configuration:**
```bash
# Set the provider at build time
export LLM_PROVIDER=local

# Optional: Configure model location and server port
export LOCAL_MODEL_PATH=priv/models
export LLAMA_PORT=8080

# Build and run
mix deps.get
mix compile
mix phx.server
```

**What happens on first startup with local provider:**
1. Clones llama.cpp repository to `priv/llama.cpp/`
2. Builds llama.cpp with CMake
3. Downloads Gemma 3 12B Q4_K_M GGUF model (~7GB) to `priv/models/`
4. Starts llama-server on port 8080
5. Waits for server to be ready before accepting requests

**Requirements for local model:**
- CMake (for building llama.cpp)
- Git (for cloning llama.cpp)
- ~10GB disk space (model + build artifacts)
- 16GB+ RAM recommended
- CUDA-capable GPU optional (for faster inference)

**Switching between providers:**

To switch providers, you need to recompile with the new environment variable:

```bash
# Switch to Gemini
export LLM_PROVIDER=gemini
export GEMINI_API_KEY=your_key
mix clean
mix compile
mix phx.server

# Switch to local
export LLM_PROVIDER=local
mix clean
mix compile
mix phx.server
```

**Performance Notes:**
- Gemini: Fast, requires internet, API costs
- Local Gemma: Slower (~5-30s per inference on CPU), offline, free
- GPU acceleration recommended for local model (use `--n-gpu-layers 99`)

## Learn more

* Official website: https://www.phoenixframework.org/
* Guides: https://hexdocs.pm/phoenix/overview.html
* Docs: https://hexdocs.pm/phoenix
* Forum: https://elixirforum.com/c/phoenix-forum
* Source: https://github.com/phoenixframework/phoenix
