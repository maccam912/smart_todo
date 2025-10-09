# SmartTodo REST API Documentation

This document describes the REST API endpoints for managing tasks in SmartTodo.

## Interactive API Documentation

**Swagger UI is available at `/swaggerui`**

Visit `http://localhost:4000/swaggerui` in your browser to access the interactive API documentation where you can:
- Browse all API endpoints with detailed descriptions
- View request/response schemas with examples
- Try out API calls directly from your browser
- Test authentication with your API token

The OpenAPI specification is also available in JSON format at `/api/openapi`.

## Authentication

All API endpoints require authentication using a Bearer token. You can generate an API token from the user settings page in the web interface.

Include the token in the `Authorization` header of your requests:

```
Authorization: Bearer <your-token-here>
```

If authentication fails, the API will return a `401 Unauthorized` response.

## Base URL

All endpoints are prefixed with `/api`.

## Endpoints

### List Tasks

**GET** `/api/tasks`

Lists all tasks accessible by the authenticated user (owned, assigned, or group-assigned tasks).

**Query Parameters:**
- `status` (optional): Filter by status. Valid values: `todo`, `in_progress`, `done`

**Example Request:**
```bash
curl -H "Authorization: Bearer YOUR_TOKEN" \
  http://localhost:4000/api/tasks

# Filter by status
curl -H "Authorization: Bearer YOUR_TOKEN" \
  http://localhost:4000/api/tasks?status=todo
```

**Example Response:**
```json
{
  "data": [
    {
      "id": 1,
      "title": "Complete API documentation",
      "description": "Write comprehensive API docs",
      "status": "in_progress",
      "urgency": "high",
      "due_date": "2025-10-15",
      "recurrence": "none",
      "deferred_until": null,
      "notes": "Include examples for all endpoints",
      "user_id": 1,
      "assignee_id": 1,
      "assigned_group_id": null,
      "prerequisites": [],
      "dependents": [],
      "inserted_at": "2025-10-09T12:00:00Z",
      "updated_at": "2025-10-09T12:00:00Z"
    }
  ]
}
```

### Get Task

**GET** `/api/tasks/:id`

Retrieves a single task by ID. The task must be owned by or assigned to the authenticated user.

**Example Request:**
```bash
curl -H "Authorization: Bearer YOUR_TOKEN" \
  http://localhost:4000/api/tasks/1
```

**Example Response:**
```json
{
  "data": {
    "id": 1,
    "title": "Complete API documentation",
    "description": "Write comprehensive API docs",
    "status": "in_progress",
    "urgency": "high",
    "due_date": "2025-10-15",
    "recurrence": "none",
    "deferred_until": null,
    "notes": "Include examples for all endpoints",
    "user_id": 1,
    "assignee_id": 1,
    "assigned_group_id": null,
    "prerequisites": [
      {
        "id": 2,
        "title": "Create API endpoints",
        "status": "done"
      }
    ],
    "dependents": [],
    "inserted_at": "2025-10-09T12:00:00Z",
    "updated_at": "2025-10-09T12:00:00Z"
  }
}
```

### Create Task

**POST** `/api/tasks`

Creates a new task for the authenticated user.

**Request Body:**
```json
{
  "task": {
    "title": "New task title",
    "description": "Optional description",
    "status": "todo",
    "urgency": "normal",
    "due_date": "2025-10-20",
    "recurrence": "none",
    "notes": "Optional notes",
    "prerequisite_ids": [2, 3]
  }
}
```

**Field Descriptions:**
- `title` (required, string, max 200 chars): Task title
- `description` (optional, string, max 10,000 chars): Detailed description
- `status` (optional, enum): One of `todo`, `in_progress`, `done`. Defaults to `todo`
- `urgency` (optional, enum): One of `low`, `normal`, `high`, `critical`. Defaults to `normal`
- `due_date` (optional, date): Due date in ISO 8601 format (YYYY-MM-DD)
- `recurrence` (optional, enum): One of `none`, `daily`, `weekly`, `monthly`, `yearly`. Defaults to `none`
- `deferred_until` (optional, date): Date to defer task until
- `notes` (optional, string, max 10,000 chars): Additional notes
- `assignee_id` (optional, integer): User ID to assign task to
- `assigned_group_id` (optional, integer): Group ID to assign task to
- `prerequisite_ids` (optional, array of integers): IDs of tasks that must be completed first

**Note:** Tasks cannot be assigned to both a user and a group simultaneously. If neither `assignee_id` nor `assigned_group_id` is specified, the task is assigned to the creator by default.

**Example Request:**
```bash
curl -X POST \
  -H "Authorization: Bearer YOUR_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"task": {"title": "New task", "urgency": "high"}}' \
  http://localhost:4000/api/tasks
```

**Example Response:**
```json
{
  "data": {
    "id": 5,
    "title": "New task",
    "description": null,
    "status": "todo",
    "urgency": "high",
    "due_date": null,
    "recurrence": "none",
    "deferred_until": null,
    "notes": null,
    "user_id": 1,
    "assignee_id": 1,
    "assigned_group_id": null,
    "prerequisites": [],
    "dependents": [],
    "inserted_at": "2025-10-09T13:00:00Z",
    "updated_at": "2025-10-09T13:00:00Z"
  }
}
```

