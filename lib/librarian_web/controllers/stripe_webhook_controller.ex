defmodule LibrarianWeb.StripeWebhookController do
  use LibrarianWeb, :controller

  alias Librarian.Billing
  alias LibrarianWeb.CacheBodyReader

  require Logger

  def create(conn, _params) do
    payload = CacheBodyReader.raw_body(conn) || ""
    signature = conn |> get_req_header("stripe-signature") |> List.first("")

    with {:ok, event} <- Billing.verify_webhook(payload, signature),
         :ok <- Billing.handle_event(event) do
      send_resp(conn, 200, "ok")
    else
      {:error, :invalid_signature} ->
        send_resp(conn, 400, "invalid signature")

      {:error, reason} ->
        # 500 makes Stripe retry with backoff.
        Logger.error("Stripe webhook processing failed: #{inspect(reason)}")
        send_resp(conn, 500, "processing failed")
    end
  end
end
