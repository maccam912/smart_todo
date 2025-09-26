defmodule SmartTodo.Agent.LlmSessionTest do
  use SmartTodo.DataCase, async: true

  alias SmartTodo.Accounts
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

  test "record_plan tool advertises steps as an array" do
    scope = AccountsFixtures.user_scope_fixture()

    request_fun = fn _url, payload, _opts ->
      send(self(), {:tool_schema_payload, payload})
      {:error, :stubbed}
    end

    assert {:error, :stubbed, _ctx} =
             LlmSession.run(scope, "Plan work",
               request_fun: request_fun,
               api_key: "test",
               max_rounds: 1
             )

    assert_received {:tool_schema_payload, payload}

    [%{"functionDeclarations" => declarations}] = payload["tools"]
    record_plan = Enum.find(declarations, &(&1["name"] == "record_plan"))

    assert get_in(record_plan, ["parameters", "properties", "steps", "type"]) == "array"
    assert get_in(record_plan, ["parameters", "properties", "steps", "items", "type"]) == "string"
  end

  test "recovers from state machine errors when possible" do
    scope = AccountsFixtures.user_scope_fixture()

    Process.put(:llm_responses, [
      stub_response("record_plan", %{}),
      stub_response("record_plan", %{
        "plan" => "Cluster upgrades",
        "steps" => ["Upgrade Cortex", "Upgrade USRM"]
      }),
      stub_response("complete_session", %{})
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

    {:ok, result} =
      LlmSession.run(scope, "Handle upgrades",
        request_fun: request_fun,
        api_key: "test"
      )

    assert result.machine.state == :completed
    assert Enum.map(result.executed, & &1.name) == [:record_plan, :complete_session]

    assert Enum.any?(get_in(result, [:last_response, :plan_notes]), fn note ->
             note.plan == "Cluster upgrades"
           end)
  end

  test "stops automation after exceeding retry limit" do
    scope = AccountsFixtures.user_scope_fixture()

    Process.put(
      :llm_responses,
      Enum.map(1..2, fn _ -> stub_response("record_plan", %{}) end)
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

    assert {:error, :max_errors, ctx} =
             LlmSession.run(scope, "still failing",
               request_fun: request_fun,
               api_key: "test",
               max_errors: 2
             )

    assert ctx.errors == 2
    assert Enum.map(ctx.executed, & &1.name) == []
  end

  test "uses Helicone proxy headers when configured" do
    scope = AccountsFixtures.user_scope_fixture()

    Process.put(:llm_responses, [stub_response("complete_session", %{})])

    original = System.get_env("HELICONE_API_KEY")
    System.put_env("HELICONE_API_KEY", "helicone-test")

    on_exit(fn ->
      if original do
        System.put_env("HELICONE_API_KEY", original)
      else
        System.delete_env("HELICONE_API_KEY")
      end
    end)

    request_fun = fn url, _payload, opts ->
      assert String.starts_with?(url, "https://gateway.helicone.ai/v1beta/models/")

      headers = Keyword.fetch!(opts, :headers)

      assert {"Helicone-Auth", "Bearer helicone-test"} in headers
      assert {"Helicone-Target-URL", "https://generativelanguage.googleapis.com"} in headers
      assert {"Helicone-Property-App", "smart_todo"} in headers
      assert {"Helicone-Property-UserId", Integer.to_string(scope.user.id)} in headers

      case Process.get(:llm_responses) do
        [resp | rest] ->
          Process.put(:llm_responses, rest)
          resp

        _ ->
          flunk("no more responses queued")
      end
    end

    assert {:ok, _result} =
             LlmSession.run(scope, "route via helicone",
               request_fun: request_fun,
               api_key: "test"
             )
  end

  test "includes user preferences in the system prompt" do
    scope = AccountsFixtures.user_scope_fixture()

    {:ok, preference} =
      Accounts.upsert_user_preferences(scope.user, %{
        "prompt_preferences" => "Respond in Spanish."
      })

    scope = %{scope | user: %{scope.user | preference: preference}}

    Process.put(:llm_responses, [stub_response("complete_session", %{})])

    request_fun = fn _url, payload, _opts ->
      send(self(), {:system_instruction, payload["systemInstruction"]})

      case Process.get(:llm_responses) do
        [resp | rest] ->
          Process.put(:llm_responses, rest)
          resp

        _ ->
          flunk("no more responses queued")
      end
    end

    {:ok, _result} =
      LlmSession.run(scope, "Finish up", request_fun: request_fun, api_key: "test")

    assert_received {:system_instruction, %{"parts" => [%{"text" => prompt_text}]}}
    assert prompt_text =~ "User preferences:"
    assert prompt_text =~ "Respond in Spanish."
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

  test "applies configured receive timeout when calling the model" do
    scope = AccountsFixtures.user_scope_fixture()

    Process.put(:llm_responses, [stub_response("complete_session", %{})])

    Application.put_env(:smart_todo, :llm_receive_timeout, 123_000)
    on_exit(fn -> Application.delete_env(:smart_todo, :llm_receive_timeout) end)

    request_fun = fn _url, _payload, opts ->
      assert Keyword.get(opts, :receive_timeout) == 123_000

      case Process.get(:llm_responses) do
        [resp | rest] ->
          Process.put(:llm_responses, rest)
          resp

        _ ->
          flunk("no more responses queued")
      end
    end

    assert {:ok, _result} =
             LlmSession.run(scope, "Finish up",
               request_fun: request_fun,
               api_key: "test"
             )
  end
end
