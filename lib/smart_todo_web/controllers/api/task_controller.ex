defmodule SmartTodoWeb.Api.TaskController do
  use SmartTodoWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias SmartTodo.Tasks
  alias SmartTodo.Agent.LlmSession
  alias SmartTodoWeb.Schemas
  alias OpenApiSpex.Schema

  require Logger

  action_fallback SmartTodoWeb.FallbackController

  tags ["Tasks"]

  operation :index,
    summary: "List tasks",
    description: "Lists all tasks accessible by the authenticated user (owned, assigned, or group-assigned tasks)",
    parameters: [
      status: [
        in: :query,
        description: "Filter by task status",
        schema: %Schema{type: :string, enum: [:todo, :in_progress, :done]},
        required: false
      ]
    ],
    responses: [
      ok: {"Tasks retrieved successfully", "application/json", Schemas.TasksResponse},
      unauthorized: {"Unauthorized", "application/json", Schemas.UnauthorizedResponse}
    ]

  def index(conn, params) do
    current_scope = conn.assigns[:current_scope]
    opts = if status = params["status"], do: [status: String.to_existing_atom(status)], else: []
    tasks = Tasks.list_tasks(current_scope, opts)
    render(conn, :index, tasks: tasks)
  end

  operation :show,
    summary: "Get a task",
    description: "Retrieves a single task by ID. The task must be owned by or assigned to the authenticated user.",
    parameters: [
      id: [in: :path, description: "Task ID", type: :integer, example: 1]
    ],
    responses: [
      ok: {"Task retrieved successfully", "application/json", Schemas.TaskResponse},
      not_found: {"Task not found", "application/json", Schemas.ErrorResponse},
      unauthorized: {"Unauthorized", "application/json", Schemas.UnauthorizedResponse}
    ]

  def show(conn, %{"id" => id}) do
    current_scope = conn.assigns[:current_scope]
    task = Tasks.get_task!(current_scope, String.to_integer(id))
    render(conn, :show, task: task)
  end

  operation :create,
    summary: "Create a task",
    description: "Creates a new task for the authenticated user. If neither assignee_id nor assigned_group_id is specified, the task is assigned to the creator by default.",
    request_body: {"Task parameters", "application/json", Schemas.TaskRequest, required: true},
    responses: [
      created: {"Task created successfully", "application/json", Schemas.TaskResponse},
      unprocessable_entity: {"Validation error", "application/json", Schemas.ErrorResponse},
      unauthorized: {"Unauthorized", "application/json", Schemas.UnauthorizedResponse}
    ]

  def create(conn, %{"task" => task_params}) do
    current_scope = conn.assigns[:current_scope]

    case Tasks.create_task(current_scope, task_params) do
      {:ok, task} ->
        conn
        |> put_status(:created)
        |> put_resp_header("location", ~p"/api/tasks/#{task.id}")
        |> render(:show, task: task)

      {:error, %Ecto.Changeset{} = changeset} ->
        {:error, changeset}
    end
  end

  operation :update,
    summary: "Update a task",
    description: "Updates an existing task. Only the task owner can update it. All fields are optional - only include the fields you want to update.",
    parameters: [
      id: [in: :path, description: "Task ID", type: :integer, example: 1]
    ],
    request_body: {"Task parameters", "application/json", Schemas.TaskRequest, required: true},
    responses: [
      ok: {"Task updated successfully", "application/json", Schemas.TaskResponse},
      not_found: {"Task not found", "application/json", Schemas.ErrorResponse},
      unprocessable_entity: {"Validation error", "application/json", Schemas.ErrorResponse},
      unauthorized: {"Unauthorized", "application/json", Schemas.UnauthorizedResponse}
    ]

  def update(conn, %{"id" => id, "task" => task_params}) do
    current_scope = conn.assigns[:current_scope]
    task = Tasks.get_task!(current_scope, String.to_integer(id))

    case Tasks.update_task(current_scope, task, task_params) do
      {:ok, task} ->
        render(conn, :show, task: task)

      {:error, %Ecto.Changeset{} = changeset} ->
        {:error, changeset}
    end
  end

  operation :delete,
    summary: "Delete a task",
    description: "Deletes a task. Only the task owner can delete it. This also removes all associated dependencies.",
    parameters: [
      id: [in: :path, description: "Task ID", type: :integer, example: 1]
    ],
    responses: [
      no_content: "Task deleted successfully",
      not_found: {"Task not found", "application/json", Schemas.ErrorResponse},
      unauthorized: {"Unauthorized", "application/json", Schemas.UnauthorizedResponse}
    ]

  def delete(conn, %{"id" => id}) do
    current_scope = conn.assigns[:current_scope]
    task = Tasks.get_task!(current_scope, String.to_integer(id))

    case Tasks.delete_task(current_scope, task) do
      {:ok, _task} ->
        send_resp(conn, :no_content, "")

      {:error, %Ecto.Changeset{} = changeset} ->
        {:error, changeset}
    end
  end

  operation :complete,
    summary: "Complete a task",
    description: "Marks a task as complete. Validates that all prerequisites are completed before allowing the task to be marked as done. If the task has a recurrence setting, a new task will be created automatically with the next due date.",
    parameters: [
      id: [in: :path, description: "Task ID", type: :integer, example: 1]
    ],
    responses: [
      ok: {"Task completed successfully", "application/json", Schemas.TaskResponse},
      not_found: {"Task not found", "application/json", Schemas.ErrorResponse},
      unprocessable_entity: {"Prerequisites not complete", "application/json", Schemas.ErrorResponse},
      unauthorized: {"Unauthorized", "application/json", Schemas.UnauthorizedResponse}
    ]

  def complete(conn, %{"id" => id}) do
    current_scope = conn.assigns[:current_scope]
    task = Tasks.get_task!(current_scope, String.to_integer(id))

    case Tasks.complete_task(current_scope, task) do
      {:ok, task} ->
        render(conn, :show, task: task)

      {:error, %Ecto.Changeset{} = changeset} ->
        {:error, changeset}
    end
  end

  operation :process_natural_language,
    summary: "Process natural language text",
    description: """
    Processes natural language text to perform task operations using an AI assistant.
    The AI will interpret your request and execute the appropriate commands to create,
    update, complete, or delete tasks. Returns a list of all actions that were performed.

    Examples:
    - "Create a task to review the quarterly report with high urgency"
    - "Mark the task 'Buy groceries' as complete"
    - "Break down the task 'Launch new website' into smaller steps"
    """,
    request_body: {"Natural language request", "application/json", Schemas.NaturalLanguageRequest, required: true},
    responses: [
      ok: {"Natural language processed successfully", "application/json", Schemas.NaturalLanguageResponse},
      unprocessable_entity: {"Processing error", "application/json", Schemas.ErrorResponse},
      unauthorized: {"Unauthorized", "application/json", Schemas.UnauthorizedResponse}
    ]

  def process_natural_language(conn, %{"text" => text}) when is_binary(text) do
    current_scope = conn.assigns[:current_scope]

    case String.trim(text) do
      "" ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{errors: %{text: ["cannot be blank"]}})

      trimmed_text ->
        case LlmSession.run(current_scope, trimmed_text) do
          {:ok, result} ->
            actions = Map.get(result, :executed, [])
            render(conn, :natural_language, actions: actions)

          {:error, reason, _context} ->
            Logger.error("Natural language processing failed: #{inspect(reason)}")

            error_message = format_llm_error(reason)

            conn
            |> put_status(:unprocessable_entity)
            |> json(%{errors: %{processing: [error_message]}})
        end
    end
  end

  def process_natural_language(conn, _params) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{errors: %{text: ["is required"]}})
  end

  defp format_llm_error(:max_rounds), do: "Processing stopped after reaching maximum rounds"
  defp format_llm_error(:max_errors), do: "Processing stopped due to too many errors"
  defp format_llm_error({:http_error, status, _}), do: "HTTP error: #{status}"
  defp format_llm_error({:unsupported_command, name}), do: "Unsupported command: #{name}"
  defp format_llm_error(reason) when is_atom(reason), do: Phoenix.Naming.humanize(reason)
  defp format_llm_error(reason), do: "Processing failed: #{inspect(reason)}"
end
