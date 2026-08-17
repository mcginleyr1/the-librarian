defmodule Librarian.DemoSeed do
  @moduledoc """
  Seeds a reviewable demo from baked data (`priv/repo/demo_seed_data.json`):
  sample feeds, articles + vault notes with precomputed embeddings, interest
  centroids, and a handful of like/save/dislike signals.

  Because embeddings and centroids are baked, this needs no model at runtime —
  the personalized stream, dashboard, and discovery all work immediately.
  Idempotent: does nothing if any feed already exists.
  """

  alias Librarian.Repo
  alias Librarian.Reader.{Article, Feed, Subscription}
  alias Librarian.Vault.Note
  alias Librarian.Interest.Centroid
  alias Librarian.{Discovery, Stream, Tagging}

  require Logger

  @doc "Seeds demo data unless the database already has feeds."
  def run do
    if Repo.aggregate(Feed, :count) > 0 do
      {:ok, :already_seeded}
    else
      owner_id = Librarian.Accounts.owner!().id

      Repo.with_user(owner_id, fn ->
        data = load()
        now = DateTime.utc_now() |> DateTime.truncate(:second)

        feeds = insert_feeds(data["feeds"], now, owner_id)
        insert_articles(data["articles"], feeds, now)
        insert_notes(data["notes"], now, owner_id)
        insert_centroids(data["centroids"], now, owner_id)

        Tagging.tag_untagged()
        Discovery.harvest_link_graph()

        Logger.info(
          "DemoSeed: seeded #{map_size(feeds)} feeds and #{length(data["articles"])} articles"
        )

        {:ok, :seeded}
      end)
    end
  end

  defp load do
    Path.join(:code.priv_dir(:librarian), "repo/demo_seed_data.json")
    |> File.read!()
    |> Jason.decode!()
  end

  defp insert_feeds(feeds, now, owner_id) do
    Map.new(feeds, fn f ->
      origin = if f["category"] == "Infrastructure", do: "discovered", else: "manual"

      feed =
        Repo.insert!(%Feed{
          title: f["title"],
          site_url: f["site_url"],
          feed_url: f["feed_url"],
          inserted_at: now,
          updated_at: now
        })

      Repo.insert!(%Subscription{
        user_id: owner_id,
        feed_id: feed.id,
        category: f["category"],
        origin: origin,
        trust_score: if(origin == "discovered", do: 0.3, else: 0.5),
        discovered_at: if(origin == "discovered", do: now, else: nil),
        inserted_at: now,
        updated_at: now
      })

      {f["title"], feed}
    end)
  end

  defp insert_articles(articles, feeds, now) do
    articles
    |> Enum.with_index()
    |> Enum.each(fn {a, i} ->
      feed = Map.fetch!(feeds, a["feed"])
      published = DateTime.add(now, -i * 7200, :second)

      article =
        Repo.insert!(%Article{
          feed_id: feed.id,
          guid: "demo-#{i}",
          title: a["title"],
          url: a["url"],
          content: a["content"],
          published_at: published,
          fetched_at: now,
          embedding: Pgvector.new(a["embedding"]),
          inserted_at: now
        })

      if a["signal"], do: Stream.record_interaction(article.id, a["signal"])
    end)
  end

  defp insert_notes(notes, now, owner_id) do
    Enum.each(notes, fn n ->
      Repo.insert!(%Note{
        title: n["title"],
        body: n["body"],
        clip_mode: "markdown",
        embedding: Pgvector.new(n["embedding"]),
        user_id: owner_id,
        inserted_at: now,
        updated_at: now
      })
    end)
  end

  defp insert_centroids(centroids, now, owner_id) do
    Repo.delete_all(Centroid)

    Enum.each(centroids, fn c ->
      Repo.insert!(%Centroid{
        label: c["label"],
        embedding: Pgvector.new(c["embedding"]),
        member_count: c["member_count"],
        user_id: owner_id,
        inserted_at: now,
        updated_at: now
      })
    end)
  end
end
