defmodule Librarian.BillingTest do
  # async: false — enable_billing mutates global app env.
  use Librarian.DataCase, async: false

  import Librarian.BillingHelpers

  alias Librarian.Accounts
  alias Librarian.Accounts.User
  alias Librarian.Billing

  defp user!(attrs \\ []) do
    defaults = [email: "payer-#{System.unique_integer([:positive])}@example.com"]
    Repo.insert!(struct!(User, Keyword.merge(defaults, attrs)))
  end

  describe "with billing disabled (self-hosted default)" do
    test "enabled? is false and everyone is active" do
      refute Billing.enabled?()
      assert Billing.active?(user!())
    end
  end

  describe "active?/1" do
    setup :enable_billing

    test "comped: allowlisted emails never need a subscription" do
      # The seeded owner is on the allowlist and has no Stripe subscription.
      assert Billing.active?(Accounts.owner!())
    end

    test "trialing, active, and past_due keep access" do
      for status <- ~w(trialing active past_due) do
        assert Billing.active?(user!(subscription_status: status)), status
      end
    end

    test "new, canceled, and unpaid users are locked out" do
      refute Billing.active?(user!())
      refute Billing.active?(user!(subscription_status: "canceled"))
      refute Billing.active?(user!(subscription_status: "unpaid"))
      refute Billing.active?(nil)
    end
  end

  describe "verify_webhook/3" do
    setup :enable_billing

    test "accepts a correctly signed payload" do
      payload = ~s({"type":"ping"})

      assert {:ok, %{"type" => "ping"}} =
               Billing.verify_webhook(payload, stripe_signature(payload))
    end

    test "rejects a tampered payload" do
      signature = stripe_signature(~s({"type":"ping"}))
      assert {:error, :invalid_signature} = Billing.verify_webhook(~s({"type":"pong"}), signature)
    end

    test "rejects a stale timestamp (replay)" do
      payload = ~s({"type":"ping"})
      old = System.system_time(:second) - 600

      assert {:error, :invalid_signature} =
               Billing.verify_webhook(payload, stripe_signature(payload, old))
    end

    test "rejects garbage headers" do
      assert {:error, :invalid_signature} = Billing.verify_webhook("{}", "nonsense")
      assert {:error, :invalid_signature} = Billing.verify_webhook("{}", "")
    end
  end

  describe "handle_event/1" do
    setup :enable_billing

    test "checkout.session.completed fetches the subscription and activates the user" do
      user = user!()
      period_end = System.system_time(:second) + 30 * 86_400

      Req.Test.stub(Librarian.Billing.Stripe, fn conn ->
        assert conn.method == "GET"
        assert conn.request_path == "/v1/subscriptions/sub_123"

        Req.Test.json(conn, %{
          "id" => "sub_123",
          "customer" => "cus_123",
          "status" => "trialing",
          # 2025+ API shape: period end lives on the items
          "items" => %{"data" => [%{"current_period_end" => period_end}]}
        })
      end)

      assert :ok =
               Billing.handle_event(%{
                 "type" => "checkout.session.completed",
                 "data" => %{
                   "object" => %{
                     "mode" => "subscription",
                     "client_reference_id" => Integer.to_string(user.id),
                     "customer" => "cus_123",
                     "subscription" => "sub_123"
                   }
                 }
               })

      user = Accounts.get_user(user.id)
      assert user.stripe_customer_id == "cus_123"
      assert user.stripe_subscription_id == "sub_123"
      assert user.subscription_status == "trialing"
      assert DateTime.to_unix(user.subscription_period_end) == period_end
      assert Billing.active?(user)
    end

    test "customer.subscription.updated moves status (e.g. cancellation)" do
      user = user!(stripe_customer_id: "cus_9", subscription_status: "active")

      assert :ok =
               Billing.handle_event(%{
                 "type" => "customer.subscription.deleted",
                 "data" => %{
                   "object" => %{
                     "id" => "sub_9",
                     "customer" => "cus_9",
                     "status" => "canceled",
                     "current_period_end" => System.system_time(:second)
                   }
                 }
               })

      user = Accounts.get_user(user.id)
      assert user.subscription_status == "canceled"
      refute Billing.active?(user)
    end

    test "subscription events for unknown customers are ignored" do
      assert :ok =
               Billing.handle_event(%{
                 "type" => "customer.subscription.updated",
                 "data" => %{"object" => %{"id" => "sub_x", "customer" => "cus_unknown"}}
               })
    end

    test "unknown event types are ignored" do
      assert :ok = Billing.handle_event(%{"type" => "invoice.finalized", "data" => %{}})
    end
  end

  describe "create_checkout_session/4" do
    setup :enable_billing

    test "posts the plan, trial, and user reference to Stripe" do
      user = user!()

      Req.Test.stub(Librarian.Billing.Stripe, fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "/v1/checkout/sessions"

        {:ok, body, conn} = Plug.Conn.read_body(conn)
        params = URI.decode_query(body)

        assert params["mode"] == "subscription"
        assert params["line_items[0][price]"] == "price_monthly"
        assert params["client_reference_id"] == Integer.to_string(user.id)
        assert params["customer_email"] == user.email
        assert params["subscription_data[trial_period_days]"] == "14"
        assert params["success_url"] =~ "session_id={CHECKOUT_SESSION_ID}"

        Req.Test.json(conn, %{"id" => "cs_1", "url" => "https://checkout.stripe.test/cs_1"})
      end)

      assert {:ok, "https://checkout.stripe.test/cs_1"} =
               Billing.create_checkout_session(
                 user,
                 :monthly,
                 "http://localhost/subscribe?session_id={CHECKOUT_SESSION_ID}",
                 "http://localhost/subscribe"
               )
    end

    test "reuses an existing Stripe customer" do
      user = user!(stripe_customer_id: "cus_77")

      Req.Test.stub(Librarian.Billing.Stripe, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        params = URI.decode_query(body)

        assert params["customer"] == "cus_77"
        refute Map.has_key?(params, "customer_email")

        Req.Test.json(conn, %{"id" => "cs_2", "url" => "https://checkout.stripe.test/cs_2"})
      end)

      assert {:ok, _url} =
               Billing.create_checkout_session(user, :yearly, "http://x/s", "http://x/c")
    end
  end

  describe "create_portal_session/2" do
    setup :enable_billing

    test "requires a Stripe customer" do
      assert {:error, :no_customer} = Billing.create_portal_session(user!(), "http://x")
    end
  end
end
