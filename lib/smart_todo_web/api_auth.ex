defmodule SmartTodoWeb.ApiAuth do
  @moduledoc """
  Plug for authenticating API requests using bearer tokens.
  """

  import Plug.Conn
  import Phoenix.Controller

  alias SmartTodo.Accounts
  alias SmartTodo.Accounts.Scope

  @doc """
  Initializes the plug options.
  """
  def init(opts), do: opts

  @doc """
  Authenticates API requests using a bearer token from the Authorization header.

  If authentication succeeds, assigns `:current_scope` to the connection.
  If authentication fails, returns a 401 Unauthorized response.
  """
  def call(conn, _opts) do
    with ["Bearer " <> token] <- get_req_header(conn, "authorization"),
         %Accounts.User{} = user <- Accounts.get_user_by_access_token(token) do
      assign(conn, :current_scope, %Scope{user: user})
    else
      _ ->
        conn
        |> put_status(:unauthorized)
        |> put_view(json: SmartTodoWeb.ErrorJSON)
        |> render(:"401")
        |> halt()
    end
  end
end
