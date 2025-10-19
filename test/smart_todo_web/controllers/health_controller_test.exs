defmodule SmartTodoWeb.HealthControllerTest do
  use SmartTodoWeb.ConnCase

  test "GET /api/health returns ok status", %{conn: conn} do
    conn = get(conn, ~p"/api/health")
    assert json_response(conn, 200) == %{"status" => "ok"}
  end
end
