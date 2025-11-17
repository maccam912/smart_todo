# OpenTelemetry Observability

This document describes the OpenTelemetry (OTEL) instrumentation implemented in SmartTodo for comprehensive observability.

## Overview

SmartTodo includes comprehensive OpenTelemetry instrumentation for:
- **Traces**: Distributed tracing for request flows, database queries, and business operations
- **Metrics**: Business and system metrics exported via OTLP
- **Logs**: Structured logging with trace correlation

## Configuration

### Standard OTLP Configuration (Recommended)

Set the following environment variables to configure the OTLP exporter:

```bash
# Required: OTLP collector endpoint
export OTEL_EXPORTER_OTLP_ENDPOINT="http://localhost:4318"

# Optional: Service name (defaults to "smart_todo")
export OTEL_SERVICE_NAME="smart_todo"

# Optional: Additional resource attributes
export OTEL_RESOURCE_ATTRIBUTES="deployment.environment=production,service.version=1.0.0"

# Optional: Headers for authentication (format: key1=value1,key2=value2)
export OTEL_EXPORTER_OTLP_HEADERS="authorization=Bearer YOUR_TOKEN"

# Optional: Protocol (http/protobuf or grpc, defaults to http/protobuf)
export OTEL_EXPORTER_OTLP_PROTOCOL="http/protobuf"

# Optional: Separate endpoints for different signals
export OTEL_EXPORTER_OTLP_TRACES_ENDPOINT="http://localhost:4318/v1/traces"
export OTEL_EXPORTER_OTLP_METRICS_ENDPOINT="http://localhost:4318/v1/metrics"
export OTEL_EXPORTER_OTLP_LOGS_ENDPOINT="http://localhost:4318/v1/logs"
```

### Phoenix Arize Configuration (Legacy)

For backward compatibility, you can still use Phoenix Arize-specific configuration:

```bash
export PHOENIX_API_KEY="your-api-key"
export PHOENIX_COLLECTOR_ENDPOINT="https://phoenix.rackspace.koski.co"  # Optional
```

**Note**: Standard OTLP configuration takes precedence over Phoenix Arize configuration.

## Instrumentation Details

### 1. Automatic Framework Instrumentation

The following frameworks are automatically instrumented:

#### Phoenix HTTP Requests
- **Library**: `opentelemetry_phoenix`
- **Spans**: All HTTP requests to Phoenix endpoints
- **Attributes**: Route, status code, method, etc.

#### Bandit Web Server
- **Library**: `opentelemetry_bandit`
- **Spans**: HTTP server request handling

#### Ecto Database Queries
- **Library**: `opentelemetry_ecto`
- **Spans**: All database queries
- **Attributes**: Query, source (table), decode/query/queue time

### 2. Custom Business Logic Instrumentation

#### Task Operations

All task operations are instrumented with custom spans:

**Create Task** (`lib/smart_todo/tasks.ex:82`)
- Span: `smart_todo.tasks.create`
- Attributes:
  - `user.id`: User creating the task
  - `task.title`: Task title
  - `task.id`: Created task ID
  - `task.status`: Initial task status
- Events: `task.create.error` on validation failures

**Update Task** (`lib/smart_todo/tasks.ex:144`)
- Span: `smart_todo.tasks.update`
- Attributes:
  - `user.id`: User updating the task
  - `task.id`: Task ID
  - `task.previous_status`: Status before update
  - `task.new_status`: Status after update
- Events: `task.update.error` on validation failures

**Delete Task** (`lib/smart_todo/tasks.ex:194`)
- Span: `smart_todo.tasks.delete`
- Attributes:
  - `user.id`: User deleting the task
  - `task.id`: Task ID
  - `task.status`: Task status at deletion
- Events: `task.deleted`, `task.delete.error`

**Complete Task** (`lib/smart_todo/tasks.ex:230`)
- Span: `smart_todo.tasks.complete`
- Attributes:
  - `user.id`: User completing the task
  - `task.id`: Task ID
  - `task.recurrence`: Recurrence type
  - `task.prerequisites_count`: Number of prerequisites
  - `task.prerequisites_done`: Whether all prerequisites are done
