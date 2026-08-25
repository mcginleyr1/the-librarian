defmodule LibrarianWeb.StripeWebhookControllerTest do
  # async: false — enable_billing mutates global app env.
  use LibrarianWeb.ConnCase, async: false

  import Librarian.BillingHelpers

  alias Librarian.Accounts
  alias Librarian.Accounts.User

  setup :enable_billing

  defp post_webhook(conn, payload, signature) do
    conn
    |> put_req_header("content-type", "application/json")
    |> put_req_header("stripe-signature", signature)
    |> post(~p"/webhooks/stripe", payload)
  end

  test "a signed subscription event updates the user", %{conn: conn} do
    user =
      Librarian.Repo.insert!(%User{
        email: "hook@example.com",
        stripe_customer_id: "cus_hook",
        subscription_status: "active"
      })

    payload =
      Jason.encode!(%{
        "type" => "customer.subscription.updated",
        "data" => %{
          "object" => %{
            "id" => "sub_hook",
            "customer" => "cus_hook",
            "status" => "past_due",
            "current_period_end" => System.system_time(:second) + 86_400
          }
        }
      })

    conn = post_webhook(conn, payload, stripe_signature(payload))

    assert response(conn, 200)
    assert Accounts.get_user(user.id).subscription_status == "past_due"
  end

  test "a bad signature is rejected without touching data", %{conn: conn} do
    payload = Jason.encode!(%{"type" => "customer.subscription.updated"})

    conn = post_webhook(conn, payload, "t=1,v1=bogus")

    assert response(conn, 400)
  end

  test "webhooks need no session or CSRF token", %{conn: conn} do
    payload = Jason.encode!(%{"type" => "ping"})

    conn = post_webhook(conn, payload, stripe_signature(payload))

    assert response(conn, 200)
  end
end
