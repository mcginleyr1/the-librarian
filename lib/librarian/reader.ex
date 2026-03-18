defmodule Librarian.Reader do
  import Ecto.Query
  alias Librarian.Repo
  alias Librarian.Reader.{Feed, Article, ReadState}

  def list_active_feeds do
    Repo.all(from f in Feed, where: f.active == true)
  end

  def list_feeds_by_category do
    Repo.all(from f in Feed, where: f.active == true, order_by: [:category, :title])
    |> Enum.group_by(& &1.category)
  end

  def get_feed!(id), do: Repo.get!(Feed, id)

  def create_feed(attrs) do
    %Feed{}
    |> Feed.changeset(attrs)
    |> Repo.insert()
  end

  def upsert_feed(attrs) do
    %Feed{}
    |> Feed.changeset(attrs)
    |> Repo.insert(on_conflict: :nothing, conflict_target: :feed_url)
  end

  def list_articles(feed_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)
    offset = Keyword.get(opts, :offset, 0)
    unread_only = Keyword.get(opts, :unread_only, false)

    query =
      from a in Article,
        where: a.feed_id == ^feed_id,
        order_by: [desc: a.published_at],
        limit: ^limit,
        offset: ^offset,
        preload: [:feed, :read_state]

    query =
      if unread_only do
        from a in query,
          left_join: rs in ReadState,
          on: rs.article_id == a.id,
          where: is_nil(rs.id) or is_nil(rs.read_at)
      else
        query
      end

    Repo.all(query)
  end

  def get_article!(id) do
    Repo.get!(Article, id) |> Repo.preload([:feed, :read_state])
  end

  def list_all_unread_articles(opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)

    Repo.all(
      from a in Article,
        join: f in assoc(a, :feed),
        where: f.active == true,
        left_join: rs in ReadState,
        on: rs.article_id == a.id,
        where: is_nil(rs.id) or is_nil(rs.read_at),
        order_by: [desc: a.published_at],
        limit: ^limit,
        preload: [:feed, :read_state]
    )
  end

  def list_articles_by_category(category, opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)
    unread_only = Keyword.get(opts, :unread_only, false)

    query =
      if is_nil(category) do
        from a in Article,
          join: f in assoc(a, :feed),
          where: is_nil(f.category) and f.active == true,
          order_by: [desc: a.published_at],
          limit: ^limit,
          preload: [:feed, :read_state]
      else
        from a in Article,
          join: f in assoc(a, :feed),
          where: f.category == ^category and f.active == true,
          order_by: [desc: a.published_at],
          limit: ^limit,
          preload: [:feed, :read_state]
      end

    query =
      if unread_only do
        from [a, _f] in query,
          left_join: rs in ReadState,
          on: rs.article_id == a.id,
          where: is_nil(rs.id) or is_nil(rs.read_at)
      else
        query
      end

    Repo.all(query)
  end

  def list_starred_articles do
    Repo.all(
      from a in Article,
        join: rs in ReadState,
        on: rs.article_id == a.id,
        where: rs.starred == true,
        order_by: [desc: a.published_at],
        preload: [:feed, :read_state]
    )
  end

  def count_unread_by_feed do
    Repo.all(
      from a in Article,
        join: f in assoc(a, :feed),
        where: f.active == true,
        left_join: rs in ReadState,
        on: rs.article_id == a.id,
        where: is_nil(rs.id) or is_nil(rs.read_at),
        group_by: a.feed_id,
        select: {a.feed_id, count(a.id)}
    )
    |> Map.new()
  end

  def unread_count(feed_id) do
    Repo.one(
      from a in Article,
        left_join: rs in ReadState,
        on: rs.article_id == a.id,
        where: a.feed_id == ^feed_id and (is_nil(rs.id) or is_nil(rs.read_at)),
        select: count(a.id)
    )
  end

  def mark_all_read do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    article_ids = Repo.all(from a in Article, join: f in assoc(a, :feed), where: f.active == true, select: a.id)
    bulk_mark_read(article_ids, now)
  end

  def mark_all_read_for_feed(feed_id) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    article_ids = Repo.all(from a in Article, where: a.feed_id == ^feed_id, select: a.id)
    bulk_mark_read(article_ids, now)
  end

  def mark_all_read_for_category(category) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    article_ids =
      if is_nil(category) do
        Repo.all(
          from a in Article,
            join: f in assoc(a, :feed),
            where: is_nil(f.category) and f.active == true,
            select: a.id
        )
      else
        Repo.all(
          from a in Article,
            join: f in assoc(a, :feed),
            where: f.category == ^category and f.active == true,
            select: a.id
        )
      end

    bulk_mark_read(article_ids, now)
  end

  defp bulk_mark_read(article_ids, now) do
    entries = Enum.map(article_ids, &%{article_id: &1, read_at: now, starred: false, inserted_at: now, updated_at: now})

    Repo.insert_all(ReadState, entries,
      on_conflict: [set: [read_at: now, updated_at: now]],
      conflict_target: :article_id
    )
  end

  def mark_read(article_id) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    %ReadState{}
    |> ReadState.changeset(%{article_id: article_id, read_at: now})
    |> Repo.insert(
      on_conflict: [set: [read_at: now]],
      conflict_target: :article_id
    )
  end

  def mark_starred(article_id, starred) do
    %ReadState{}
    |> ReadState.changeset(%{article_id: article_id, starred: starred})
    |> Repo.insert(
      on_conflict: [set: [starred: starred]],
      conflict_target: :article_id
    )
  end

  def list_all_feeds do
    Repo.all(from f in Feed, order_by: [:category, :title])
  end

  def update_feed(%Feed{} = feed, attrs) do
    feed
    |> Feed.changeset(attrs)
    |> Repo.update()
  end

  def delete_feed(%Feed{} = feed) do
    Repo.delete(feed)
  end

  def list_categories do
    Repo.all(from f in Feed, select: f.category, distinct: true, order_by: f.category)
    |> Enum.reject(&is_nil/1)
  end

  def fetch_feed(feed_id) do
    feed = get_feed!(feed_id)
    Librarian.Reader.FeedFetcher.fetch(feed)
  end
end
