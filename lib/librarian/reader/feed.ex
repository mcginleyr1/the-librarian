defmodule Librarian.Reader.Feed do
  use Ecto.Schema
  import Ecto.Changeset

  @moduledoc """
  A catalog feed, shared across users and fetched once. Per-user state
  (category, active, discovery/probation fields) lives on `Subscription`;
  Reader's queries merge it onto the virtual fields below so callers see
  "their" feed.
  """

  schema "feeds" do
    field :title, :string
    field :site_url, :string
    field :feed_url, :string
    field :etag, :string
    field :last_modified, :string
    field :last_fetched_at, :utc_datetime
    field :fetch_error, :string
    field :fetch_interval_minutes, :integer, default: 120

    # The current user's subscription view, populated by Reader's queries.
    field :subscription_id, :integer, virtual: true
    field :category, :string, virtual: true
    field :active, :boolean, virtual: true, default: true
    field :origin, :string, virtual: true, default: "manual"
    field :trust_score, :float, virtual: true
    field :like_rate, :float, virtual: true
    field :discovered_at, :utc_datetime, virtual: true

    has_many :subscriptions, Librarian.Reader.Subscription
    has_many :articles, Librarian.Reader.Article

    timestamps(type: :utc_datetime)
  end

  def changeset(feed, attrs) do
    feed
    |> cast(attrs, [
      :title,
      :site_url,
      :feed_url,
      :etag,
      :last_modified,
      :last_fetched_at,
      :fetch_error,
      :fetch_interval_minutes
    ])
    |> validate_required([:title, :feed_url])
    |> validate_change(:feed_url, fn :feed_url, url ->
      if URI.parse(url).scheme in ["http", "https"], do: [], else: [feed_url: "must be http(s)"]
    end)
    |> validate_number(:fetch_interval_minutes, greater_than_or_equal_to: 5)
    |> unique_constraint(:feed_url)
    |> clear_conditional_get_on_url_change()
  end

  # A changed URL invalidates the old endpoint's ETag/Last-Modified — keeping
  # them risks the first fetch of the new URL short-circuiting as a 304.
  defp clear_conditional_get_on_url_change(changeset) do
    case {changeset.data.id, get_change(changeset, :feed_url)} do
      {nil, _} -> changeset
      {_, nil} -> changeset
      _ -> change(changeset, etag: nil, last_modified: nil, fetch_error: nil)
    end
  end
end
