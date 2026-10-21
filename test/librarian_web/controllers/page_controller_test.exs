defmodule LibrarianWeb.PageControllerTest do
  use LibrarianWeb.ConnCase, async: true

  test "GET / redirects to /login when signed out", %{conn: conn} do
    conn = get(conn, ~p"/")
    assert redirected_to(conn) == ~p"/login"
  end

  test "GET /login renders the Google sign-in button", %{conn: conn} do
    conn = get(conn, ~p"/login")
    assert html_response(conn, 200) =~ "google-sign-in"
  end

  test "pages carry a CSP whose script nonce matches the inline script", %{conn: conn} do
    conn = get(conn, ~p"/login")
    [csp] = get_resp_header(conn, "content-security-policy")

    assert [_, nonce] = Regex.run(~r/script-src 'self' 'nonce-([^']+)'/, csp)
    assert csp =~ "object-src 'none'"
    assert html_response(conn, 200) =~ ~s(nonce="#{nonce}")
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
