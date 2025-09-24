defmodule SmartTodo.Tasks.Task do
  use Ecto.Schema
  import Ecto.Changeset

  alias SmartTodo.Accounts.User
  alias SmartTodo.Tasks.{Task, TaskDependency}

  @moduledoc """
  Represents a work item. Tasks belong to a user (owner) and can have
  self-referential prerequisites/dependents.
  """

  @type t :: %__MODULE__{}

  @status_values [:todo, :in_progress, :done]
  @urgency_values [:low, :normal, :high, :critical]
  @recurrence_values [:none, :daily, :weekly, :monthly, :yearly]

  schema "tasks" do
    belongs_to :user, User
    belongs_to :assignee, User

    field :title, :string
    # Database column is :text, but schema uses :string per project guideline
    field :description, :string
    field :status, Ecto.Enum, values: @status_values, default: :todo
    field :urgency, Ecto.Enum, values: @urgency_values, default: :normal
    field :due_date, :date
    field :recurrence, Ecto.Enum, values: @recurrence_values, default: :none

    has_many :prerequisite_links, TaskDependency, foreign_key: :blocked_task_id
    has_many :prerequisites, through: [:prerequisite_links, :prereq]

    has_many :dependent_links, TaskDependency, foreign_key: :prereq_task_id
    has_many :dependents, through: [:dependent_links, :blocked]

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(%Task{} = task, attrs) do
    task
    |> cast(attrs, [:title, :description, :status, :urgency, :due_date, :recurrence])
    |> validate_required([:title])
    |> validate_length(:title, max: 200)
    |> validate_length(:description, max: 10_000)
  end

  @doc """
  Validate completion according to prerequisites when moving to :done.
  Assumes `:prerequisites` are preloaded when needed.
  """
  def validate_can_complete(changeset, prerequisites_done?) do
    case get_change(changeset, :status) do
      :done ->
        if prerequisites_done? do
          changeset
        else
          add_error(changeset, :status, "cannot complete: has incomplete prerequisites")
        end

      _ ->
        changeset
    end
  end

  def status_values, do: @status_values
  def urgency_values, do: @urgency_values
  def recurrence_values, do: @recurrence_values
end
