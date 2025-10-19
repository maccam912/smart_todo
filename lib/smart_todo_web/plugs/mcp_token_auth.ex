defmodule SmartTodoWeb.Plugs.MCPTokenAuth do
  @moduledoc """
  Plug for extracting access token from path and authenticating user for MCP requests.

  The token is expected to be in the path like: /mcp/<token>/...
  """

  import Plug.Conn
  import Phoenix.Controller

  alias SmartTodo.Accounts

  def init(opts), do: opts

  def call(conn, _opts) do
    # Extract token from path_params
    case Map.get(conn.path_params, "token") do
      nil ->
        send_unauthorized(conn)

      token ->
        case Accounts.get_user_by_session_token(token) do
          nil ->
            # Try as access token
            case Accounts.get_user_by_access_token(token) do
              nil ->
                send_unauthorized(conn)

              {user, _token_record} ->
                scope = Accounts.get_scope_for_user(user)
                assign(conn, :current_scope, scope)
            end

          user ->
            scope = Accounts.get_scope_for_user(user)
            assign(conn, :current_scope, scope)
        end
    end
  end

  defp send_unauthorized(conn) do
    conn
    |> put_status(:unauthorized)
    |> put_view(json: SmartTodoWeb.ErrorJSON)
    |> render("401.json")
    |> halt()
  end
end
