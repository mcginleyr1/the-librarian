defmodule LibrarianWeb.BillingController do
  use LibrarianWeb, :controller

  alias Librarian.Billing

  plug :redirect_if_billing_disabled

  @doc """
  Plan picker for signed-in users without an active subscription. Also the
  Stripe Checkout return URL: on success Stripe appends `session_id`, which
  we sync eagerly instead of waiting for the webhook.
  """
  def subscribe(conn, params) do
    session_id = params["session_id"]
    if session_id, do: Billing.sync_checkout_session(session_id)

    # Re-read: the sync above may have just activated the subscription.
    user = Librarian.Accounts.get_user(conn.assigns.current_user.id)

    cond do
      Billing.active?(user) and is_binary(session_id) ->
        conn
        |> put_flash(:info, "You're all set — welcome to The Librarian!")
        |> redirect(to: ~p"/")

      Billing.active?(user) ->
        redirect(conn, to: ~p"/")

      true ->
        render(conn, :subscribe,
          page_title: "Choose your plan",
          user: user,
          monthly_price: Billing.monthly_price_usd(),
          yearly_price: Billing.yearly_price_usd(),
          yearly_available?: Billing.yearly_available?(),
          trial_days: Billing.trial_days(),
          lapsed?: Billing.subscribed_before?(user)
        )
    end
  end

  def checkout(conn, %{"interval" => interval}) when interval in ["monthly", "yearly"] do
    user = conn.assigns.current_user
    success_url = url(~p"/subscribe") <> "?session_id={CHECKOUT_SESSION_ID}"
    cancel_url = url(~p"/subscribe")

    case Billing.create_checkout_session(
           user,
           String.to_existing_atom(interval),
           success_url,
           cancel_url
         ) do
      {:ok, checkout_url} ->
        redirect(conn, external: checkout_url)

      {:error, _reason} ->
        conn
        |> put_flash(:error, "Could not start checkout. Please try again.")
        |> redirect(to: ~p"/subscribe")
    end
  end

  @doc "Stripe billing portal: update card, switch plan, cancel, invoices."
  def portal(conn, _params) do
    user = conn.assigns.current_user

    case Billing.create_portal_session(user, url(~p"/settings") <> "?tab=billing") do
      {:ok, portal_url} ->
        redirect(conn, external: portal_url)

      {:error, _reason} ->
        conn
        |> put_flash(:error, "Could not open the billing portal. Please try again.")
        |> redirect(to: ~p"/subscribe")
    end
  end

  defp redirect_if_billing_disabled(conn, _opts) do
    if Billing.enabled?() do
      conn
    else
      conn |> redirect(to: ~p"/") |> halt()
    end
  end
end
