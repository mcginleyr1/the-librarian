defmodule LibrarianWeb.PageController do
  use LibrarianWeb, :controller

  def home(conn, _params) do
    redirect(conn, to: "/reader")
  end
end
