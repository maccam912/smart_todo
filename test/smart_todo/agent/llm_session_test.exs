defmodule SmartTodo.Agent.LlmSessionTest do
  use SmartTodo.DataCase, async: true

  alias SmartTodo.AccountsFixtures
  alias SmartTodo.Agent.LlmSession
  alias SmartTodo.Tasks
  alias SmartTodo.TasksFixtures

  defp stub_response(name, args) do
    {:ok,
     %{
       "candidates" => [
         %{
           "content" => %{
             "parts" => [
               %{
                 "functionCall" => %{
                   "name" => name,
                   "args" => args
                 }
               }
             ]
           }
         }
       ]
     }}
  end

  test "executes commands until the session completes" do
    scope = AccountsFixtures.user_scope_fixture()

    Process.put(:llm_responses, [
      stub_response("create_task", %{"title" => "Write integration tests"}),
      stub_response("complete_session", %{})
    ])

    request_fun = fn _url, payload, _opts ->
      send(self(), {:llm_payload, payload})

      case Process.get(:llm_responses) do
        [resp | rest] ->
          Process.put(:llm_responses, rest)
          resp

        _ ->
          flunk("no more responses queued")
      end
    end

    {:ok, result} =
      LlmSession.run(scope, "Please add a task and finish",
        request_fun: request_fun,
        api_key: "test"
      )

    assert Enum.any?(result.executed, &(&1.name == :create_task))
    assert result.machine.state == :completed
    assert Enum.any?(Tasks.list_tasks(scope), &(&1.title == "Write integration tests"))

    assert_received {:llm_payload, payload}
    assert %{"tools" => [%{"functionDeclarations" => declarations}]} = payload

    assert Enum.any?(declarations, fn
             %{"name" => "create_task"} -> true
             _ -> false
           end)
  end

  test "stops with an error when the model requests an unavailable command" do
    scope = AccountsFixtures.user_scope_fixture()
    task = TasksFixtures.task_fixture(scope.user)

    Process.put(:llm_responses, [
      stub_response("select_task", %{"task_id" => Integer.to_string(task.id)}),
      stub_response("select_task", %{"task_id" => Integer.to_string(task.id)})
    ])

    request_fun = fn _url, _payload, _opts ->
      case Process.get(:llm_responses) do
        [resp | rest] ->
          Process.put(:llm_responses, rest)
          resp

        _ ->
          flunk("no more responses queued")
      end
    end

    assert {:error, {:unsupported_command, "select_task"}, ctx} =
             LlmSession.run(scope, "select something", request_fun: request_fun, api_key: "test")

    assert ctx.machine.state == {:editing_task, {:existing, task.id}}
  end

  test "enforces the max round limit" do
    scope = AccountsFixtures.user_scope_fixture()

    Process.put(
      :llm_responses,
      Stream.repeatedly(fn -> stub_response("discard_all", %{}) end) |> Enum.take(5)
    )

    request_fun = fn _url, _payload, _opts ->
      case Process.get(:llm_responses) do
        [resp | rest] ->
          Process.put(:llm_responses, rest)
          resp

        _ ->
          flunk("no more responses queued")
      end
    end

    assert {:error, :max_rounds, _ctx} =
             LlmSession.run(scope, "loop",
               request_fun: request_fun,
               api_key: "test",
               max_rounds: 1
             )
  end
end
