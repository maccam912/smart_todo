defmodule SmartTodo.Repo do
  use Ecto.Repo,
    otp_app: :smart_todo,
    adapter: Ecto.Adapters.Postgres
end
