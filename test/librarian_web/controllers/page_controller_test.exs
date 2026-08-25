defmodule LibrarianWeb.PageControllerTest do
  # async: false — the landing-page tests mutate global billing config.
  use LibrarianWeb.ConnCase, async: false

  import Librarian.BillingHelpers

  test "GET / redirects to /login when signed out (billing disabled)", %{conn: conn} do
    conn = get(conn, ~p"/")
    assert redirected_to(conn) == ~p"/login"
  end

  test "GET /login renders the Google sign-in button", %{conn: conn} do
    conn = get(conn, ~p"/login")
    assert html_response(conn, 200) =~ "google-sign-in"
  end

  describe "landing page (billing enabled)" do
    setup :enable_billing

    test "GET / shows the landing page with pricing to visitors", %{conn: conn} do
      html = conn |> get(~p"/") |> html_response(200)

      assert html =~ "id=\"landing\""
      assert html =~ "id=\"pricing\""
      assert html =~ "$12"
      assert html =~ "$96"
      assert html =~ "14-day free trial"
    end

    test "GET / still redirects signed-in users to the app", %{conn: conn} do
      %{conn: conn} = log_in_owner(%{conn: conn})
      conn = get(conn, ~p"/")
      assert redirected_to(conn) == "/reader"
    end
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
