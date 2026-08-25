defmodule LibrarianWeb.AuthControllerTest do
  use LibrarianWeb.ConnCase

  alias Librarian.Accounts

  defp google_auth(email, opts \\ []) do
    %Ueberauth.Auth{
      provider: :google,
      uid: Keyword.get(opts, :uid, "google-uid-123"),
      info: %Ueberauth.Auth.Info{
        email: email,
        name: Keyword.get(opts, :name, "Rob McGinley"),
        image: "https://example.com/avatar.png"
      }
    }
  end

  defp callback_with(conn, auth) do
    conn
    |> init_test_session(%{})
    |> Phoenix.Controller.fetch_flash([])
    |> assign(:ueberauth_auth, auth)
    |> LibrarianWeb.AuthController.callback(%{})
  end

  describe "callback" do
    test "allowed email signs in and claims the migration-created owner", %{conn: conn} do
      owner_before = Accounts.owner!()
      assert owner_before.provider_uid == nil

      conn = callback_with(conn, google_auth("owner@example.com"))

      assert redirected_to(conn) == ~p"/"
      owner = Accounts.owner!()
      assert get_session(conn, :user_id) == owner.id
      assert owner.id == owner_before.id
      assert owner.provider_uid == "google-uid-123"
      assert owner.avatar_url == "https://example.com/avatar.png"
    end

    test "email outside the allowlist is rejected", %{conn: conn} do
      conn = callback_with(conn, google_auth("intruder@example.com"))

      assert redirected_to(conn) == ~p"/login"
      refute get_session(conn, :user_id)
      refute Librarian.Repo.get_by(Accounts.User, email: "intruder@example.com")
    end

    test "with billing enabled, anyone may sign up (the paywall gates access)", %{conn: conn} do
      Librarian.BillingHelpers.enable_billing()

      conn = callback_with(conn, google_auth("stranger@example.com"))

      assert redirected_to(conn) == ~p"/"
      user = Librarian.Repo.get_by(Accounts.User, email: "stranger@example.com")
      assert get_session(conn, :user_id) == user.id
      refute Librarian.Billing.active?(user)
    end

    test "provider failure redirects to login", %{conn: conn} do
      conn =
        conn
        |> init_test_session(%{})
        |> Phoenix.Controller.fetch_flash([])
        |> assign(:ueberauth_failure, %Ueberauth.Failure{})
        |> LibrarianWeb.AuthController.callback(%{})

      assert redirected_to(conn) == ~p"/login"
      refute get_session(conn, :user_id)
    end
  end

  describe "logout" do
    setup :log_in_owner

    test "DELETE /logout clears the session", %{conn: conn} do
      conn = delete(conn, ~p"/logout")

      assert redirected_to(conn) == ~p"/login"
      refute get_session(conn, :user_id)
    end
  end

  describe "route gating" do
    test "live routes redirect to /login when signed out", %{conn: conn} do
      for path <- ["/reader", "/vault", "/foryou", "/dashboard", "/search", "/settings"] do
        conn = get(conn, path)
        assert redirected_to(conn) == ~p"/login", "expected #{path} to require login"
      end
    end
  end
end
