defmodule LibrarianWeb.UserAuthTest do
  use LibrarianWeb.ConnCase, async: true

  alias Librarian.Accounts

  setup do
    %{user: Accounts.ensure_api_token!(insert_allowed_user!("revoked"))}
  end

  test "a signed-in session ends when the email leaves the allowlist", %{conn: conn, user: user} do
    conn = log_in_user(conn, user)
    assert conn |> get(~p"/settings") |> html_response(200)

    disallow_user!(user)
    assert redirected_to(get(conn, ~p"/settings")) == ~p"/login"
  end

  test "an API token stops working when the email leaves the allowlist", %{
    conn: conn,
    user: user
  } do
    conn = put_req_header(conn, "authorization", "Bearer #{user.api_token}")
    assert conn |> get(~p"/api/notebooks") |> json_response(200)

    disallow_user!(user)
    assert conn |> get(~p"/api/notebooks") |> json_response(401)
  end
end
