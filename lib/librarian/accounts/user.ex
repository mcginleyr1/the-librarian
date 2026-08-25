defmodule Librarian.Accounts.User do
  use Ecto.Schema
  import Ecto.Changeset

  schema "users" do
    field :email, :string
    field :name, :string
    field :avatar_url, :string
    field :provider, :string, default: "google"
    field :provider_uid, :string
    field :api_token, :string, redact: true

    field :stripe_customer_id, :string
    field :stripe_subscription_id, :string
    field :subscription_status, :string
    field :subscription_period_end, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  def changeset(user, attrs) do
    user
    |> cast(attrs, [:email, :name, :avatar_url, :provider, :provider_uid])
    |> validate_required([:email])
    |> update_change(:email, &String.downcase/1)
    |> unique_constraint(:email)
    |> unique_constraint([:provider, :provider_uid])
  end

  @doc "Billing fields are set from Stripe data only, never from user input."
  def subscription_changeset(user, attrs) do
    user
    |> cast(attrs, [
      :stripe_customer_id,
      :stripe_subscription_id,
      :subscription_status,
      :subscription_period_end
    ])
    |> unique_constraint(:stripe_customer_id)
  end
end
