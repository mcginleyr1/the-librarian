defmodule LibrarianWeb.PageControllerTest do
  use LibrarianWeb.ConnCase

  test "GET / redirects to /reader", %{conn: conn} do
    conn = get(conn, ~p"/")
    assert redirected_to(conn) == "/reader"
  end
end
