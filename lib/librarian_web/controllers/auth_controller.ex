defmodule LibrarianWeb.AuthController do
  use LibrarianWeb, :controller

  plug Ueberauth

  alias Librarian.Accounts
  alias LibrarianWeb.UserAuth

  # The Ueberauth plug handles the request phase (redirect to Google) before
  # this action runs; reaching it means the provider is unknown.
  def request(conn, _params) do
    conn
    |> put_flash(:error, "Unknown login provider.")
    |> redirect(to: ~p"/login")
  end

  # Accounts are matched by email, so an unverified Google email must never
  # sign in: it could claim another person's account.
  def callback(%{assigns: %{ueberauth_auth: auth}} = conn, _params) do
    if email_verified?(auth) and Accounts.allowed_email?(auth.info.email) do
      case Accounts.upsert_user_from_auth(auth) do
        {:ok, user} ->
          UserAuth.log_in_user(conn, user)

        {:error, _changeset} ->
          conn
          |> put_flash(:error, "Could not sign you in. Please try again.")
          |> redirect(to: ~p"/login")
      end
    else
      conn
      |> put_flash(:error, "#{auth.info.email} is not allowed to sign in.")
      |> redirect(to: ~p"/login")
    end
  end

  def callback(%{assigns: %{ueberauth_failure: _failure}} = conn, _params) do
    conn
    |> put_flash(:error, "Google sign-in failed.")
    |> redirect(to: ~p"/login")
  end

  defp email_verified?(%{extra: %{raw_info: %{user: %{"email_verified" => true}}}}), do: true
  defp email_verified?(_auth), do: false

  def delete(conn, _params) do
    UserAuth.log_out_user(conn)
  end
end
