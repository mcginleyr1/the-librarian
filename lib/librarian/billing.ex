defmodule Librarian.Billing do
  @moduledoc """
  Stripe-backed subscriptions for hosted, multi-user deployments.

  Billing is opt-in: it turns on when a Stripe secret key and monthly price id
  are configured (`STRIPE_SECRET_KEY` / `STRIPE_PRICE_ID_MONTHLY`). With it
  off, the app keeps its self-hosted behavior — sign-in restricted to
  `:allowed_emails`, no payment required. With it on, anyone may sign in;
  access to the app requires an active subscription, and allowlisted emails
  are comped (they're the operators).

  Stripe state lives on the user row and is written only from Stripe data:
  webhooks (`handle_event/1`) are the source of truth, and the checkout
  success return syncs eagerly (`sync_checkout_session/1`) so new subscribers
  don't race the webhook.
  """

  alias Librarian.Accounts
  alias Librarian.Accounts.User
  alias Librarian.Billing.Stripe

  # `past_due` keeps access during Stripe's dunning retries; Stripe moves the
  # subscription to `canceled`/`unpaid` when retries are exhausted.
  @active_statuses ~w(trialing active past_due)
  @webhook_tolerance_seconds 300

  ## Configuration

  def enabled? do
    present?(config()[:stripe_secret_key]) and present?(config()[:monthly_price_id])
  end

  def monthly_price_usd, do: config()[:monthly_price_usd]
  def yearly_price_usd, do: config()[:yearly_price_usd]
  def trial_days, do: config()[:trial_days] || 0
  def yearly_available?, do: present?(config()[:yearly_price_id])

  ## Access

  @doc "May this user use the app? Always true when billing is disabled."
  def active?(%User{} = user) do
    not enabled?() or comped?(user) or user.subscription_status in @active_statuses
  end

  def active?(_), do: false

  @doc "Allowlisted (operator) accounts never pay."
  def comped?(user), do: Accounts.admin?(user)

  @doc "Has this user ever had a subscription (e.g. lapsed vs. brand new)?"
  def subscribed_before?(%User{stripe_subscription_id: id}), do: is_binary(id)

  ## Checkout & portal

  @doc """
  Creates a Stripe Checkout session for a new subscription.
  Returns `{:ok, redirect_url}`.
  """
  def create_checkout_session(%User{} = user, interval, success_url, cancel_url)
      when interval in [:monthly, :yearly] do
    params =
      %{
        "mode" => "subscription",
        "client_reference_id" => Integer.to_string(user.id),
        "line_items[0][price]" => price_id!(interval),
        "line_items[0][quantity]" => "1",
        "allow_promotion_codes" => "true",
        "success_url" => success_url,
        "cancel_url" => cancel_url
      }
      |> put_customer(user)
      |> put_trial()

    with {:ok, %{"url" => url}} <- Stripe.post("/v1/checkout/sessions", params) do
      {:ok, url}
    end
  end

  @doc "Creates a Stripe billing-portal session. Returns `{:ok, redirect_url}`."
  def create_portal_session(%User{stripe_customer_id: customer_id}, return_url)
      when is_binary(customer_id) do
    params = %{"customer" => customer_id, "return_url" => return_url}

    with {:ok, %{"url" => url}} <- Stripe.post("/v1/billing_portal/sessions", params) do
      {:ok, url}
    end
  end

  def create_portal_session(_user, _return_url), do: {:error, :no_customer}

  @doc "Eager sync on return from checkout, so access doesn't wait on the webhook."
  def sync_checkout_session(session_id) when is_binary(session_id) do
    with {:ok, session} <-
           Stripe.get("/v1/checkout/sessions/#{session_id}", %{"expand[]" => "subscription"}) do
      sync_session(session)
    end
  end

  ## Webhooks

  @doc """
  Verifies a `Stripe-Signature` header (HMAC-SHA256 over `t.payload`) and
  decodes the payload. Returns `{:ok, event}` or `{:error, :invalid_signature}`.
  """
  def verify_webhook(payload, signature_header, now \\ System.system_time(:second)) do
    secret = config()[:stripe_webhook_secret]

    with true <- present?(secret),
         {timestamp, signatures} <- parse_signature_header(signature_header),
         true <- abs(now - timestamp) <= @webhook_tolerance_seconds,
         expected = compute_signature(timestamp, payload, secret),
         true <- Enum.any?(signatures, &Plug.Crypto.secure_compare(&1, expected)) do
      Jason.decode(payload)
    else
      _ -> {:error, :invalid_signature}
    end
  end

  @doc """
  Applies a verified webhook event. Unknown event types and events for
  unknown customers return `:ok` (nothing to do); Stripe API failures return
  `{:error, reason}` so the webhook can 500 and Stripe retries.
  """
  def handle_event(%{"type" => "checkout.session.completed", "data" => %{"object" => session}}) do
    sync_session(session)
  end

  def handle_event(%{"type" => "customer.subscription." <> _, "data" => %{"object" => sub}}) do
    case Accounts.get_user_by_stripe_customer_id(sub["customer"]) do
      # An early subscription.created can beat checkout.session.completed;
      # the session event carries the user reference and will sync fully.
      nil -> :ok
      user -> apply_subscription(user, sub["customer"], sub)
    end
  end

  def handle_event(_event), do: :ok

  ## Internals

  defp sync_session(%{"mode" => "subscription"} = session) do
    with %User{} = user <- session_user(session),
         {:ok, sub} <- fetch_subscription(session["subscription"]) do
      apply_subscription(user, session["customer"], sub)
    else
      nil -> :ok
      error -> error
    end
  end

  defp sync_session(_session), do: :ok

  defp session_user(session) do
    case Integer.parse(to_string(session["client_reference_id"] || "")) do
      {user_id, ""} -> Accounts.get_user(user_id)
      _ -> Accounts.get_user_by_stripe_customer_id(session["customer"])
    end
  end

  defp fetch_subscription(%{"id" => _} = sub), do: {:ok, sub}
  defp fetch_subscription(id) when is_binary(id), do: Stripe.get("/v1/subscriptions/#{id}")
  defp fetch_subscription(_), do: {:error, :no_subscription}

  defp apply_subscription(%User{} = user, customer_id, sub) do
    Accounts.update_subscription!(user, %{
      stripe_customer_id: customer_id || sub["customer"],
      stripe_subscription_id: sub["id"],
      subscription_status: sub["status"],
      subscription_period_end: period_end(sub)
    })

    :ok
  end

  # Older API versions put current_period_end on the subscription; since
  # 2025-03-31 it lives on each subscription item.
  defp period_end(%{"current_period_end" => ts}) when is_integer(ts), do: DateTime.from_unix!(ts)

  defp period_end(%{"items" => %{"data" => items}}) when is_list(items) do
    items
    |> Enum.map(& &1["current_period_end"])
    |> Enum.filter(&is_integer/1)
    |> case do
      [] -> nil
      stamps -> stamps |> Enum.max() |> DateTime.from_unix!()
    end
  end

  defp period_end(_sub), do: nil

  defp put_customer(params, %User{stripe_customer_id: id}) when is_binary(id) do
    Map.put(params, "customer", id)
  end

  defp put_customer(params, %User{email: email}), do: Map.put(params, "customer_email", email)

  defp put_trial(params) do
    case trial_days() do
      days when is_integer(days) and days > 0 ->
        Map.put(params, "subscription_data[trial_period_days]", Integer.to_string(days))

      _ ->
        params
    end
  end

  defp price_id!(:monthly), do: config()[:monthly_price_id] || raise("no monthly price id")
  defp price_id!(:yearly), do: config()[:yearly_price_id] || raise("no yearly price id")

  defp parse_signature_header(header) when is_binary(header) do
    parts =
      header
      |> String.split(",")
      |> Enum.map(&String.split(String.trim(&1), "=", parts: 2))

    timestamp =
      Enum.find_value(parts, fn
        ["t", value] ->
          case Integer.parse(value) do
            {ts, ""} -> ts
            _ -> nil
          end

        _ ->
          nil
      end)

    signatures = for ["v1", signature] <- parts, do: signature

    if timestamp && signatures != [], do: {timestamp, signatures}
  end

  defp parse_signature_header(_header), do: nil

  defp compute_signature(timestamp, payload, secret) do
    :crypto.mac(:hmac, :sha256, secret, "#{timestamp}.#{payload}")
    |> Base.encode16(case: :lower)
  end

  defp config, do: Application.get_env(:librarian, :billing, [])

  defp present?(value), do: is_binary(value) and value != ""
end
