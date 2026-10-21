defmodule Librarian.Reader do
  @moduledoc """
  The feed reader. Feeds and articles are a shared catalog; subscriptions and
  read/star state are per user, and user-facing queries are scoped to the
  current tenant (see `Librarian.Repo`).
  """

  import Ecto.Query
  alias Librarian.Repo
  alias Librarian.Reader.{Feed, Article, ReadState, Subscription}

  @subscription_keys ~w(category active origin trust_score like_rate discovered_at)a
  # Catalog fields a subscriber may edit; fetch state (etag, last_fetched_at,
  # fetch_error, ...) belongs to the fetcher alone.
  @editable_feed_keys ~w(title feed_url fetch_interval_minutes)a

  # --- tenant-scoped building blocks ---
  #
  # Tenanted schemas can't be joined directly (Repo.prepare_query raises);
  # these subqueries bake the user filter in so left-join semantics survive.

  defp my_subscriptions do
    from s in Subscription, where: s.user_id == ^Repo.user_id!()
  end

  defp my_active_subscriptions do
    from s in my_subscriptions(), where: s.active == true
  end

  defp my_read_states do
    from rs in ReadState, where: rs.user_id == ^Repo.user_id!()
  end

  @doc """
  Articles the user may see: those in feeds they subscribe to, plus anything
  they starred (stars survive unsubscribing). Articles are a shared catalog, so
  every lookup by a client-supplied id must go through this.
  """
  def visible_articles do
    subscribed = from s in my_subscriptions(), select: s.feed_id
    starred = from rs in my_read_states(), where: rs.starred == true, select: rs.article_id

    from a in Article, where: a.feed_id in subquery(subscribed) or a.id in subquery(starred)
  end

  def visible_article?(id), do: Repo.exists?(from a in visible_articles(), where: a.id == ^id)

  # The user's view of the catalog: their subscriptions joined to the feed,
  # with the per-user fields merged onto the feed's virtual fields.
  defp subscribed_feeds do
    from s in Subscription,
      join: f in Feed,
      on: f.id == s.feed_id,
      select: f,
      select_merge: %{
        subscription_id: s.id,
        category: s.category,
        active: s.active,
        origin: s.origin,
        trust_score: s.trust_score,
        like_rate: s.like_rate,
        discovered_at: s.discovered_at
      }
  end

  def list_active_feeds do
    Repo.all(from [s, f] in subscribed_feeds(), where: s.active == true)
  end

  @doc """
  Feeds with at least one active subscriber (any user — fetching is a
  system-level concern) whose fetch interval has elapsed.
  """
  def list_due_feeds(now \\ DateTime.utc_now()) do
    any_active = from s in Subscription, where: s.active == true, select: s.feed_id

    Repo.all(
      from f in Feed,
        where: f.id in subquery(any_active),
        where:
          is_nil(f.last_fetched_at) or
            fragment(
              "? + make_interval(mins => ?) <= ?",
              f.last_fetched_at,
              f.fetch_interval_minutes,
              ^now
            )
    )
  end

  @doc """
  Active feeds grouped into `{category, feeds}` tuples, ordered by the user's
  saved category order (Settings). Unordered categories follow alphabetically,
  with Uncategorized last.
  """
  def list_feeds_by_category do
    position = Librarian.Settings.category_order() |> Enum.with_index() |> Map.new()

    Repo.all(from [s, f] in subscribed_feeds(), where: s.active == true, order_by: f.title)
    |> Enum.group_by(& &1.category)
    |> Enum.sort_by(fn {category, _feeds} ->
      {Map.get(position, category, map_size(position)), is_nil(category), category || ""}
    end)
  end

  def get_feed!(id), do: Repo.one!(from [s, f] in subscribed_feeds(), where: f.id == ^id)

  @doc "Subscribes the current user to a feed, creating the catalog row if it's new."
  def create_feed(attrs) do
    {sub_attrs, feed_attrs} = split_attrs(attrs)

    Repo.transaction(fn ->
      with {:ok, feed} <- upsert_catalog_feed(feed_attrs),
           {:ok, sub} <- insert_subscription(feed, sub_attrs, []) do
        merge_subscription(feed, sub)
      else
        {:error, changeset} -> Repo.rollback(changeset)
      end
    end)
  end

  @doc """
  Like `create_feed/1`, but an existing subscription is left untouched and
  signalled with `{:ok, %Feed{id: nil}}` (so imports can count it as skipped).
  """
  def upsert_feed(attrs) do
    {sub_attrs, feed_attrs} = split_attrs(attrs)

    Repo.transaction(fn ->
      with {:ok, feed} <- upsert_catalog_feed(feed_attrs),
           {:ok, %Subscription{id: id} = sub} when not is_nil(id) <-
             insert_subscription(feed, sub_attrs,
               on_conflict: :nothing,
               conflict_target: [:user_id, :feed_id]
             ) do
        merge_subscription(feed, sub)
      else
        {:ok, %Subscription{id: nil}} -> %Feed{id: nil}
        {:error, changeset} -> Repo.rollback(changeset)
      end
    end)
  end

  defp upsert_catalog_feed(attrs) do
    changeset = Feed.changeset(%Feed{}, attrs)

    case Ecto.Changeset.get_field(changeset, :feed_url) do
      nil ->
        Repo.insert(changeset)

      url ->
        if feed = Repo.get_by(Feed, feed_url: url), do: {:ok, feed}, else: Repo.insert(changeset)
    end
  end

  defp insert_subscription(feed, attrs, opts) do
    %Subscription{user_id: Repo.user_id!(), feed_id: feed.id}
    |> Subscription.changeset(attrs)
    |> Repo.insert(opts)
  end

  defp merge_subscription(feed, %Subscription{} = s) do
    %{
      feed
      | subscription_id: s.id,
        category: s.category,
        active: s.active,
        origin: s.origin,
        trust_score: s.trust_score,
        like_rate: s.like_rate,
        discovered_at: s.discovered_at
    }
  end

  defp split_attrs(attrs) do
    sub_keys = Enum.flat_map(@subscription_keys, &[&1, Atom.to_string(&1)])
    Map.split(Map.new(attrs), sub_keys)
  end

  def list_articles(feed_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)
    offset = Keyword.get(opts, :offset, 0)
    unread_only = Keyword.get(opts, :unread_only, false)

    query =
      from a in visible_articles(),
        where: a.feed_id == ^feed_id,
        order_by: [desc: a.fetched_at, desc: a.published_at],
        limit: ^limit,
        offset: ^offset,
        preload: [:feed, :read_state]

    query =
      if unread_only do
        from a in query,
          left_join: rs in subquery(my_read_states()),
          on: rs.article_id == a.id,
          where: is_nil(rs.id) or is_nil(rs.read_at)
      else
        query
      end

    Repo.all(query)
  end

  def get_article!(id) do
    Repo.one!(from a in visible_articles(), where: a.id == ^id, preload: [:feed, :read_state])
  end

  def list_all_unread_articles(opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)
    offset = Keyword.get(opts, :offset, 0)

    Repo.all(
      from a in Article,
        join: s in subquery(my_active_subscriptions()),
        on: s.feed_id == a.feed_id,
        left_join: rs in subquery(my_read_states()),
        on: rs.article_id == a.id,
        where: is_nil(rs.id) or is_nil(rs.read_at),
        order_by: [desc: a.fetched_at, desc: a.published_at],
        limit: ^limit,
        offset: ^offset,
        preload: [:feed, :read_state]
    )
  end

  def list_articles_by_category(category, opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)
    offset = Keyword.get(opts, :offset, 0)
    unread_only = Keyword.get(opts, :unread_only, false)

    category_subs =
      if is_nil(category) do
        from s in my_active_subscriptions(), where: is_nil(s.category)
      else
        from s in my_active_subscriptions(), where: s.category == ^category
      end

    query =
      from a in Article,
        join: s in subquery(category_subs),
        on: s.feed_id == a.feed_id,
        order_by: [desc: a.fetched_at, desc: a.published_at],
        limit: ^limit,
        offset: ^offset,
        preload: [:feed, :read_state]

    query =
      if unread_only do
        from [a, _s] in query,
          left_join: rs in subquery(my_read_states()),
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
        join: rs in subquery(my_read_states()),
        on: rs.article_id == a.id,
        where: rs.starred == true,
        order_by: [desc: a.published_at],
        preload: [:feed, :read_state]
    )
  end

  @doc "Ids of the feeds the user's active subscriptions file under `category`."
  def feed_ids_for_category(nil) do
    Repo.all(
      from s in Subscription, where: s.active == true and is_nil(s.category), select: s.feed_id
    )
  end

  def feed_ids_for_category(category) do
    Repo.all(
      from s in Subscription,
        where: s.active == true and s.category == ^category,
        select: s.feed_id
    )
  end

  def count_unread_by_feed do
    Repo.all(
      from a in Article,
        join: s in subquery(my_active_subscriptions()),
        on: s.feed_id == a.feed_id,
        left_join: rs in subquery(my_read_states()),
        on: rs.article_id == a.id,
        where: is_nil(rs.id) or is_nil(rs.read_at),
        group_by: a.feed_id,
        select: {a.feed_id, count(a.id)}
    )
    |> Map.new()
  end

  def unread_count(feed_id) do
    Repo.one(
      from a in visible_articles(),
        left_join: rs in subquery(my_read_states()),
        on: rs.article_id == a.id,
        where: a.feed_id == ^feed_id and (is_nil(rs.id) or is_nil(rs.read_at)),
        select: count(a.id)
    )
  end

  def mark_all_read do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    article_ids =
      Repo.all(
        from a in Article,
          join: s in subquery(my_active_subscriptions()),
          on: s.feed_id == a.feed_id,
          left_join: rs in subquery(my_read_states()),
          on: rs.article_id == a.id,
          where: is_nil(rs.id) or is_nil(rs.read_at),
          select: a.id
      )

    bulk_mark_read(article_ids, now)
  end

  def mark_all_read_for_feed(feed_id) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    article_ids =
      Repo.all(
        from a in Article,
          left_join: rs in subquery(my_read_states()),
          on: rs.article_id == a.id,
          where: a.feed_id == ^feed_id and (is_nil(rs.id) or is_nil(rs.read_at)),
          select: a.id
      )

    bulk_mark_read(article_ids, now)
  end

  def mark_all_read_for_category(category) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    category_subs =
      if is_nil(category) do
        from s in my_active_subscriptions(), where: is_nil(s.category)
      else
        from s in my_active_subscriptions(), where: s.category == ^category
      end

    article_ids =
      Repo.all(
        from a in Article,
          join: s in subquery(category_subs),
          on: s.feed_id == a.feed_id,
          left_join: rs in subquery(my_read_states()),
          on: rs.article_id == a.id,
          where: is_nil(rs.id) or is_nil(rs.read_at),
          select: a.id
      )

    bulk_mark_read(article_ids, now)
  end

  defp bulk_mark_read(article_ids, now) do
    user_id = Repo.user_id!()

    article_ids
    |> Enum.map(
      &%{
        article_id: &1,
        user_id: user_id,
        read_at: now,
        starred: false,
        inserted_at: now,
        updated_at: now
      }
    )
    |> Enum.chunk_every(10_000)
    |> Enum.each(fn chunk ->
      Repo.insert_all(ReadState, chunk,
        on_conflict: [set: [read_at: now, updated_at: now]],
        conflict_target: [:user_id, :article_id]
      )
    end)
  end

  def mark_read(article_id) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    upsert_read_state(article_id, %{read_at: now}, set: [read_at: now])
  end

  def mark_starred(article_id, starred) do
    upsert_read_state(article_id, %{starred: starred}, set: [starred: starred])
  end

  defp upsert_read_state(article_id, attrs, on_conflict) do
    if visible_article?(article_id) do
      %ReadState{user_id: Repo.user_id!()}
      |> ReadState.changeset(Map.put(attrs, :article_id, article_id))
      |> Repo.insert(on_conflict: on_conflict, conflict_target: [:user_id, :article_id])
    else
      {:error, :not_found}
    end
  end

  @doc """
  Catalog GC (cross-tenant by design): deletes old articles that every current
  subscriber of their feed has read and that nobody has starred — one user's
  reading never removes an article someone else hasn't seen.
  """
  def delete_stale_read_articles(days_old \\ 365) do
    cutoff = DateTime.utc_now() |> DateTime.add(-days_old, :day) |> DateTime.truncate(:second)

    read =
      from rs in ReadState,
        where: rs.article_id == parent_as(:article).id and not is_nil(rs.read_at)

    starred =
      from rs in ReadState, where: rs.article_id == parent_as(:article).id and rs.starred == true

    {count, _} =
      Repo.delete_all(
        from(a in Article,
          as: :article,
          where: a.published_at < ^cutoff,
          where: exists(read),
          where: not exists(starred),
          where:
            fragment(
              """
              NOT EXISTS (
                SELECT 1 FROM subscriptions s
                WHERE s.feed_id = ? AND NOT EXISTS (
                  SELECT 1 FROM read_states rs
                  WHERE rs.article_id = ? AND rs.user_id = s.user_id AND rs.read_at IS NOT NULL))
              """,
              a.feed_id,
              a.id
            )
        )
      )

    count
  end

  def list_all_feeds do
    Repo.all(from [s, f] in subscribed_feeds(), order_by: [s.category, f.title])
  end

  @doc """
  Updates the user's view of a feed. Per-user attrs (category, active, …) land
  on the subscription; `@editable_feed_keys` update the shared catalog row,
  which only a feed's sole subscriber may change. Anything else is ignored.
  """
  def update_feed(%Feed{} = feed, attrs) do
    {sub_attrs, feed_attrs} = split_attrs(attrs)

    feed_attrs =
      Map.take(feed_attrs, @editable_feed_keys ++ Enum.map(@editable_feed_keys, &to_string/1))

    with {:ok, updated} <- apply_feed_update(feed, feed_attrs),
         {:ok, sub} <- apply_subscription_update(feed, sub_attrs) do
      {:ok, if(sub, do: merge_subscription(updated, sub), else: updated)}
    end
  end

  defp apply_feed_update(feed, attrs) when map_size(attrs) == 0, do: {:ok, feed}

  defp apply_feed_update(feed, attrs) do
    changeset = Feed.changeset(feed, attrs)

    if changeset.changes != %{} and shared_feed?(feed) do
      {:error,
       Enum.reduce(Map.keys(changeset.changes), changeset, fn field, cs ->
         Ecto.Changeset.add_error(cs, field, "is shared with other subscribers")
       end)}
    else
      Repo.update(changeset)
    end
  end

  defp shared_feed?(feed) do
    others =
      from s in Subscription, where: s.feed_id == ^feed.id and s.user_id != ^Repo.user_id!()

    Repo.exists?(others, skip_tenant: true)
  end

  defp apply_subscription_update(_feed, attrs) when map_size(attrs) == 0, do: {:ok, nil}

  defp apply_subscription_update(feed, attrs) do
    case Repo.one(from s in Subscription, where: s.feed_id == ^feed.id) do
      nil -> {:ok, nil}
      sub -> sub |> Subscription.changeset(attrs) |> Repo.update()
    end
  end

  @doc """
  Unsubscribes from a feed; the catalog row (and its articles) is deleted only
  when no subscriber remains.
  """
  def delete_feed(%Feed{} = feed) do
    # The row lock makes a concurrent subscribe wait on (then fail against) the
    # deleted feed instead of being cascaded away with it.
    Repo.transaction(fn ->
      Repo.one!(from f in Feed, where: f.id == ^feed.id, lock: "FOR UPDATE")
      Repo.delete_all(from s in Subscription, where: s.feed_id == ^feed.id)

      remaining = from s in Subscription, where: s.feed_id == ^feed.id

      if Repo.exists?(remaining, skip_tenant: true),
        do: feed,
        else: Repo.delete!(%Feed{id: feed.id})
    end)
  end

  @doc """
  Activate or deactivate every feed in a category at once. Deactivated feeds
  stop fetching and disappear from Reader and For You, but keep their articles
  and interaction history (unlike `delete_feed/1`).
  """
  def set_category_active(category, active?) when is_boolean(active?) do
    {count, _} =
      Repo.update_all(from(s in Subscription, where: s.category == ^category),
        set: [active: active?]
      )

    count
  end

  def list_categories do
    Repo.all(from s in Subscription, select: s.category, distinct: true, order_by: s.category)
    |> Enum.reject(&is_nil/1)
  end

  def fetch_feed(feed_id) do
    feed = Repo.get!(Feed, feed_id)
    Librarian.Reader.FeedFetcher.fetch(feed)
  end
end
