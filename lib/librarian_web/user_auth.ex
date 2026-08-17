defmodule LibrarianWeb.UserAuth do
  @moduledoc """
  Session-based authentication. Users only ever come from Google OAuth
  (see `LibrarianWeb.AuthController`), so all this holds is the user id.
  """

  use LibrarianWeb, :verified_routes

  import Plug.Conn
  import Phoenix.Controller

  alias Librarian.Accounts

  def log_in_user(conn, user) do
    return_to = get_session(conn, :user_return_to)

    conn
    |> configure_session(renew: true)
    |> put_session(:user_id, user.id)
    |> delete_session(:user_return_to)
    |> put_flash(:info, "Welcome back, #{user.name || user.email}!")
    |> redirect(to: return_to || ~p"/")
  end

  def log_out_user(conn) do
    conn
    |> configure_session(renew: true)
    |> clear_session()
    |> redirect(to: ~p"/login")
  end

  def fetch_current_user(conn, _opts) do
    user =
      if user_id = get_session(conn, :user_id) do
        Accounts.get_user(user_id)
      end

    if user, do: Librarian.Repo.put_user_id(user.id)
    assign(conn, :current_user, user)
  end

  @doc """
  API auth: a per-user bearer token (Settings → API access). Sets the tenant
  for the request on success, 401s otherwise.
  """
  def require_api_token(conn, _opts) do
    with ["Bearer " <> token] <- get_req_header(conn, "authorization"),
         user when not is_nil(user) <- Accounts.get_user_by_api_token(token) do
      Librarian.Repo.put_user_id(user.id)
      assign(conn, :current_user, user)
    else
      _ ->
        conn
        |> put_status(401)
        |> Phoenix.Controller.json(%{error: "unauthorized"})
        |> halt()
    end
  end

  def require_authenticated_user(conn, _opts) do
    if conn.assigns[:current_user] do
      conn
    else
      conn
      |> maybe_store_return_to()
      |> redirect(to: ~p"/login")
      |> halt()
    end
  end

  def redirect_if_authenticated(conn, _opts) do
    if conn.assigns[:current_user] do
      conn |> redirect(to: ~p"/") |> halt()
    else
      conn
    end
  end

  def on_mount(:ensure_authenticated, _params, session, socket) do
    socket =
      Phoenix.Component.assign_new(socket, :current_user, fn ->
        if user_id = session["user_id"], do: Accounts.get_user(user_id)
      end)

    if user = socket.assigns.current_user do
      # The LiveView runs in its own process; handle_event/handle_info inherit
      # this process state.
      Librarian.Repo.put_user_id(user.id)
      {:cont, socket}
    else
      {:halt, Phoenix.LiveView.redirect(socket, to: ~p"/login")}
    end
  end

  defp maybe_store_return_to(%{method: "GET"} = conn) do
    put_session(conn, :user_return_to, current_path(conn))
  end

  defp maybe_store_return_to(conn), do: conn
end
