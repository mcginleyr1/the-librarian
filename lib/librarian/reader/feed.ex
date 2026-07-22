defmodule Librarian.Reader.Feed do
  use Ecto.Schema
  import Ecto.Changeset

  schema "feeds" do
    field :title, :string
    field :site_url, :string
    field :feed_url, :string
    field :category, :string
    field :etag, :string
    field :last_modified, :string
    field :last_fetched_at, :utc_datetime
    field :fetch_error, :string
    field :active, :boolean, default: true
    field :fetch_interval_minutes, :integer, default: 120

    # Discovery (P4): the self-managing source pool
    field :origin, :string, default: "manual"
    field :trust_score, :float, default: 0.5
    field :like_rate, :float
    field :discovered_at, :utc_datetime

    belongs_to :user, Librarian.Accounts.User
    has_many :articles, Librarian.Reader.Article

    timestamps(type: :utc_datetime)
  end

  def changeset(feed, attrs) do
    feed
    |> cast(attrs, [
      :title,
      :site_url,
      :feed_url,
      :category,
      :etag,
      :last_modified,
      :last_fetched_at,
      :fetch_error,
      :active,
      :fetch_interval_minutes
    ])
    |> validate_required([:title, :feed_url])
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
