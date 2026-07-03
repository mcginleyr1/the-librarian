defmodule LibrarianWeb.PageController do
  use LibrarianWeb, :controller

  def home(conn, _params) do
    redirect(conn, to: "/reader")
  end

  def login(conn, _params) do
    render(conn, :login, page_title: "Sign in")
  end
end
