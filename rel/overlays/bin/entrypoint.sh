#!/bin/bash
set -ex

# Configuration from environment variables
MODEL_URL="${MODEL_URL:-https://huggingface.co/ggml-org/gemma-3-12b-it-GGUF/resolve/main/gemma-3-12b-it-Q4_K_M.gguf}"
MODEL_PATH="${LOCAL_MODEL_PATH:-/app/priv/models}/gemma-3-12b-it-Q4_K_M.gguf"
LLAMA_CPP_DIR="${LLAMA_CPP_DIR:-/app/priv/llama.cpp}"
LLAMA_SERVER_BIN="${LLAMA_CPP_DIR}/build/bin/llama-server"
LLAMA_PORT="${LLAMA_PORT:-8080}"
LLM_PROVIDER="${LLM_PROVIDER:-local}"

# Startup timeout in seconds (default: 10 minutes)
STARTUP_TIMEOUT="${STARTUP_TIMEOUT:-600}"
HEALTH_CHECK_INTERVAL=5

echo "=========================================="
echo "Smart Todo Application Startup"
echo "=========================================="
echo "LLM Provider: ${LLM_PROVIDER}"
echo "Startup timeout: ${STARTUP_TIMEOUT}s"
echo ""

# Only proceed with llama setup if using local provider
if [ "$LLM_PROVIDER" != "local" ]; then
    echo "LLM provider is not 'local', skipping llama-server setup"
    echo "Starting Elixir application..."
    exec "$@"
fi

# Step 1: Download GGUF model if needed
echo "=========================================="
echo "Step 1: Checking GGUF model"
echo "=========================================="
echo "Model path: ${MODEL_PATH}"

if [ -f "$MODEL_PATH" ]; then
    MODEL_SIZE=$(du -h "$MODEL_PATH" | cut -f1)
    echo "✓ Model already exists (${MODEL_SIZE})"
else
    echo "Model not found, downloading..."
    echo "URL: ${MODEL_URL}"
    echo ""

    # Create models directory if it doesn't exist
    mkdir -p "$(dirname "$MODEL_PATH")"

    # Download with progress
    if command -v curl &> /dev/null; then
        curl -L --progress-bar -o "$MODEL_PATH" "$MODEL_URL"
    elif command -v wget &> /dev/null; then
        wget --show-progress -O "$MODEL_PATH" "$MODEL_URL"
    else
        echo "ERROR: Neither curl nor wget is available"
        exit 1
    fi

    MODEL_SIZE=$(du -h "$MODEL_PATH" | cut -f1)
    echo ""
    echo "✓ Model downloaded successfully (${MODEL_SIZE})"
fi
echo ""

# Step 2: Compile llama.cpp if needed
echo "=========================================="
echo "Step 2: Checking llama-server compilation"
echo "=========================================="
echo "Expected binary: ${LLAMA_SERVER_BIN}"

NEEDS_COMPILE=false
FORCE_RECOMPILE="${FORCE_RECOMPILE:-true}"

if [ "$FORCE_RECOMPILE" = "true" ]; then
    echo "⚠ FORCE_RECOMPILE is set, forcing recompilation..."
    echo "Removing old build to force recompilation..."
    rm -rf "$LLAMA_CPP_DIR/build"
    NEEDS_COMPILE=true
elif [ -f "$LLAMA_SERVER_BIN" ]; then
    echo "Found existing llama-server binary, testing compatibility..."
    # Test if the binary works (might have illegal instructions from old build)
    if timeout 5 "$LLAMA_SERVER_BIN" --version > /dev/null 2>&1; then
        echo "✓ llama-server binary is compatible"
    else
        echo "⚠ Existing binary is incompatible (likely illegal instructions)"
        echo "Removing old build to force recompilation..."
        rm -rf "$LLAMA_CPP_DIR/build"
        NEEDS_COMPILE=true
    fi
else
    NEEDS_COMPILE=true
fi

