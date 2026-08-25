defmodule Librarian.Billing.Stripe do
  @moduledoc """
  Minimal Stripe API client over Req: bearer auth, form-encoded bodies
  (Stripe's nested params use bracketed keys, e.g. `line_items[0][price]`).
  Tests inject a `Req.Test` plug via the `:stripe_req_options` app env.
  """

  @base_url "https://api.stripe.com"

  def post(path, params), do: request(method: :post, url: path, form: params)

  def get(path, params \\ %{}), do: request(method: :get, url: path, params: params)

  defp request(opts) do
    [
      base_url: @base_url,
      auth: {:bearer, secret_key!()},
      receive_timeout: 30_000
    ]
    |> Keyword.merge(opts)
    |> Keyword.merge(Application.get_env(:librarian, :stripe_req_options, []))
    |> Req.request()
    |> case do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 -> {:ok, body}
      {:ok, %Req.Response{status: status, body: body}} -> {:error, {:stripe_error, status, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp secret_key! do
    Application.get_env(:librarian, :billing, [])[:stripe_secret_key] ||
      raise "Stripe is not configured — set STRIPE_SECRET_KEY"
  end
end
