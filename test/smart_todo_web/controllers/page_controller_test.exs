defmodule SmartTodoWeb.PageControllerTest do
  use SmartTodoWeb.ConnCase

  test "GET / redirects to log in when unauthenticated", %{conn: conn} do
    conn = get(conn, ~p"/")
    assert redirected_to(conn) == ~p"/users/log-in"
  end
end