if [ "$NEEDS_COMPILE" = true ]; then
    echo "llama-server needs compilation..."
    echo ""

    # Create directory
    mkdir -p "$LLAMA_CPP_DIR"

    # Clone llama.cpp if needed
    if [ ! -d "$LLAMA_CPP_DIR/.git" ]; then
        echo "Cloning llama.cpp repository..."
        git clone --depth 1 https://github.com/ggerganov/llama.cpp "$LLAMA_CPP_DIR"
        echo "✓ Repository cloned"
        echo ""
    else
        echo "✓ Repository already exists (using PVC)"
        echo ""
    fi

    # Build llama-server
    echo "Building llama-server (this may take several minutes)..."
    cd "$LLAMA_CPP_DIR"

    # Ensure build directory exists and has proper permissions
    echo "Creating build directory..."
    mkdir -p build
    chmod 755 build

    echo "Running cmake configuration..."
    # Use extremely conservative settings for Sandy Bridge CPU
    # This CPU supports up to SSE4.2 but NOT BMI/BMI2/AVX2
    cmake -B build -G Ninja \
        -DCMAKE_BUILD_TYPE=Debug \
        -DGGML_NATIVE=OFF \
        -DGGML_CUDA=OFF \
        -DGGML_METAL=OFF \
        -DGGML_AVX=OFF \
        -DGGML_AVX2=OFF \
        -DGGML_AVX512=OFF \
        -DGGML_FMA=OFF \
        -DGGML_F16C=OFF \
        -DGGML_SSE3=OFF \
        -DGGML_SSSE3=OFF \
        -DGGML_SSE4=OFF \
        -DGGML_SSE42=OFF \
        -DGGML_BMI=OFF \
        -DGGML_BMI2=OFF \
        -DGGML_CPU_ALL_VARIANTS=OFF \
        -DGGML_CPU_HBM=OFF \
        -DBUILD_SHARED_LIBS=OFF \
        -DCMAKE_C_COMPILER_LAUNCHER="" \
        -DCMAKE_CXX_COMPILER_LAUNCHER="" \
        -DCMAKE_C_FLAGS="-march=core2 -mtune=generic -mno-sse3 -mno-ssse3 -mno-sse4 -mno-sse4.1 -mno-sse4.2 -mno-avx -mno-avx2 -mno-bmi -mno-bmi2 -mno-fma -mno-f16c -O0 -g" \
        -DCMAKE_CXX_FLAGS="-march=core2 -mtune=generic -mno-sse3 -mno-ssse3 -mno-sse4 -mno-sse4.1 -mno-sse4.2 -mno-avx -mno-avx2 -mno-bmi -mno-bmi2 -mno-fma -mno-f16c -O0 -g"
    echo "✓ CMake configuration complete"
    echo ""

    echo "Compiling llama-server with ninja..."
    cmake --build build --target llama-server
    echo "✓ Compilation complete"
    echo ""

    # Verify the binary was created
    if [ ! -f "$LLAMA_SERVER_BIN" ]; then
        echo "ERROR: llama-server binary not found after compilation"
        exit 1
    fi

    cd - > /dev/null
fi
echo ""

# Step 3: Start llama-server in background
echo "=========================================="
echo "Step 3: Starting llama-server"
echo "=========================================="
echo "Port: ${LLAMA_PORT}"
echo "Context size: 2048 (reduced for stability)"
echo "Max tokens: 512 (reduced for stability)"
echo "Threads: 1 (single thread for debugging)"
echo ""

# First, test if the binary can run at all
echo "Testing binary compatibility..."
if ! "$LLAMA_SERVER_BIN" --version > /tmp/llama-version-test.log 2>&1; then
    echo "ERROR: Binary test failed with illegal instruction"
    echo "Version test output:"
    cat /tmp/llama-version-test.log
    echo ""
    echo "Running 'file' command on binary:"
    file "$LLAMA_SERVER_BIN"
    echo ""
    echo "CPU information:"
    cat /proc/cpuinfo | grep -E "model name|flags" | head -5
    exit 1
fi
echo "✓ Binary compatibility test passed"
echo ""

# Start llama-server in background with reduced resources
"$LLAMA_SERVER_BIN" \
    --port "$LLAMA_PORT" \
    --model "$MODEL_PATH" \
    --ctx-size 2048 \
    --n-predict 512 \
    --threads 1 \
    --log-disable \
    > /tmp/llama-server.log 2>&1 &

LLAMA_PID=$!
echo "✓ llama-server started (PID: ${LLAMA_PID})"

# Save PID for later cleanup
echo "$LLAMA_PID" > /tmp/llama-server.pid
echo ""

# Step 4: Wait for llama-server to become ready
echo "=========================================="
echo "Step 4: Waiting for llama-server to be ready"
echo "=========================================="
echo "Health check endpoint: http://localhost:${LLAMA_PORT}/health"
echo "Timeout: ${STARTUP_TIMEOUT}s"
echo ""

elapsed=0
while [ $elapsed -lt $STARTUP_TIMEOUT ]; do
    # Check if process is still running
    if ! kill -0 "$LLAMA_PID" 2>/dev/null; then
        echo ""
        echo "ERROR: llama-server process died"
        echo "Last 50 lines of log:"
        tail -n 50 /tmp/llama-server.log
        exit 1
    fi

    # Check health endpoint
    if curl -s -f "http://localhost:${LLAMA_PORT}/health" > /dev/null 2>&1; then
        echo ""
        echo "✓ llama-server is ready!"
        break
    fi

    # Show progress
    echo -n "."
    sleep "$HEALTH_CHECK_INTERVAL"
    elapsed=$((elapsed + HEALTH_CHECK_INTERVAL))
done

if [ $elapsed -ge $STARTUP_TIMEOUT ]; then
    echo ""
    echo "ERROR: llama-server failed to become ready within ${STARTUP_TIMEOUT}s"
    echo "Last 50 lines of log:"
    tail -n 50 /tmp/llama-server.log
    kill "$LLAMA_PID" 2>/dev/null || true
    exit 1
fi

echo ""

# Step 5: Start Elixir application
echo "=========================================="
echo "Step 5: Starting Elixir application"
echo "=========================================="
echo ""

# Setup cleanup trap
cleanup() {
    echo ""
    echo "Shutting down llama-server..."
    if [ -f /tmp/llama-server.pid ]; then
        kill $(cat /tmp/llama-server.pid) 2>/dev/null || true
        rm -f /tmp/llama-server.pid
    fi
}
trap cleanup EXIT INT TERM

# Execute the original command (start Elixir app)
exec "$@"
