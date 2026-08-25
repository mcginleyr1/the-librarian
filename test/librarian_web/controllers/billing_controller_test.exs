defmodule LibrarianWeb.BillingControllerTest do
  # async: false — enable_billing mutates global app env.
  use LibrarianWeb.ConnCase, async: false

  import Librarian.BillingHelpers

  alias Librarian.Accounts
  alias Librarian.Accounts.User
  alias Librarian.Repo

  defp subscriber!(attrs \\ []) do
    defaults = [email: "member-#{System.unique_integer([:positive])}@example.com"]
    Repo.insert!(struct!(User, Keyword.merge(defaults, attrs)))
  end

  describe "billing disabled (self-hosted)" do
    setup :log_in_owner

    test "/subscribe is a no-op redirect home", %{conn: conn} do
      conn = get(conn, ~p"/subscribe")
      assert redirected_to(conn) == ~p"/"
    end
  end

  describe "subscription gate" do
    setup :enable_billing

    test "unsubscribed users are pushed to /subscribe", %{conn: conn} do
      conn = conn |> log_in_user(subscriber!()) |> get(~p"/reader")
      assert redirected_to(conn) == ~p"/subscribe"
    end

    test "active subscribers pass through", %{conn: conn} do
      user = subscriber!(subscription_status: "active")
      conn = conn |> log_in_user(user) |> get(~p"/reader")
      assert html_response(conn, 200)
    end

    test "comped (allowlisted) users pass through without a subscription", %{conn: conn} do
      # The seeded owner is on the allowlist and has no Stripe subscription.
      conn = conn |> log_in_user(Accounts.owner!()) |> get(~p"/reader")
      assert html_response(conn, 200)
    end

    test "the clip API returns 402 for lapsed subscriptions", %{conn: conn} do
      user =
        subscriber!(subscription_status: "canceled")
        |> Accounts.ensure_api_token!()

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{user.api_token}")
        |> post(~p"/api/clips", %{})

      assert json_response(conn, 402)["error"] == "subscription_required"
    end
  end

  describe "/subscribe" do
    setup :enable_billing

    test "shows plan choices to unsubscribed users", %{conn: conn} do
      conn = conn |> log_in_user(subscriber!()) |> get(~p"/subscribe")

      html = html_response(conn, 200)
      assert html =~ "checkout-monthly"
      assert html =~ "checkout-yearly"
    end

    test "redirects active subscribers home", %{conn: conn} do
      user = subscriber!(subscription_status: "active")
      conn = conn |> log_in_user(user) |> get(~p"/subscribe")
      assert redirected_to(conn) == ~p"/"
    end

    test "offers billing management to lapsed subscribers", %{conn: conn} do
      user =
        subscriber!(
          subscription_status: "canceled",
          stripe_customer_id: "cus_1",
          stripe_subscription_id: "sub_1"
        )

      conn = conn |> log_in_user(user) |> get(~p"/subscribe")
      assert html_response(conn, 200) =~ "manage-billing"
    end

    test "success return syncs the checkout session before the webhook lands", %{conn: conn} do
      user = subscriber!()

      Req.Test.stub(Librarian.Billing.Stripe, fn conn ->
        assert conn.request_path == "/v1/checkout/sessions/cs_done"

        Req.Test.json(conn, %{
          "mode" => "subscription",
          "client_reference_id" => Integer.to_string(user.id),
          "customer" => "cus_new",
          "subscription" => %{
            "id" => "sub_new",
            "customer" => "cus_new",
            "status" => "trialing",
            "current_period_end" => System.system_time(:second) + 14 * 86_400
          }
        })
      end)

      conn = conn |> log_in_user(user) |> get(~p"/subscribe?session_id=cs_done")

      assert redirected_to(conn) == ~p"/"
      assert Accounts.get_user(user.id).subscription_status == "trialing"
    end
  end

  describe "POST /subscribe/checkout" do
    setup :enable_billing

    test "redirects to Stripe Checkout", %{conn: conn} do
      Req.Test.stub(Librarian.Billing.Stripe, fn conn ->
        Req.Test.json(conn, %{"id" => "cs_1", "url" => "https://checkout.stripe.test/cs_1"})
      end)

      conn =
        conn
        |> log_in_user(subscriber!())
        |> post(~p"/subscribe/checkout", %{"interval" => "monthly"})

      assert redirected_to(conn) == "https://checkout.stripe.test/cs_1"
    end
  end
end
