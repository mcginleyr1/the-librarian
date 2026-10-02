defmodule Librarian.BillingHelpers do
  @moduledoc """
  Turns Stripe billing on for a test (`setup :enable_billing`) and restores
  the app env after. Tests using this mutate global config, so they must be
  `async: false`.
  """

  import ExUnit.Callbacks, only: [on_exit: 1]

  @stripe_overrides [
    stripe_secret_key: "sk_test_x",
    stripe_webhook_secret: "whsec_test",
    monthly_price_id: "price_monthly",
    yearly_price_id: "price_yearly"
  ]

  def enable_billing(_context \\ %{}) do
    previous = Application.fetch_env!(:librarian, :billing)
    Application.put_env(:librarian, :billing, Keyword.merge(previous, @stripe_overrides))
    on_exit(fn -> Application.put_env(:librarian, :billing, previous) end)
    :ok
  end

  @doc "A Stripe-format signature header for `payload`."
  def stripe_signature(payload, timestamp \\ System.system_time(:second)) do
    signature =
      :crypto.mac(:hmac, :sha256, "whsec_test", "#{timestamp}.#{payload}")
      |> Base.encode16(case: :lower)

    "t=#{timestamp},v1=#{signature}"
  end
end