**Status Code:** `201 Created`

### Update Task

**PUT** `/api/tasks/:id`

Updates an existing task. Only the task owner can update it.

**Request Body:**
```json
{
  "task": {
    "title": "Updated title",
    "status": "in_progress",
    "urgency": "critical",
    "prerequisite_ids": [2]
  }
}
```

All fields are optional. Only include the fields you want to update.

**Example Request:**
```bash
curl -X PUT \
  -H "Authorization: Bearer YOUR_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"task": {"status": "in_progress"}}' \
  http://localhost:4000/api/tasks/5
```

**Example Response:**
```json
{
  "data": {
    "id": 5,
    "title": "New task",
    "status": "in_progress",
    "urgency": "high",
    ...
  }
}
```

**Status Code:** `200 OK`

### Delete Task

**DELETE** `/api/tasks/:id`

Deletes a task. Only the task owner can delete it.

**Example Request:**
```bash
curl -X DELETE \
  -H "Authorization: Bearer YOUR_TOKEN" \
  http://localhost:4000/api/tasks/5
```

**Status Code:** `204 No Content`

### Complete Task

**POST** `/api/tasks/:id/complete`

Marks a task as complete. This endpoint validates that all prerequisites are completed before allowing the task to be marked as done. If the task has a recurrence setting, a new task will be created automatically with the next due date.

**Example Request:**
```bash
curl -X POST \
  -H "Authorization: Bearer YOUR_TOKEN" \
  http://localhost:4000/api/tasks/1/complete
```

**Example Response:**
```json
{
  "data": {
    "id": 1,
    "title": "Complete API documentation",
    "status": "done",
    ...
  }
}
```

**Status Code:** `200 OK`

**Error Response (prerequisites not complete):**
```json
{
  "errors": {
    "status": ["cannot complete: has incomplete prerequisites"]
  }
}
```

**Status Code:** `422 Unprocessable Entity`

## Error Responses

### 401 Unauthorized

Returned when the bearer token is missing, invalid, or expired.

```json
{
  "errors": {
    "detail": "Unauthorized"
  }
}
```

### 404 Not Found

Returned when a task with the given ID doesn't exist or doesn't belong to the authenticated user.

```json
{
  "errors": {
    "detail": "Not Found"
  }
}
```

### 422 Unprocessable Entity

Returned when validation fails (e.g., missing required fields, invalid values).

```json
{
  "errors": {
    "title": ["can't be blank"],
    "urgency": ["is invalid"]
  }
}
```

## Task Field Reference

| Field | Type | Description | Constraints |
|-------|------|-------------|-------------|
| `id` | integer | Unique task identifier | Read-only |
| `title` | string | Task title | Required, max 200 chars |
| `description` | string | Detailed description | Optional, max 10,000 chars |
| `status` | enum | Current status | `todo`, `in_progress`, `done` |
| `urgency` | enum | Priority level | `low`, `normal`, `high`, `critical` |
| `due_date` | date | Due date | Optional, ISO 8601 format |
| `recurrence` | enum | Recurrence pattern | `none`, `daily`, `weekly`, `monthly`, `yearly` |
| `deferred_until` | date | Defer until date | Optional, ISO 8601 format |
| `notes` | string | Additional notes | Optional, max 10,000 chars |
| `user_id` | integer | Task owner | Read-only, set on creation |
| `assignee_id` | integer | Assigned user | Optional, mutually exclusive with `assigned_group_id` |
| `assigned_group_id` | integer | Assigned group | Optional, mutually exclusive with `assignee_id` |
| `prerequisites` | array | Prerequisite tasks | Array of task objects with `id`, `title`, `status` |
| `dependents` | array | Dependent tasks | Array of task objects with `id`, `title`, `status` |
| `inserted_at` | datetime | Creation timestamp | Read-only, ISO 8601 format |
| `updated_at` | datetime | Last update timestamp | Read-only, ISO 8601 format |

## Getting Started

1. **Generate an API Token:**
   - Log in to the SmartTodo web interface
   - Navigate to Settings
   - Generate a new API token
   - Copy the token (it will only be shown once)

2. **Test the API:**
   ```bash
   # List your tasks
   curl -H "Authorization: Bearer YOUR_TOKEN" \
     http://localhost:4000/api/tasks

   # Create a new task
   curl -X POST \
     -H "Authorization: Bearer YOUR_TOKEN" \
     -H "Content-Type: application/json" \
     -d '{"task": {"title": "Test task", "urgency": "high"}}' \
     http://localhost:4000/api/tasks
   ```

## Rate Limiting

Currently, there are no rate limits imposed on API requests. This may change in future versions.

## API Versioning

The current API version is v1. Future versions will be accessible via versioned endpoints (e.g., `/api/v2/tasks`).
