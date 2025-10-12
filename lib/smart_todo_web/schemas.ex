defmodule SmartTodoWeb.Schemas do
  @moduledoc """
  OpenAPI schemas for API request and response objects.
  """

  alias OpenApiSpex.Schema

  defmodule Task do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "Task",
      description: "A task item",
      type: :object,
      properties: %{
        id: %Schema{type: :integer, description: "Task ID", readOnly: true},
        title: %Schema{type: :string, description: "Task title", maxLength: 200},
        description: %Schema{type: :string, description: "Detailed description", nullable: true, maxLength: 10_000},
        status: %Schema{type: :string, description: "Current status", enum: [:todo, :in_progress, :done], default: :todo},
        urgency: %Schema{type: :string, description: "Priority level", enum: [:low, :normal, :high, :critical], default: :normal},
        due_date: %Schema{type: :string, format: :date, description: "Due date (YYYY-MM-DD)", nullable: true},
        recurrence: %Schema{type: :string, description: "Recurrence pattern", enum: [:none, :daily, :weekly, :monthly, :yearly], default: :none},
        deferred_until: %Schema{type: :string, format: :date, description: "Defer until date (YYYY-MM-DD)", nullable: true},
        notes: %Schema{type: :string, description: "Additional notes", nullable: true, maxLength: 10_000},
        user_id: %Schema{type: :integer, description: "Task owner ID", readOnly: true},
        assignee_id: %Schema{type: :integer, description: "Assigned user ID", nullable: true},
        assigned_group_id: %Schema{type: :integer, description: "Assigned group ID", nullable: true},
        prerequisites: %Schema{
          type: :array,
          description: "Prerequisite tasks",
          items: %Schema{
            type: :object,
            properties: %{
              id: %Schema{type: :integer},
              title: %Schema{type: :string},
              status: %Schema{type: :string, enum: [:todo, :in_progress, :done]}
            }
          },
          readOnly: true
        },
        dependents: %Schema{
          type: :array,
          description: "Dependent tasks",
          items: %Schema{
            type: :object,
            properties: %{
              id: %Schema{type: :integer},
              title: %Schema{type: :string},
              status: %Schema{type: :string, enum: [:todo, :in_progress, :done]}
            }
          },
          readOnly: true
        },
        inserted_at: %Schema{type: :string, format: :"date-time", description: "Creation timestamp", readOnly: true},
        updated_at: %Schema{type: :string, format: :"date-time", description: "Last update timestamp", readOnly: true}
      },
      required: [:title],
      example: %{
        id: 1,
        title: "Complete API documentation",
        description: "Write comprehensive API docs",
        status: "in_progress",
        urgency: "high",
        due_date: "2025-10-15",
        recurrence: "none",
        deferred_until: nil,
        notes: "Include examples for all endpoints",
        user_id: 1,
        assignee_id: 1,
        assigned_group_id: nil,
        prerequisites: [],
        dependents: [],
        inserted_at: "2025-10-09T12:00:00Z",
        updated_at: "2025-10-09T12:00:00Z"
      }
    })
  end

  defmodule TaskRequest do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "TaskRequest",
      description: "Request body for creating or updating a task",
      type: :object,
      properties: %{
        task: %Schema{
          type: :object,
          properties: %{
            title: %Schema{type: :string, description: "Task title", maxLength: 200},
            description: %Schema{type: :string, description: "Detailed description", nullable: true, maxLength: 10_000},
            status: %Schema{type: :string, description: "Current status", enum: [:todo, :in_progress, :done]},
            urgency: %Schema{type: :string, description: "Priority level", enum: [:low, :normal, :high, :critical]},
            due_date: %Schema{type: :string, format: :date, description: "Due date (YYYY-MM-DD)", nullable: true},
            recurrence: %Schema{type: :string, description: "Recurrence pattern", enum: [:none, :daily, :weekly, :monthly, :yearly]},
            deferred_until: %Schema{type: :string, format: :date, description: "Defer until date (YYYY-MM-DD)", nullable: true},
            notes: %Schema{type: :string, description: "Additional notes", nullable: true, maxLength: 10_000},
            assignee_id: %Schema{type: :integer, description: "Assigned user ID", nullable: true},
            assigned_group_id: %Schema{type: :integer, description: "Assigned group ID", nullable: true},
            prerequisite_ids: %Schema{
              type: :array,
              description: "IDs of tasks that must be completed first",
              items: %Schema{type: :integer},
              nullable: true
            }
          }
        }
      },
      required: [:task],
      example: %{
        task: %{
          title: "New task",
          description: "Task description",
          urgency: "high",
          due_date: "2025-10-20",
          prerequisite_ids: [2, 3]
        }
      }
    })
  end

  defmodule TaskResponse do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "TaskResponse",
      description: "Response containing a single task",
      type: :object,
      properties: %{
        data: Task
      },
      example: %{
        data: %{
          id: 1,
          title: "Complete API documentation",
          description: "Write comprehensive API docs",
          status: "in_progress",
          urgency: "high",
          due_date: "2025-10-15",
          recurrence: "none",
          deferred_until: nil,
          notes: "Include examples for all endpoints",
          user_id: 1,
          assignee_id: 1,
          assigned_group_id: nil,
          prerequisites: [],
          dependents: [],
          inserted_at: "2025-10-09T12:00:00Z",
          updated_at: "2025-10-09T12:00:00Z"
        }
      }
    })
  end

  defmodule TasksResponse do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "TasksResponse",
      description: "Response containing a list of tasks",
      type: :object,
      properties: %{
        data: %Schema{type: :array, items: Task}
      },
      example: %{
        data: [
          %{
            id: 1,
            title: "Complete API documentation",
            description: "Write comprehensive API docs",
            status: "in_progress",
            urgency: "high",
            due_date: "2025-10-15",
            recurrence: "none",
            deferred_until: nil,
            notes: nil,
            user_id: 1,
            assignee_id: 1,
            assigned_group_id: nil,
            prerequisites: [],
            dependents: [],
            inserted_at: "2025-10-09T12:00:00Z",
            updated_at: "2025-10-09T12:00:00Z"
          }
        ]
      }
    })
  end

  defmodule ErrorResponse do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "ErrorResponse",
      description: "Error response",
      type: :object,
      properties: %{
        errors: %Schema{
          type: :object,
          description: "Error details",
          additionalProperties: %Schema{
            oneOf: [
              %Schema{type: :string},
              %Schema{type: :array, items: %Schema{type: :string}}
            ]
          }
        }
      },
      example: %{
        errors: %{
          title: ["can't be blank"]
        }
      }
    })
  end

  defmodule UnauthorizedResponse do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "UnauthorizedResponse",
      description: "Unauthorized error response",
      type: :object,
      properties: %{
        errors: %Schema{
          type: :object,
          properties: %{
            detail: %Schema{type: :string}
          }
        }
      },
      example: %{
        errors: %{
          detail: "Unauthorized"
        }
      }
    })
  end

  defmodule NaturalLanguageRequest do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "NaturalLanguageRequest",
      description: "Request to process natural language text and perform task operations",
      type: :object,
      properties: %{
        text: %Schema{
          type: :string,
          description: "Natural language text describing the task operations to perform",
          minLength: 1,
          maxLength: 5000
        }
      },
      required: [:text],
      example: %{
        text: "Create a task to review the quarterly report with high urgency and due date next Friday"
      }
    })
  end

  defmodule ActionPerformed do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "ActionPerformed",
      description: "An action that was performed by the natural language processor",
      type: :object,
      properties: %{
        name: %Schema{type: :string, description: "Name of the command that was executed"},
        params: %Schema{
          type: :object,
          description: "Parameters that were passed to the command",
          additionalProperties: true
        }
      },
      example: %{
        name: "create_task",
        params: %{
          title: "Review quarterly report",
          urgency: "high",
          due_date: "2025-10-19"
        }
      }
    })
  end

  defmodule NaturalLanguageResponse do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "NaturalLanguageResponse",
      description: "Response from processing natural language text",
      type: :object,
      properties: %{
        actions: %Schema{
          type: :array,
          description: "List of actions that were performed",
          items: ActionPerformed
        },
        message: %Schema{
          type: :string,
          description: "Summary message of the operation"
        }
      },
      example: %{
        actions: [
          %{
            name: "create_task",
            params: %{
              title: "Review quarterly report",
              urgency: "high",
              due_date: "2025-10-19"
            }
          },
          %{
            name: "complete_session",
            params: %{}
          }
        ],
        message: "Successfully processed your request and created 1 task"
      }
    })
  end
end
