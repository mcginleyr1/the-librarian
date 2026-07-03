defmodule LibrarianWeb.PageControllerTest do
  use LibrarianWeb.ConnCase

  test "GET / redirects to /login when signed out", %{conn: conn} do
    conn = get(conn, ~p"/")
    assert redirected_to(conn) == ~p"/login"
  end

  test "GET /login renders the Google sign-in button", %{conn: conn} do
    conn = get(conn, ~p"/login")
    assert html_response(conn, 200) =~ "google-sign-in"
  end

  describe "signed in" do
    setup :log_in_owner

    test "GET / redirects to /reader", %{conn: conn} do
      conn = get(conn, ~p"/")
      assert redirected_to(conn) == "/reader"
    end

    test "GET /login redirects home", %{conn: conn} do
      conn = get(conn, ~p"/login")
      assert redirected_to(conn) == ~p"/"
    end
  end
end
