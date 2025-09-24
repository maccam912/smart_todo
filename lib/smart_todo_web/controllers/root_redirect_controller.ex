defmodule SmartTodoWeb.RootRedirectController do
  use SmartTodoWeb, :controller

  def index(conn, _params) do
    if conn.assigns.current_scope && conn.assigns.current_scope.user do
      redirect(conn, to: ~p"/tasks")
    else
      redirect(conn, to: ~p"/users/log-in")
    end
  end
end

