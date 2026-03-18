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
      :active
    ])
    |> validate_required([:title, :feed_url])
    |> unique_constraint(:feed_url)
  end
end
