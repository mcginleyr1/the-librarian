defmodule Librarian.Ranking do
  @moduledoc """
  Scores candidate articles against the interest model to produce the ranked
  "For You" stream. Cheap vector + affinity blend over everything; an LLM judge
  (P3) refines only the borderline shortlist. Reserves an exploration budget so
  the stream never collapses into a filter bubble.
  """

  import Ecto.Query

  alias Librarian.Repo
  alias Librarian.Stream
  alias Librarian.Reader.Article

  @exploration 0.15
  @penalty_weight 0.5
  @recency_weight 0.1
  @pool_size 200

  # Ranks the recency-bounded candidate pool entirely in Postgres: affinity is
  # the best cosine similarity to any interest centroid, penalty the best
  # similarity to any disliked article, recency a 30-day linear decay. Returns
  # only scalar scores — embeddings never leave the database. Articles already
  # read (anywhere — reader or For You) are excluded; starring or saving alone
  # keeps an unread article eligible.
  @scored_sql """
  WITH pool AS (
    SELECT a.id, a.embedding, a.published_at
    FROM articles a
    JOIN subscriptions s ON s.feed_id = a.feed_id AND s.active = TRUE AND s.user_id = $9
    WHERE a.embedding IS NOT NULL
      AND ($1::text IS NULL OR $1 = ANY(a.topics))
      AND ($8::text IS NULL OR s.category = $8)
      AND NOT EXISTS (
        SELECT 1 FROM interactions i
        WHERE i.article_id = a.id AND i.user_id = $9 AND i.kind = ANY($2::text[])
      )
      AND NOT EXISTS (
        SELECT 1 FROM read_states rs
        WHERE rs.article_id = a.id AND rs.user_id = $9 AND rs.read_at IS NOT NULL
      )
    ORDER BY a.published_at DESC NULLS LAST
    LIMIT $4
  ),
  neg AS (
    SELECT DISTINCT a.embedding
    FROM articles a
    JOIN interactions i ON i.article_id = a.id AND i.user_id = $9
    WHERE i.kind = ANY($3::text[]) AND a.embedding IS NOT NULL
  ),
  aff AS (
    SELECT p.id, MAX(1 - (p.embedding <=> c.embedding)) AS affinity
    FROM pool p CROSS JOIN interest_centroids c
    WHERE c.user_id = $9
    GROUP BY p.id
  ),
  pen AS (
    SELECT p.id, COALESCE(MAX(1 - (p.embedding <=> n.embedding)), 0.0) AS penalty
    FROM pool p LEFT JOIN neg n ON TRUE
    GROUP BY p.id
  ),
  rec AS (
    SELECT p.id,
      COALESCE(GREATEST(0.0, 1.0 - EXTRACT(EPOCH FROM ((now() AT TIME ZONE 'UTC') - p.published_at)) / (30.0 * 86400.0)), 0.0) AS recency
    FROM pool p
  )
  SELECT p.id,
         COALESCE(aff.affinity, 0.0)::float8,
         COALESCE(pen.penalty, 0.0)::float8,
         rec.recency::float8
  FROM pool p
  LEFT JOIN aff ON aff.id = p.id
  LEFT JOIN pen ON pen.id = p.id
  JOIN rec ON rec.id = p.id
  ORDER BY (COALESCE(aff.affinity, 0.0) - $5 * COALESCE(pen.penalty, 0.0) + $6 * rec.recency) DESC
  LIMIT $7
  """

  @doc """
  Returns ranked stream entries: maps of `%{article, score, components, why,
  exploration}`.
  """
  def rank_stream(opts \\ []) do
    limit = Keyword.get(opts, :limit, 30)
    topic = Keyword.get(opts, :topic)
    category = Keyword.get(opts, :category)

    rows = scored_rows(topic, category, limit * 2)
    articles = articles_by_id(Enum.map(rows, & &1.id))

    rows
    |> Enum.flat_map(fn r ->
      case Map.get(articles, r.id) do
        nil ->
          []

        article ->
          [
            %{
              article: article,
              score: r.affinity - @penalty_weight * r.penalty + @recency_weight * r.recency,
              exploration: false,
              components: %{affinity: r.affinity, penalty: r.penalty, recency: r.recency},
              why: why(article, r.affinity, r.penalty)
            }
          ]
      end
    end)
    |> with_exploration(limit)
  end

  @doc """
  Distinct topics present in the current candidate pool, for topic-lens chips.
  Bounded to the same recency window the stream ranks over, so lenses reflect
  what's actually in front of you rather than all-time topic frequencies.
  """
  def available_topics do
    # explicit user filter: this runs as a subquery, which prepare_query
    # doesn't see
    pool =
      from s in Librarian.Reader.Subscription,
        join: a in Article,
        on: a.feed_id == s.feed_id,
        where: s.user_id == ^Repo.user_id!(),
        where: not is_nil(a.embedding) and s.active == true,
        order_by: [desc_nulls_last: a.published_at],
        limit: @pool_size,
        select: %{topics: a.topics}

    Repo.all(from p in subquery(pool), where: p.topics != [], select: p.topics)
    |> List.flatten()
    |> Enum.frequencies()
    |> Enum.sort_by(fn {_t, n} -> -n end)
    |> Enum.map(&elem(&1, 0))
  end

  defp scored_rows(topic, category, fetch) do
    # scoped: every tenanted table in @scored_sql is filtered by user_id ($9)
    # credo:disable-for-next-line Librarian.CredoChecks.RawSQL
    %{rows: rows} =
      Repo.query!(@scored_sql, [
        topic,
        Stream.consumed_kinds(),
        Stream.negative_kinds(),
        @pool_size,
        @penalty_weight,
        @recency_weight,
        fetch,
        category,
        Repo.user_id!()
      ])

    Enum.map(rows, fn [id, affinity, penalty, recency] ->
      %{id: id, affinity: num(affinity), penalty: num(penalty), recency: num(recency)}
    end)
  end

  # Postgrex returns NaN/Infinity (from a zero-norm embedding) as atoms; treat
  # those as no-signal rather than letting them crash the whole stream.
  defp num(x) when is_float(x), do: x
  defp num(_), do: 0.0

  defp articles_by_id([]), do: %{}

  defp articles_by_id(ids) do
    from(a in Article, where: a.id in ^ids, preload: [:feed, :read_state])
    |> Repo.all()
    |> Map.new(&{&1.id, &1})
  end

  defp why(article, affinity, penalty) do
    cond do
      article.topics && article.topics != [] ->
        "Matches your interest in #{Enum.join(Enum.take(article.topics, 2), ", ")}"

      penalty > affinity ->
        "Similar to things you've passed on — shown to keep your stream broad"

      affinity > 0.4 ->
        "Close to articles you've liked and saved"

      true ->
        "From a source you read"
    end
  end

  # Reserve a fraction of slots for novel (low-affinity) items, so new interests
  # can surface. The rest are the top-scored items.
  defp with_exploration(ranked, limit) when length(ranked) <= limit, do: ranked

  defp with_exploration(ranked, limit) do
    keep = round(limit * (1 - @exploration))
    {top, rest} = Enum.split(ranked, keep)

    explore =
      rest
      |> Enum.shuffle()
      |> Enum.take(limit - keep)
      |> Enum.map(&%{&1 | exploration: true, why: "Exploring — something a bit different"})

    top ++ explore
  end
end
