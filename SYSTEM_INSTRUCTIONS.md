# SmartTodo System Instructions for LLM Pre-Caching

This document describes the exact system instructions sent to the LLM and how they're structured for optimal prompt caching.

## Current Implementation

### System Instruction Structure

The system instruction is sent in the `systemInstruction` field of the request payload (see `lib/smart_todo/agent/llm_session.ex:95-104`):

```elixir
payload = %{
  "systemInstruction" => %{
    "role" => "system",
    "parts" => [%{"text" => system_prompt(ctx.scope)}]
  },
  "contents" => ctx.conversation,
  "tools" => [%{"functionDeclarations" => tools}],
  "toolConfig" => %{"functionCallingConfig" => %{"mode" => "ANY"}}
}
```

### Exact System Prompt Text

The system prompt is defined in `system_prompt/1` at line 765:

```
You manage SmartTodo tasks strictly through the provided function-call tools. Follow these rules:
1. Every reply MUST be exactly one function call defined in `available_commands`.
2. Read the state snapshot each turn; `available_commands` is the source of truth for what you can call.
3. To change, complete, or delete an existing task you MUST call `select_task` first. Once a task is selected, the editing commands (update, complete, delete, exit_editing) become available. If you are not editing, those commands are unavailable.
4. New tasks are staged with `create_task`; existing tasks accumulate staged changes until you `complete_session` (commit) or `discard_all`.
5. Whenever solving the request requires more than one command, call `record_plan` first to capture the steps you intend to take.
6. `complete_session` MUST be the final command you ever issue in a session; after calling it you may not send any further commands.
```

If user preferences exist (stored in `user_preference.prompt_preferences`), they are appended:

```
\n\nUser preferences:\n{user_preference.prompt_preferences}
```

### Translation to OpenAI Format (for llama.cpp)

When using llama.cpp servers, the `LlamaCppAdapter` translates the Gemini format to OpenAI format:

**From:** Gemini API format
```json
{
  "systemInstruction": {
    "role": "system",
    "parts": [{"text": "..."}]
  },
  "contents": [...]
}
```

**To:** OpenAI Chat Completions format
```json
{
  "model": "qwen2.5-3b-instruct",
  "messages": [
    {
      "role": "system",
      "content": "You manage SmartTodo tasks strictly through..."
    },
    {
      "role": "user",
      "content": "User request: ...\n[state snapshot]"
    },
    ...
  ],
  "tools": [...],
  "tool_choice": "auto",
  "temperature": 0.7,
  "max_tokens": 2048,
  "cache_prompt": true
}
```

**Note:** The adapter already sets `"cache_prompt": true` (line 69 of `llama_cpp_adapter.ex`).

## Caching Strategy

### Static Content (Cacheable)

These parts are the same across requests and should be cached:

1. **Base system prompt** (6 rules listed above)
2. **User preferences** (if present, these are per-user and rarely change)

### Dynamic Content (Not Cacheable)

These parts change with each request/turn:

1. **User request text** - Changes for each new session
2. **State snapshot** - Changes every turn, includes:
   - Session message
   - Current state
   - Error status
   - Open tasks list
   - Pending operations
   - Recorded plans
   - Available commands
3. **Conversation history** - Grows with each turn
4. **Tool declarations** - Changes based on state machine state

### Current Message Structure

The conversation turns are structured as follows:

**Initial turn** (line 646-650):
```
role: "user"
text: "User request: {user_text}\n{state_snapshot}"
```

**Error turn** (line 653-661):
```
role: "user"
text: "The previous command failed. Review the error details and try another command.\n{state_snapshot}"
```

**Followup turn** (line 666-672):
```
role: "user"
text: "State updated. Provide the next command.\n{state_snapshot}"
```

### State Snapshot Format

The state snapshot (rendered by `render_state_text/1` at line 675) contains:

```
Session message: {message}
State: {state}
Error?: {error?}
Open tasks:
{list of tasks with JSON data}
Pending operations:
{list of operations with JSON params}
Recorded plans:
{list of plans with steps}
Available commands:
{list of commands with descriptions and params}
```

## Optimal Structure for Pre-Caching

The current implementation is **already optimized** for prompt caching:

### ✅ Good: Static Content First

```
messages[0]: System message (static, cacheable)
  - Base rules (6 rules)
  - User preferences (optional, per-user static)
```

### ✅ Good: Dynamic Content After

```
messages[1+]: Conversation turns (dynamic)
  - User request + state snapshot
  - Model function calls
  - Tool responses
  - Follow-up prompts
```

### Cache Hit Rate

With this structure:
- **Per-user cache**: System message is cached per user (includes user preferences)
- **Cache invalidation**: Only when user preferences change
- **Dynamic data**: All changing data (state, commands, tasks) is in the conversation, not in the cached system message

## Alternative: Reorganized for Maximum Caching

If you want to maximize caching by moving more content into the static section, you could reorganize as follows:

### Option 1: Move Generic Instructions to System

