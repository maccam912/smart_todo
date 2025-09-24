defmodule SmartTodoWeb.PageController do
  use SmartTodoWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
