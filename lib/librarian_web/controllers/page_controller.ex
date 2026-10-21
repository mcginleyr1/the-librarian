defmodule LibrarianWeb.PageController do
  use LibrarianWeb, :controller

  def home(conn, _params) do
    if conn.assigns[:current_user],
      do: redirect(conn, to: "/reader"),
      else: redirect(conn, to: "/login")
  end

  def login(conn, _params) do
    render(conn, :login, page_title: "Sign in")
  end
end
