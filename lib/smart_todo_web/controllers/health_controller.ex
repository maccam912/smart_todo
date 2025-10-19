defmodule SmartTodoWeb.HealthController do
  use SmartTodoWeb, :controller

  def check(conn, _params) do
    conn
    |> put_status(200)
    |> text("ok")
  end
end
