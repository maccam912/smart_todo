defmodule SmartTodo.Agent.StateMachine do
  @moduledoc """
  Conversational state machine that guides an LLM through staged task commands.

  The machine exposes discrete commands that can be invoked one at a time, always
  returning the next available options plus a preview of the user's open tasks
  (tasks whose status is not `:done`). Pending operations are accumulated and
  executed inside a single database transaction when `:complete_session` is
  invoked; any error rolls the transaction back and keeps the session active.
  """

  alias Ecto.Changeset
  alias SmartTodo.Accounts.Scope
  alias SmartTodo.Repo
  alias SmartTodo.Tasks

  @enforce_keys [:current_scope]
  defstruct current_scope: nil,
            state: :awaiting_command,
            pending_ops: [],
            edit_context: nil,
            next_pending_ref: 1,
            plan_notes: []

  @type target :: {:existing, integer()} | {:pending, integer()}
  @type pending_op ::
          %{type: :create_task, target: {:pending, integer()}, attrs: map()}
          | %{type: :update_task, target: target(), attrs: map()}
          | %{type: :delete_task, target: target(), attrs: map()}
          | %{type: :complete_task, target: target(), attrs: map()}
  @type edit_context :: %{target: target(), staged: map()}
  @type plan_note :: %{plan: String.t(), steps: [String.t()]}
  @type state :: :awaiting_command | {:editing_task, target()} | :completed

  @type t :: %__MODULE__{
          current_scope: Scope.t() | nil,
          state: state(),
          pending_ops: [pending_op()],
          edit_context: edit_context() | nil,
          next_pending_ref: pos_integer(),
          plan_notes: [plan_note()]
        }

  @type command ::
          :select_task
          | :create_task
          | :update_task_fields
          | :delete_task
          | :complete_task
          | :exit_editing
          | :discard_all
          | :complete_session
          | :record_plan

  @allowed_fields ~w(title description status urgency due_date recurrence assignee_id prerequisite_ids)a

  @doc """
  Starts a new session bound to the given scope.
  """
  @spec start_session(Scope.t() | nil) :: {t(), map()}
  def start_session(scope) do
    machine = %__MODULE__{current_scope: scope}
    {machine, build_response(machine, "Session started. Awaiting command.")}
  end

  @doc """
  Applies a single command against the machine.
  """
  @spec handle_command(t(), command(), map()) :: {:ok, t(), map()} | {:error, t(), map()}
  def handle_command(machine, command, params \\ %{})

  def handle_command(%__MODULE__{state: :completed} = machine, _command, _params) do
    {:error, machine,
     build_response(machine, "Session already completed. Restart to issue commands.",
       error?: true
     )}
  end

  def handle_command(%__MODULE__{} = machine, command, params) when is_map(params) do
    case do_handle(machine, command, params) do
      {:ok, updated, message} ->
        {:ok, updated, build_response(updated, message)}

      {:error, message} ->
        {:error, machine, build_response(machine, message, error?: true)}
    end
  end

  def handle_command(machine, _command, _params) do
    {:error, machine,
     build_response(machine, "Command parameters must be provided as a map.", error?: true)}
  end

  # Command handlers

  defp do_handle(machine, :select_task, params) do
    with {:ok, target} <- resolve_target_param(machine, params),
         :ok <- ensure_selectable(machine, target) do
      new_machine = %{
        machine
        | state: {:editing_task, target},
          edit_context: %{target: target, staged: %{}}
      }

      {:ok, new_machine, "Editing started."}
    else
      {:error, message} -> {:error, message}
    end
  end

  defp do_handle(machine, :create_task, params) do
    case normalize_task_attrs(params) do
      {:ok, attrs} ->
        case Map.get(attrs, :title) do
          title when title in [nil, ""] ->
            {:error, "Creating a task requires at least a title."}

          _title ->
            {machine, ref} = stage_create(machine, attrs)
            {:ok, machine, "Task creation staged with pending_ref #{ref}."}
        end

      {:error, message} ->
        {:error, message}
    end
  end

  defp do_handle(
         %__MODULE__{state: {:editing_task, target}} = machine,
         :update_task_fields,
         params
       ) do
    case normalize_task_attrs(params) do
      {:ok, attrs} when map_size(attrs) > 0 ->
        case stage_update(machine, target, attrs) do
          {:ok, machine} -> {:ok, machine, "Field changes staged."}
          {:error, message} -> {:error, message}
        end

      {:ok, _} ->
        {:error, "No recognized task fields provided."}

      {:error, message} ->
        {:error, message}
    end
  end

  defp do_handle(%__MODULE__{state: :awaiting_command}, :update_task_fields, _params) do
    {:error, "Select a task before updating its fields."}
  end

  defp do_handle(%__MODULE__{state: {:editing_task, target}} = machine, :delete_task, _params) do
    case stage_delete(machine, target) do
      {:ok, updated, message} -> {:ok, clear_editing(updated), message}
      {:error, message} -> {:error, message}
    end
  end

  defp do_handle(%__MODULE__{state: :awaiting_command}, :delete_task, _params) do
    {:error, "Select a task before deleting it."}
  end

  defp do_handle(%__MODULE__{state: {:editing_task, target}} = machine, :complete_task, _params) do
    case stage_complete(machine, target) do
      {:ok, machine, message} -> {:ok, machine, message}
      {:error, message} -> {:error, message}
    end
  end

  defp do_handle(%__MODULE__{state: :awaiting_command}, :complete_task, _params) do
    {:error, "Select a task before marking it complete."}
  end

  defp do_handle(%__MODULE__{state: {:editing_task, _}} = machine, :exit_editing, _params) do
    {:ok, clear_editing(machine), "Exited editing mode."}
  end

  defp do_handle(%__MODULE__{state: :awaiting_command}, :exit_editing, _params) do
    {:error, "Not currently editing a task."}
  end

  defp do_handle(machine, :discard_all, _params) do
    updated = %{machine | pending_ops: [], edit_context: nil, state: :awaiting_command}
    {:ok, updated, "Pending operations discarded."}
  end

  defp do_handle(machine, :complete_session, _params) do
    case persist_pending_ops(machine) do
      {:noop, updated} ->
        {:ok, updated, "Nothing to commit. Session closed."}

      {:ok, updated, summary} ->
        {:ok, updated, commit_message(summary)}

      {:error, message} ->
        {:error, message}
    end
  end

  defp do_handle(machine, :record_plan, params) do
    case normalize_plan(params) do
      {:ok, plan_note} ->
        updated = %{machine | plan_notes: machine.plan_notes ++ [plan_note]}
        {:ok, updated, "Plan recorded for reference."}

      {:error, message} ->
        {:error, message}
    end
  end

  defp do_handle(_machine, command, _params) do
    {:error, "Unsupported command: #{inspect(command)}."}
  end

  # Command helpers

  defp stage_create(%__MODULE__{pending_ops: ops, next_pending_ref: ref} = machine, attrs) do
    op = %{type: :create_task, target: {:pending, ref}, attrs: attrs}
    {%{machine | pending_ops: ops ++ [op], next_pending_ref: ref + 1}, ref}
  end

  defp stage_update(machine, {:pending, _} = target, attrs) do
    with {:ok, machine} <- merge_into_pending_create(machine, target, attrs) do
      {:ok, update_edit_context(machine, target, attrs)}
    end
  end

  defp stage_update(machine, target, attrs) do
    machine =
      machine
      |> replace_update_op(target, attrs)
      |> update_edit_context(target, attrs)

    {:ok, machine}
  end

  defp merge_into_pending_create(%__MODULE__{pending_ops: ops} = machine, target, attrs) do
    {updated_ops, found?} =
      Enum.reduce(ops, {[], false}, fn
        %{type: :create_task, target: ^target, attrs: existing} = op, {acc, _found?} ->
          updated = %{op | attrs: Map.merge(existing, attrs)}
          {[updated | acc], true}

        %{target: ^target, type: :update_task}, {acc, found?} ->
          {acc, found?}

        op, {acc, found?} ->
          {[op | acc], found?}
      end)

    case found? do
      true ->
        {:ok, %{machine | pending_ops: Enum.reverse(updated_ops)}}

      false ->
        {:error, "Pending task not found for update."}
    end
  end

  defp replace_update_op(%__MODULE__{pending_ops: ops} = machine, target, attrs) do
    {rev_ops, found?} =
      Enum.reduce(ops, {[], false}, fn
        %{type: :update_task, target: ^target, attrs: existing}, {acc, _found?} ->
          merged = Map.merge(existing, attrs)
          {[%{type: :update_task, target: target, attrs: merged} | acc], true}

        op, {acc, found?} ->
          {[op | acc], found?}
      end)

    ops_in_order = Enum.reverse(rev_ops)

    if found? do
      %{machine | pending_ops: ops_in_order}
    else
      %{
        machine
        | pending_ops: ops_in_order ++ [%{type: :update_task, target: target, attrs: attrs}]
      }
    end
  end

  defp stage_delete(%__MODULE__{} = machine, {:pending, ref} = target) do
    {remaining, removed?} =
      Enum.reduce(machine.pending_ops, {[], false}, fn op, {acc, removed?} ->
        cond do
          op.type == :create_task and op.target == target ->
            {acc, true}

          op.target == target ->
            {acc, removed?}

          true ->
            {[op | acc], removed?}
        end
      end)

    case removed? do
      true ->
        machine = %{machine | pending_ops: Enum.reverse(remaining)}
        {:ok, machine, "Pending task creation removed."}

      false ->
        {:error, "No pending task with ref #{ref}."}
    end
  end

  defp stage_delete(%__MODULE__{} = machine, target) do
    machine =
      machine
      |> remove_ops_for_target(target)
      |> append_op(%{type: :delete_task, target: target, attrs: %{}})

    {:ok, machine, "Task marked for deletion."}
  end

  defp stage_complete(_machine, {:pending, ref}) do
    {:error, "Cannot complete pending task #{ref}. Create it first or discard it."}
  end

  defp stage_complete(machine, target) do
    machine =
      machine
      |> remove_ops_for_target(target, only: [:complete_task])
      |> append_op(%{type: :complete_task, target: target, attrs: %{}})

    {:ok, machine, "Task will be completed when committed."}
  end

  defp clear_editing(machine), do: %{machine | state: :awaiting_command, edit_context: nil}

  defp append_op(%__MODULE__{pending_ops: ops} = machine, op) do
    %{machine | pending_ops: ops ++ [op]}
  end

  defp remove_ops_for_target(%__MODULE__{pending_ops: ops} = machine, target, opts \\ []) do
    types = Keyword.get(opts, :only)

    filtered =
      Enum.reject(ops, fn op ->
        op.target == target and (is_nil(types) or op.type in types)
      end)

    %{machine | pending_ops: filtered}
  end

  defp update_edit_context(%__MODULE__{} = machine, target, attrs) do
    case machine.edit_context do
      %{target: ^target, staged: staged} ->
        %{machine | edit_context: %{target: target, staged: Map.merge(staged, attrs)}}

      _ ->
        machine
    end
  end

  # Persistence

  defp persist_pending_ops(%__MODULE__{pending_ops: []} = machine) do
    {:noop, %{machine | state: :completed, edit_context: nil}}
  end

  defp persist_pending_ops(%__MODULE__{} = machine) do
    scope = machine.current_scope

    case Repo.transaction(fn -> apply_operations(machine.pending_ops, scope) end) do
      {:ok, summary} ->
        {:ok, %{machine | state: :completed, edit_context: nil, pending_ops: []}, summary}

      {:error, reason} ->
        {:error, format_transaction_error(reason)}
    end
  end

  defp apply_operations(ops, scope) do
    initial = %{
      summary: %{created: [], updated: [], deleted: [], completed: []},
      pending_map: %{}
    }

    final =
      Enum.reduce(ops, initial, fn op, acc ->
        case apply_operation(op, scope, acc) do
          {:ok, acc} -> acc
          {:error, reason} -> Repo.rollback(reason)
        end
      end)

    tidy_summary(final.summary)
  end

  defp apply_operation(%{type: :create_task, target: {:pending, ref}, attrs: attrs}, scope, acc) do
    case Tasks.create_task(scope, attrs) do
      {:ok, task} ->
        summary = Map.update!(acc.summary, :created, fn entries -> [task | entries] end)

        {:ok,
         %{
           acc
           | summary: summary,
             pending_map: Map.put(acc.pending_map, ref, task.id)
         }}

      {:error, %Changeset{} = changeset} ->
        {:error, {:create_task, ref, changeset}}
    end
  end

  defp apply_operation(%{target: target, type: type, attrs: attrs}, scope, acc) do
    with {:ok, task_id} <- resolve_runtime_target(target, acc.pending_map),
         {:ok, acc} <- dispatch_existing(type, task_id, attrs, scope, acc) do
      {:ok, acc}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp resolve_runtime_target({:existing, id}, _map), do: {:ok, id}

  defp resolve_runtime_target({:pending, ref}, map) do
    case Map.fetch(map, ref) do
      {:ok, id} -> {:ok, id}
      :error -> {:error, {:missing_pending_reference, ref}}
    end
  end

  defp dispatch_existing(:update_task, task_id, attrs, scope, acc) do
    with {:ok, task} <- fetch_task(scope, task_id),
         {:ok, updated} <- Tasks.update_task(scope, task, attrs) do
      summary = Map.update!(acc.summary, :updated, fn entries -> [updated | entries] end)
      {:ok, %{acc | summary: summary}}
    else
      {:error, {:missing_task, _} = reason} -> {:error, reason}
      {:error, %Changeset{} = changeset} -> {:error, {:update_task, task_id, changeset}}
    end
  end

  defp dispatch_existing(:delete_task, task_id, _attrs, scope, acc) do
    with {:ok, task} <- fetch_task(scope, task_id),
         {:ok, deleted} <- Tasks.delete_task(scope, task) do
      summary = Map.update!(acc.summary, :deleted, fn entries -> [deleted | entries] end)
      {:ok, %{acc | summary: summary}}
    else
      {:error, {:missing_task, _} = reason} -> {:error, reason}
      {:error, other} -> {:error, {:delete_task, task_id, other}}
    end
  end

  defp dispatch_existing(:complete_task, task_id, _attrs, scope, acc) do
    with {:ok, task} <- fetch_task(scope, task_id),
         {:ok, completed} <- Tasks.complete_task(scope, task) do
      summary = Map.update!(acc.summary, :completed, fn entries -> [completed | entries] end)
      {:ok, %{acc | summary: summary}}
    else
      {:error, {:missing_task, _} = reason} -> {:error, reason}
      {:error, %Changeset{} = changeset} -> {:error, {:complete_task, task_id, changeset}}
    end
  end

  defp dispatch_existing(type, task_id, _attrs, _scope, _acc) do
    {:error, {:unsupported_operation, type, task_id}}
  end

  defp fetch_task(scope, id) do
    {:ok, Tasks.get_task!(scope, id)}
  rescue
    Ecto.NoResultsError -> {:error, {:missing_task, id}}
  end

  defp tidy_summary(summary) do
    Enum.into(summary, %{}, fn {key, list} -> {key, Enum.reverse(list)} end)
  end

  defp commit_message(summary) do
    parts =
      [:created, :updated, :deleted, :completed]
      |> Enum.map(fn key -> summarize_part(key, Map.get(summary, key, [])) end)
      |> Enum.reject(&is_nil/1)

    case parts do
      [] -> "Session committed. No staged changes were applied. Session closed."
      _ -> "Session committed (#{Enum.join(parts, ", ")}). Session closed."
    end
  end

  defp summarize_part(_key, []), do: nil
  defp summarize_part(key, items), do: "#{length(items)} #{Atom.to_string(key)}"

  defp format_transaction_error({:missing_task, id}),
    do: "Task #{id} could not be found during commit."

  defp format_transaction_error({:missing_pending_reference, ref}),
    do: "Pending reference #{ref} was not created before it was referenced."

  defp format_transaction_error({action, ref, %Changeset{} = changeset}) do
    errors =
      changeset
      |> Changeset.traverse_errors(&translate_error/1)
      |> Enum.map(fn {field, msgs} -> "#{field}: #{Enum.join(msgs, ", ")}" end)
      |> Enum.join("; ")

    "#{atom_to_words(action)} failed for #{ref}: #{errors}"
  end

  defp format_transaction_error({:delete_task, id, reason}),
    do: "Deleting task #{id} failed: #{inspect(reason)}"

  defp format_transaction_error({:unsupported_operation, type, task_id}),
    do: "Unsupported operation #{inspect(type)} for task #{task_id}."

  defp format_transaction_error(other),
    do: "Operation failed: #{inspect(other)}"

  defp translate_error({msg, opts}) do
    Enum.reduce(opts, msg, fn {key, value}, acc ->
      String.replace(acc, "%{#{key}}", to_string(value))
    end)
  end

  defp atom_to_words(atom) do
    atom
    |> Atom.to_string()
    |> String.replace("_", " ")
  end

  # Param helpers

  defp resolve_target_param(_machine, params) do
    cond do
      Map.has_key?(params, "task_id") ->
        parse_existing(Map.get(params, "task_id"))

      Map.has_key?(params, :task_id) ->
        parse_existing(Map.get(params, :task_id))

      Map.has_key?(params, "pending_ref") ->
        parse_pending(Map.get(params, "pending_ref"))

      Map.has_key?(params, :pending_ref) ->
        parse_pending(Map.get(params, :pending_ref))

      true ->
        {:error, "Provide either task_id or pending_ref."}
    end
  end

  defp parse_existing(value) do
    with {:ok, int} <- parse_positive_int(value) do
      {:ok, {:existing, int}}
    end
  end

  defp parse_pending(value) do
    with {:ok, int} <- parse_positive_int(value) do
      {:ok, {:pending, int}}
    end
  end

  defp parse_positive_int(value) when is_integer(value) and value > 0, do: {:ok, value}

  defp parse_positive_int(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} when int > 0 -> {:ok, int}
      _ -> {:error, "Expected a positive integer value."}
    end
  end

  defp parse_positive_int(_), do: {:error, "Expected a positive integer value."}

  defp ensure_selectable(machine, {:existing, id}) do
    case Enum.find(base_tasks(machine), &(&1.id == id)) do
      nil -> {:error, "Task #{id} not found for the current scope."}
      %{status: :done} -> {:error, "Task #{id} is already completed."}
      _ -> :ok
    end
  end

  defp ensure_selectable(machine, {:pending, ref}) do
    case Enum.any?(machine.pending_ops, fn op ->
           op.type == :create_task and op.target == {:pending, ref}
         end) do
      true -> :ok
      false -> {:error, "Pending ref #{ref} not found."}
    end
  end

  defp normalize_task_attrs(attrs) when is_map(attrs) do
    cleaned =
      Enum.reduce(attrs, %{}, fn {key, value}, acc ->
        case normalize_field_key(key) do
          nil -> acc
          field -> Map.put(acc, field, value)
        end
      end)

    {:ok, cleaned}
  end

  defp normalize_task_attrs(_), do: {:error, "Attributes must be provided as a map."}

  defp normalize_field_key(key) when is_atom(key) do
    if key in @allowed_fields, do: key, else: nil
  end

  defp normalize_field_key(key) when is_binary(key) do
    Enum.find(@allowed_fields, fn field -> Atom.to_string(field) == key end)
  end

  defp normalize_field_key(_), do: nil

  defp normalize_plan(params) when is_map(params) do
    plan = Map.get(params, "plan") || Map.get(params, :plan)
    steps = Map.get(params, "steps") || Map.get(params, :steps)

    with :ok <- ensure_plan(plan, steps),
         {:ok, steps_list} <- normalize_plan_steps(steps) do
      {:ok,
       %{
         plan: normalize_plan_text(plan, steps_list),
         steps: steps_list
       }}
    end
  end

  defp normalize_plan(_), do: {:error, "Plan details must be provided as a map."}

  defp ensure_plan(plan, steps) do
    cond do
      is_binary(plan) and String.trim(plan) != "" -> :ok
      is_list(steps) and Enum.any?(steps, &valid_step?/1) -> :ok
      true -> {:error, "Provide a non-empty plan summary or at least one textual step."}
    end
  end

  defp normalize_plan_text(plan, steps) when is_binary(plan) do
    trimmed = String.trim(plan)

    cond do
      trimmed != "" -> trimmed
      steps == [] -> ""
      true -> Enum.join(steps, " | ")
    end
  end

  defp normalize_plan_text(_plan, steps), do: Enum.join(steps, " | ")

  defp normalize_plan_steps(nil), do: {:ok, []}

  defp normalize_plan_steps(steps) when is_list(steps) do
    cleaned =
      steps
      |> Enum.map(&normalize_plan_step/1)
      |> Enum.filter(& &1)

    {:ok, cleaned}
  end

  defp normalize_plan_steps(_), do: {:error, "Steps must be provided as a list of strings."}

  defp normalize_plan_step(step) when is_binary(step) do
    trimmed = String.trim(step)
    if trimmed == "", do: nil, else: trimmed
  end

  defp normalize_plan_step(step) when is_atom(step), do: normalize_plan_step(Atom.to_string(step))
  defp normalize_plan_step(_), do: nil

  defp valid_step?(step) when is_binary(step), do: String.trim(step) != ""
  defp valid_step?(step) when is_atom(step), do: valid_step?(Atom.to_string(step))
  defp valid_step?(_), do: false

  # Response rendering

  defp build_response(machine, message, opts \\ []) do
    tasks = tasks_preview(machine)

    %{
      state: render_state(machine.state),
      message: message,
      error?: Keyword.get(opts, :error?, false),
      open_tasks: Enum.map(tasks, &public_task_view/1),
      pending_operations: Enum.map(machine.pending_ops, &public_op_view/1),
      editing: render_editing(machine.edit_context, tasks),
      plan_notes: Enum.map(machine.plan_notes, &public_plan_note/1),
      available_commands: available_commands(machine)
    }
  end

  defp render_state(:awaiting_command), do: "awaiting_command"
  defp render_state(:completed), do: "completed"
  defp render_state({:editing_task, target}), do: "editing:" <> external_target(target)

  defp public_op_view(%{type: type, target: target, attrs: attrs}) do
    %{
      type: Atom.to_string(type),
      target: external_target(target),
      params: encode_attrs(attrs)
    }
  end

  defp public_task_view(%{target: target, data: data, pending?: pending?}) do
    data
    |> Map.put(:target, external_target(target))
    |> Map.put(:pending?, pending?)
  end

  defp encode_attrs(attrs) do
    attrs
    |> Enum.map(fn {key, value} -> {encode_key(key), value} end)
    |> Enum.into(%{})
  end

  defp encode_key(key) when is_atom(key), do: Atom.to_string(key)
  defp encode_key(key), do: to_string(key)

  defp render_editing(nil, _tasks), do: nil

  defp render_editing(%{target: target, staged: staged}, tasks) do
    preview = Enum.find(tasks, fn %{target: t} -> t == target end)

    %{
      target: external_target(target),
      pending_changes: encode_attrs(staged),
      current_preview: preview && preview.data
    }
  end

  defp public_plan_note(%{plan: plan, steps: steps}) do
    %{plan: plan, steps: steps}
  end

  defp available_commands(%__MODULE__{state: :awaiting_command, pending_ops: pending}) do
    [
      %{
        name: "record_plan",
        params: %{
          "plan" => "string summary (required if no steps)",
          "steps" => "optional list of strings detailing each step"
        },
        description:
          "Document a step-by-step plan whenever fulfilling the request will take multiple commands."
      },
      %{
        name: "select_task",
        params: %{
          "task_id" => "integer id of an existing open task",
          "pending_ref" => "integer pending_ref returned by create_task (optional)"
        },
        description: "Focus on a task before issuing update, delete, or complete commands."
      },
      %{
        name: "create_task",
        params: %{
          "title" => "required string",
          "description" => "optional string",
          "due_date" => "optional ISO8601 date",
          "urgency" => "optional: low|normal|high|critical",
          "status" => "optional: todo|in_progress",
          "recurrence" => "optional: none|daily|weekly|monthly|yearly",
          "prerequisite_ids" => "optional list of task ids"
        },
        description: "Stage a brand new task. Returns a pending_ref for further edits."
      },
      %{
        name: "discard_all",
        params: %{},
        description: "Remove every staged operation and reset the session."
      },
      commit_command(pending)
    ]
  end

  defp available_commands(%__MODULE__{state: {:editing_task, _target}, pending_ops: pending}) do
    [
      %{
        name: "record_plan",
        params: %{
          "plan" => "string summary (required if no steps)",
          "steps" => "optional list of strings detailing each step"
        },
        description:
          "Capture or refine your multi-step plan before issuing further edits or deletions."
      },
      %{
        name: "update_task_fields",
        params: %{
          "title" => "optional string",
          "description" => "optional string",
          "due_date" => "optional ISO8601 date",
          "urgency" => "optional: low|normal|high|critical",
          "status" => "optional: todo|in_progress",
          "recurrence" => "optional: none|daily|weekly|monthly|yearly",
          "prerequisite_ids" => "optional list of task ids"
        },
        description: "Merge the supplied fields into the staged update for the focused task."
      },
      %{
        name: "complete_task",
        params: %{},
        description: "Mark the focused task to be completed when the session commits."
      },
      %{
        name: "delete_task",
        params: %{},
        description: "Delete the focused task when the session commits."
      },
      %{
        name: "exit_editing",
        params: %{},
        description: "Return to awaiting commands while keeping staged changes."
      },
      %{
        name: "discard_all",
        params: %{},
        description: "Drop every staged change and reset the session."
      },
      commit_command(pending)
    ]
  end

  defp available_commands(%__MODULE__{state: :completed}), do: []

  defp commit_command(pending_ops) do
    %{
      name: "complete_session",
      params: %{},
      description:
        if pending_ops == [] do
          "Close the session without committing any changes. This must be the final command you issue."
        else
          "Apply all staged operations in a single transaction and finish. This must always be your final command."
        end
    }
  end

  defp tasks_preview(machine) do
    base =
      machine
      |> base_tasks()
      |> Enum.reject(&(&1.status == :done))
      |> Enum.map(&wrap_task_preview/1)

    Enum.reduce(machine.pending_ops, base, fn op, preview -> apply_preview_op(preview, op) end)
  end

  defp base_tasks(%__MODULE__{current_scope: scope}) do
    Tasks.list_tasks(scope)
  end

  defp wrap_task_preview(task) do
    %{
      target: {:existing, task.id},
      pending?: false,
      data: %{
        id: task.id,
        title: task.title,
        description: task.description,
        status: render_enum(task.status),
        urgency: render_enum(task.urgency),
        due_date: render_date(task.due_date),
        recurrence: render_enum(task.recurrence),
        prerequisites: Enum.map(task.prerequisites, & &1.id),
        dependents: Enum.map(task.dependents, & &1.id)
      }
    }
  end

  defp apply_preview_op(preview, %{type: :create_task, target: {:pending, ref}, attrs: attrs}) do
    data = %{
      id: "pending-#{ref}",
      title: Map.get(attrs, :title, "Pending Task"),
      description: Map.get(attrs, :description),
      status: render_enum(Map.get(attrs, :status, :todo)),
      urgency: render_enum(Map.get(attrs, :urgency, :normal)),
      due_date: render_date(Map.get(attrs, :due_date)),
      recurrence: render_enum(Map.get(attrs, :recurrence, :none)),
      prerequisites: normalize_prereq_preview(Map.get(attrs, :prerequisite_ids)),
      dependents: []
    }

    preview ++ [%{target: {:pending, ref}, pending?: true, data: data}]
  end

  defp apply_preview_op(preview, %{type: :update_task, target: target, attrs: attrs}) do
    Enum.map(preview, fn
      %{target: ^target, data: data} = entry ->
        updated =
          data
          |> maybe_put(:title, attrs)
          |> maybe_put(:description, attrs)
          |> maybe_put(:status, attrs, &render_enum/1)
          |> maybe_put(:urgency, attrs, &render_enum/1)
          |> maybe_put(:due_date, attrs, &render_date/1)
          |> maybe_put(:recurrence, attrs, &render_enum/1)
          |> maybe_put(:prerequisites, attrs, &normalize_prereq_preview/1)

        %{entry | data: updated}

      other ->
        other
    end)
  end

  defp apply_preview_op(preview, %{type: :delete_task, target: target}) do
    Enum.reject(preview, fn %{target: t} -> t == target end)
  end

  defp apply_preview_op(preview, %{type: :complete_task, target: target}) do
    Enum.reject(preview, fn %{target: t} -> t == target end)
  end

  defp maybe_put(data, key, attrs, transform \\ fn value -> value end) do
    case Map.fetch(attrs, key) do
      {:ok, value} -> Map.put(data, key, transform.(value))
      :error -> data
    end
  end

  defp normalize_prereq_preview(nil), do: []

  defp normalize_prereq_preview(values) when is_list(values) do
    Enum.map(values, fn
      v when is_integer(v) ->
        v

      v when is_binary(v) ->
        case Integer.parse(v) do
          {int, ""} -> int
          _ -> v
        end

      other ->
        other
    end)
  end

  defp normalize_prereq_preview(value), do: normalize_prereq_preview([value])

  defp render_enum(nil), do: nil
  defp render_enum(value) when is_atom(value), do: Atom.to_string(value)
  defp render_enum(value), do: to_string(value)

  defp render_date(nil), do: nil
  defp render_date(%Date{} = date), do: Date.to_iso8601(date)
  defp render_date(value), do: to_string(value)

  defp external_target({:existing, id}), do: "existing:#{id}"
  defp external_target({:pending, ref}), do: "pending:#{ref}"
end
