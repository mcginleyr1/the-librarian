defmodule Librarian.Reader.FeedFetcher do
  @moduledoc """
  Fetches and parses RSS/Atom/RDF feeds, upserts articles, updates feed metadata.
  Respects ETag and Last-Modified to avoid redundant downloads.
  """

  require Logger
  import Ecto.Query
  alias Librarian.Repo
  alias Librarian.Reader.{Feed, Article}

  def fetch(%Feed{} = feed) do
    headers = conditional_headers(feed)

    result =
      try do
        Librarian.SafeHTTP.get(feed.feed_url, headers: headers, receive_timeout: 30_000)
      rescue
        e -> {:error, e}
      end

    case result do
      {:ok, %{status: 304}} ->
        now = DateTime.utc_now() |> DateTime.truncate(:second)

        feed
        |> Feed.changeset(%{last_fetched_at: now, fetch_error: nil})
        |> Repo.update()

        :ok

      {:ok, %{status: 200} = response} ->
        ingest(feed, response)

      {:ok, %{status: status}} ->
        record_error(feed, "HTTP #{status}")

      {:error, reason} when is_exception(reason) ->
        record_error(feed, Exception.message(reason))

      {:error, reason} ->
        record_error(feed, inspect(reason))
    end
  end

  defp ingest(feed, response) do
    case Librarian.Reader.FeedParser.parse(response.body, feed.feed_url) do
      {:ok, articles} ->
        etag = get_header(response, "etag")
        last_modified = get_header(response, "last-modified")
        now = DateTime.utc_now() |> DateTime.truncate(:second)

        {:ok, new_count} =
          Repo.transaction(fn ->
            new_count = upsert_articles(feed.id, articles, now)

            feed
            |> Feed.changeset(%{
              etag: etag,
              last_modified: last_modified,
              last_fetched_at: now,
              fetch_error: nil
            })
            |> Repo.update!()

            new_count
          end)

        if new_count > 0 do
          Phoenix.PubSub.broadcast(
            Librarian.PubSub,
            "reader:updates",
            {:feed_updated, feed.id, new_count}
          )
        end

        :ok

      {:error, message} ->
        record_error(feed, "parse error: #{message}")
    end
  end

  # Returns how many of the parsed articles were not already in the database.
  defp upsert_articles(feed_id, articles, now) do
    guids = articles |> Enum.map(& &1[:guid]) |> Enum.reject(&is_nil/1)

    known =
      Repo.all(
        from a in Article,
          where: a.feed_id == ^feed_id and a.guid in ^guids,
          select: a.guid
      )
      |> MapSet.new()

    Enum.each(articles, fn attrs ->
      %Article{}
      |> Article.changeset(Map.merge(attrs, %{feed_id: feed_id, fetched_at: now}))
      |> Repo.insert(
        on_conflict: {:replace, [:title, :url, :content, :summary, :author, :published_at]},
        conflict_target: [:feed_id, :guid]
      )
      |> case do
        {:ok, _article} ->
          :ok

        {:error, changeset} ->
          Logger.warning(
            "Feed #{feed_id}: skipped article #{inspect(attrs[:guid])}: #{inspect(changeset.errors)}"
          )
      end
    end)

    Enum.count(guids, &(not MapSet.member?(known, &1)))
  end

  # Conditional GETs use ETag only. Last-Modified from feed proxies (hnrss.org,
  # FeedBurner, Cloudflare caches) is unreliable — hnrss.org serves a *frozen*
  # Last-Modified with fresh content, so honoring it as If-Modified-Since makes
  # the upstream answer 304 forever and the feed silently stops ingesting.
  # ETag is content-derived; feeds without one simply do a full (cheap) fetch.
  defp conditional_headers(%Feed{etag: etag}) do
    if etag, do: [{"if-none-match", etag}], else: []
  end

  defp get_header(%{headers: headers}, name) do
    case Map.get(headers, name) do
      [value | _] -> value
      value when is_binary(value) -> value
      _ -> nil
    end
  end

  # Stamping last_fetched_at makes a failing feed wait its normal interval
  # instead of being re-enqueued on every scheduler tick.
  defp record_error(feed, message) do
    Logger.warning("Feed #{feed.id} (#{feed.feed_url}) fetch error: #{message}")

    feed
    |> Feed.changeset(%{
      fetch_error: message,
      last_fetched_at: DateTime.utc_now() |> DateTime.truncate(:second)
    })
    |> Repo.update()

    {:error, message}
  end
end