- Events:
  - `task.completed`: When task is successfully completed
  - `task.recurrence.created`: When a recurring task instance is created
  - `task.complete.error`: On validation/completion failures

#### LLM Agent Operations

**Agent Session** (`lib/smart_todo/agent/llm_session.ex:63`)
- Span: `smart_todo.agent.session`
- Kind: `:internal`
- OpenInference attributes:
  - `openinference.span.kind`: "AGENT"
  - `session.id`: UUID v4 session tracking
  - `user.id`: User identifier
  - `input.value`: User request text
  - `output.value`: Formatted agent result

**Gemini API Calls** (`lib/smart_todo/agent/llm_session.ex:298`)
- Span: `gen_ai.gemini.chat`
- Kind: `:client`
- Semantic conventions (gen_ai.*):
  - `gen_ai.system`: "gemini"
  - `gen_ai.request.model`: Model name
  - `gen_ai.operation.name`: "chat"
  - `gen_ai.response.finish_reasons`: Completion reasons
- OpenInference attributes:
  - `openinference.span.kind`: "LLM"
  - `input.value`: Last user message (for quick access)
  - `output.value`: Model response (for quick access)
  - `llm.input_messages`: Full conversation history (JSON array)
  - `llm.output_messages`: Full model response messages (JSON array)
  - `llm.system`: System prompt/instruction
  - `llm.model_name`: Model identifier
  - `llm.tools`: Available tools (function names and count)
  - `session.id`, `user.id`: Session tracking

**llama.cpp API Calls** (`lib/smart_todo/agent/llama_cpp_adapter.ex:37`)
- Span: `gen_ai.llama_cpp.chat`
- Kind: `:client`
- Semantic conventions (gen_ai.*):
  - `gen_ai.system`: "llama_cpp"
  - `gen_ai.request.model`, `gen_ai.request.temperature`, `gen_ai.request.max_tokens`
  - `gen_ai.usage.input_tokens`, `gen_ai.usage.output_tokens`
- OpenInference attributes:
  - Same as Gemini above, plus:
  - `llm.invocation_parameters`: Temperature, max_tokens, cache_prompt
  - `llm.token_count.prompt`, `llm.token_count.completion`, `llm.token_count.total`

### 3. Metrics

The following business metrics are exported:

#### Task Metrics
- `smart_todo.tasks.create.count`: Total tasks created
  - Tags: `user_id`, `status`
- `smart_todo.tasks.update.count`: Total tasks updated
  - Tags: `user_id`, `status`
- `smart_todo.tasks.delete.count`: Total tasks deleted
  - Tags: `user_id`
- `smart_todo.tasks.complete.count`: Total tasks completed
  - Tags: `user_id`, `recurrence`

#### Phoenix Metrics
- Request duration summaries
- Router dispatch timing
- Socket connection metrics

#### Database Metrics
- Query timing (total, decode, query, queue, idle)
- Connection pool metrics

#### VM Metrics
- Memory usage
- Process queue lengths

### 4. Logs with Trace Correlation

Logs are automatically correlated with traces using:
- `opentelemetry_logger_metadata`: Adds trace context to log metadata
- Custom OTEL logger handler: Exports logs to OTLP endpoint

Log entries include:
- `trace_id`: Current trace ID
- `span_id`: Current span ID
- Standard log fields (level, message, timestamp, etc.)

## Semantic Conventions

### OpenInference

