defmodule LibrarianWeb.HealthControllerTest do
  use LibrarianWeb.ConnCase, async: true

  test "GET /health answers 200 without a session", %{conn: conn} do
    assert conn |> get(~p"/health") |> response(200)
  end
end