```python
# STATIC (in systemInstruction, cacheable)
system_message = """
You manage SmartTodo tasks strictly through the provided function-call tools. Follow these rules:
1. Every reply MUST be exactly one function call defined in `available_commands`.
2. Read the state snapshot each turn; `available_commands` is the source of truth for what you can call.
3. To change, complete, or delete an existing task you MUST call `select_task` first. Once a task is selected, the editing commands (update, complete, delete, exit_editing) become available. If you are not editing, those commands are unavailable.
4. New tasks are staged with `create_task`; existing tasks accumulate staged changes until you `complete_session` (commit) or `discard_all`.
5. Whenever solving the request requires more than one command, call `record_plan` first to capture the steps you intend to take.
6. `complete_session` MUST be the final command you ever issue in a session; after calling it you may not send any further commands.

User preferences:
{user_preferences}

# Output format instructions
Each turn, you will receive a state snapshot in the following format:
- Session message: describes what just happened
- State: current state machine state
- Error?: whether the previous command failed
- Open tasks: list of existing tasks
- Pending operations: staged changes not yet committed
- Recorded plans: any plans you've recorded
- Available commands: the ONLY commands you can call this turn
"""

# DYNAMIC (in contents/messages, not cached)
user_message = """
User request: {user_text}

Session message: {message}
State: {state}
Error?: {error?}
Open tasks:
{tasks}
Pending operations:
{operations}
Recorded plans:
{plans}
Available commands:
{commands}
"""
```

### Option 2: Separate System and User Preferences

```python
# STATIC GLOBAL (cached for all users)
base_system = """
You manage SmartTodo tasks strictly through the provided function-call tools. Follow these rules:
[... 6 rules ...]
"""

# STATIC PER-USER (cached per user, as first message)
user_context_message = {
  "role": "user",
  "content": f"User preferences:\n{user_preferences}"
}

# DYNAMIC (new for each request)
request_message = {
  "role": "user",
  "content": f"User request: {user_text}\n{state_snapshot}"
}
```

## Implementation Notes

### Current Files

- **System prompt construction**: `lib/smart_todo/agent/llm_session.ex:765-781`
- **Payload building**: `lib/smart_todo/agent/llm_session.ex:95-104`
- **Message formatting**: `lib/smart_todo/agent/llm_session.ex:646-672`
- **State rendering**: `lib/smart_todo/agent/llm_session.ex:675-763`
- **OpenAI adapter**: `lib/smart_todo/agent/llama_cpp_adapter.ex:54-85`

### Configuration

- **Model**: Default `qwen2.5-3b-instruct` (configurable via `LLAMA_CPP_MODEL`)
- **Base URL**: Default `https://llama-cpp.rackspace.koski.co` (configurable via `LLM_BASE_URL`)
- **Cache prompt**: Already set to `true` in adapter
- **Temperature**: `0.7`
- **Max tokens**: `2048`
- **Tool choice**: `auto` (configurable via `LLAMA_CPP_TOOL_CHOICE`)

## Recommendations

The current implementation is **already well-optimized** for prompt caching:

1. ✅ Static content (system rules + user prefs) is in `systemInstruction`
2. ✅ Dynamic content (state, commands) is in `contents`
3. ✅ `cache_prompt: true` is already enabled
4. ✅ System message comes first in OpenAI translation

**No changes are needed** unless:
- You want to separate user preferences from the base system message
- You want to add additional static context that could be cached
- You need finer-grained cache control (e.g., per-session vs per-user)

## Example Full Request (OpenAI Format)

```json
{
  "model": "qwen2.5-3b-instruct",
  "messages": [
    {
      "role": "system",
      "content": "You manage SmartTodo tasks strictly through the provided function-call tools. Follow these rules:\n1. Every reply MUST be exactly one function call defined in `available_commands`.\n2. Read the state snapshot each turn; `available_commands` is the source of truth for what you can call.\n3. To change, complete, or delete an existing task you MUST call `select_task` first. Once a task is selected, the editing commands (update, complete, delete, exit_editing) become available. If you are not editing, those commands are unavailable.\n4. New tasks are staged with `create_task`; existing tasks accumulate staged changes until you `complete_session` (commit) or `discard_all`.\n5. Whenever solving the request requires more than one command, call `record_plan` first to capture the steps you intend to take.\n6. `complete_session` MUST be the final command you ever issue in a session; after calling it you may not send any further commands.\n\nUser preferences:\n{optional user preferences text}"
    },
    {
      "role": "user",
      "content": "User request: Add a task to buy groceries\nSession message: Session started. Use record_plan if the request requires multiple commands.\nState: initial\nError?: false\nOpen tasks:\n- none\nPending operations:\n- none\nRecorded plans:\n- none\nAvailable commands:\n- create_task: Stage a new task with title, description, status, etc. | params: {...}\n- record_plan: Record your intended sequence of commands | params: {...}\n- complete_session: Mark all operations ready and exit | params: {}"
    }
  ],
  "tools": [...],
  "tool_choice": "auto",
  "temperature": 0.7,
  "max_tokens": 2048,
  "cache_prompt": true
}
```

In this structure, the system message (everything up to and including user preferences) will be cached, and only the dynamic content in subsequent messages will be processed fresh on each request.