We follow [OpenInference](https://github.com/Arize-ai/openinference) semantic conventions for AI/LLM observability:

- `openinference.span.kind`: AGENT, LLM, CHAIN, etc.
- `session.id`: Session tracking across multiple LLM calls
- `input.value`, `output.value`: Request/response content
- `llm.input_messages`, `llm.output_messages`: Full conversation history
- `llm.system`, `llm.tools`, `llm.model_name`: LLM configuration
- `llm.token_count.*`: Token usage metrics

**Note**: We implement OpenInference conventions manually. For a more standardized approach, consider the [agent_obs](https://hex.pm/packages/agent_obs) package which provides:
- Native :telemetry events for agent operations
- Automatic translation to OpenTelemetry spans with OpenInference conventions
- Higher-level abstractions for common patterns
- Better integration with tools like Arize Phoenix

### OpenTelemetry Semantic Conventions

We follow [OpenTelemetry semantic conventions](https://opentelemetry.io/docs/specs/semconv/) for:

- `gen_ai.*`: Generative AI operations
- `http.*`: HTTP client/server operations
- `db.*`: Database operations
- `server.*`: Server attributes

## Prompt Caching Optimization

The LLM prompts are structured to maximize efficiency with prefix caching:

1. **System Prompt** (static, cached across all sessions):
   - Core rules and instructions
   - Static documentation (status values, urgency levels, etc.)
   - User preferences (semi-static, changes rarely)

2. **User Messages** (ordered for caching):
   - **Semi-static content first** (better cache hit rate):
     - Available commands (only changes on state transitions)
     - Recorded plans (grows but doesn't change)
   - **Dynamic content last** (frequently changing):
     - Pending operations
     - Open tasks
     - Current state and session message

This ordering ensures that the maximum amount of prompt content can be cached by the LLM provider, reducing latency and costs.

## Testing the Instrumentation

### With Local OTEL Collector

1. Run an OTEL collector locally:
```bash
docker run -p 4318:4318 -p 4317:4317 \
  otel/opentelemetry-collector-contrib:latest
```

2. Configure your application:
```bash
export OTEL_EXPORTER_OTLP_ENDPOINT="http://localhost:4318"
export OTEL_SERVICE_NAME="smart_todo"
```

3. Start the application:
```bash
mix phx.server
```

4. Make requests and observe traces/metrics/logs in your collector.

### With Jaeger (Traces Only)

1. Run Jaeger with OTLP support:
```bash
docker run -d --name jaeger \
  -e COLLECTOR_OTLP_ENABLED=true \
  -p 16686:16686 \
  -p 4318:4318 \
  jaegertracing/all-in-one:latest
```

2. Configure and run as above

3. View traces at http://localhost:16686

### With Grafana Stack

Use the Grafana LGTM stack (Loki, Grafana, Tempo, Mimir) for full observability:

```yaml
# docker-compose.yml
version: '3'
services:
  otel-collector:
    image: otel/opentelemetry-collector-contrib:latest
    ports:
      - "4318:4318"
      - "4317:4317"
    volumes:
      - ./otel-config.yaml:/etc/otel-collector-config.yaml
    command: ["--config=/etc/otel-collector-config.yaml"]

  tempo:
    image: grafana/tempo:latest
    ports:
      - "3200:3200"
      - "4317:4317"  # OTLP gRPC
      - "4318:4318"  # OTLP HTTP

  prometheus:
    image: prom/prometheus:latest
    ports:
      - "9090:9090"

  loki:
    image: grafana/loki:latest
    ports:
      - "3100:3100"

  grafana:
    image: grafana/grafana:latest
    ports:
      - "3000:3000"
```

## Troubleshooting

### No traces appearing

1. Check OTEL endpoint configuration:
```bash
echo $OTEL_EXPORTER_OTLP_ENDPOINT
```

2. Check collector logs for errors

3. Verify network connectivity:
```bash
curl -v http://localhost:4318/v1/traces
```

### Metrics not exported

1. Verify metrics endpoint is configured
2. Check if telemetry events are being emitted (add temporary logging)
3. Ensure OpentelemetryTelemetry handlers are attached

### Logs missing trace context

1. Verify logger handler is installed:
```elixir
:logger.get_handler_config(:otel_logger)
```

2. Check if `opentelemetry_logger_metadata.setup()` was called

## References

- [OpenTelemetry Specification](https://opentelemetry.io/docs/specs/otel/)
- [OpenTelemetry Erlang/Elixir](https://opentelemetry.io/docs/languages/erlang/)
- [OpenInference Specification](https://github.com/Arize-ai/openinference)
- [OpenTelemetry Semantic Conventions](https://opentelemetry.io/docs/specs/semconv/)
