if System.get_env("GEMINI_API_KEY") do
  defmodule SmartTodo.Agent.StateMachineIntegrationTest do
    use SmartTodo.DataCase, async: false

    alias SmartTodo.AccountsFixtures
    alias SmartTodo.Agent.LlmSession

    @moduletag :integration

    @prompt """
    You control the SmartTodo state machine. Call complete_session immediately with no
    parameters so we can verify connectivity.
    """

    setup do
      {:ok,
       scope: AccountsFixtures.user_scope_fixture(), api_key: System.fetch_env!("GEMINI_API_KEY")}
    end

    test "Gemini session completes", %{scope: scope, api_key: api_key} do
      assert {:ok, result} =
               LlmSession.run(scope, @prompt,
                 api_key: api_key,
                 max_rounds: 5
               )

      assert result.machine.state == :completed
      assert length(result.conversation) > 0
    end
  end
else
  defmodule SmartTodo.Agent.StateMachineIntegrationTest do
    use ExUnit.Case

    @moduletag :integration

    @tag skip: "GEMINI_API_KEY not set"
    test "skipped because GEMINI_API_KEY is missing" do
      assert true
    end
  end
end
