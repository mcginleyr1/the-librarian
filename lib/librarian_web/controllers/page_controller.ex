defmodule LibrarianWeb.PageController do
  use LibrarianWeb, :controller

  alias Librarian.Billing

  def home(conn, _params) do
    cond do
      conn.assigns[:current_user] ->
        redirect(conn, to: "/reader")

      Billing.enabled?() ->
        render(conn, :landing,
          page_title: "The Librarian — your feeds and notes, one tool",
          monthly_price: Billing.monthly_price_usd(),
          yearly_price: Billing.yearly_price_usd(),
          trial_days: Billing.trial_days()
        )

      # Self-hosted: no public marketing page, straight to sign-in.
      true ->
        redirect(conn, to: "/login")
    end
  end

  def login(conn, _params) do
    render(conn, :login, page_title: "Sign in")
  end
end
