defmodule Librarian.Reader.Subscription do
  use Ecto.Schema
  import Ecto.Changeset

  @moduledoc """
  A user's membership of a catalog feed, carrying everything personal about
  it: category, active, and the discovery/probation state. The feed row itself
  is shared across users and fetched once.
  """

  schema "subscriptions" do
    field :category, :string
    field :active, :boolean, default: true

    # Discovery (P4): the self-managing source pool
    field :origin, :string, default: "manual"
    field :trust_score, :float, default: 0.5
    field :like_rate, :float
    field :discovered_at, :utc_datetime

    belongs_to :user, Librarian.Accounts.User
    belongs_to :feed, Librarian.Reader.Feed

    timestamps(type: :utc_datetime)
  end

  def changeset(subscription, attrs) do
    subscription
    |> cast(attrs, [:category, :active, :origin, :trust_score, :like_rate, :discovered_at])
    |> unique_constraint(:feed_url, name: :subscriptions_user_id_feed_id_index)
  end
end
