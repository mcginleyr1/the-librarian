defmodule Librarian.Reader.FeedFetcher do
  @moduledoc """
  Fetches and parses RSS/Atom/RDF feeds, upserts articles, updates feed metadata.
  Respects ETag and Last-Modified to avoid redundant downloads.
  """

  require Logger
  alias Librarian.Repo
  alias Librarian.Reader.{Feed, Article}

  def fetch(%Feed{} = feed) do
    headers = conditional_headers(feed)

    result =
      try do
        Req.get(feed.feed_url, headers: headers, redirect: true, receive_timeout: 30_000)
      rescue
        e -> {:error, e}
      end

    case result do
      {:ok, %{status: 304}} ->
        :ok

      {:ok, %{status: 200} = response} ->
        etag = get_header(response, "etag")
        last_modified = get_header(response, "last-modified")
        now = DateTime.utc_now() |> DateTime.truncate(:second)

        articles = Librarian.Reader.FeedParser.parse(response.body, feed.feed_url)

        Repo.transaction(fn ->
          upsert_articles(feed.id, articles, now)

          feed
          |> Feed.changeset(%{
            etag: etag,
            last_modified: last_modified,
            last_fetched_at: now,
            fetch_error: nil
          })
          |> Repo.update!()
        end)

        :ok

      {:ok, %{status: status}} ->
        record_error(feed, "HTTP #{status}")

      {:error, reason} ->
        record_error(feed, Exception.message(reason))
    end
  end

  defp upsert_articles(feed_id, articles, now) do
    Enum.each(articles, fn attrs ->
      %Article{}
      |> Article.changeset(Map.merge(attrs, %{feed_id: feed_id, fetched_at: now}))
      |> Repo.insert(
        on_conflict: {:replace, [:title, :url, :content, :summary, :author, :published_at]},
        conflict_target: [:feed_id, :guid]
      )
    end)
  end

  defp conditional_headers(%Feed{etag: etag, last_modified: lm}) do
    []
    |> then(fn h -> if etag, do: [{"if-none-match", etag} | h], else: h end)
    |> then(fn h -> if lm, do: [{"if-modified-since", lm} | h], else: h end)
  end

  defp get_header(%{headers: headers}, name) do
    case Map.get(headers, name) do
      [value | _] -> value
      value when is_binary(value) -> value
      _ -> nil
    end
  end

  defp record_error(feed, message) do
    Logger.warning("Feed #{feed.id} (#{feed.feed_url}) fetch error: #{message}")

    feed
    |> Feed.changeset(%{fetch_error: message})
    |> Repo.update()

    {:error, message}
  end
end
