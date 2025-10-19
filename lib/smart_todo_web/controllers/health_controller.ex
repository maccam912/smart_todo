defmodule SmartTodoWeb.HealthController do
  use SmartTodoWeb, :controller

  def index(conn, _params) do
    json(conn, %{status: "ok"})
  end
end
