defmodule Librarian.Ranking do
  @moduledoc """
  Scores candidate articles against the interest model to produce the ranked
  "For You" stream. Cheap vector + affinity blend over everything; an LLM judge
  (P3) refines only the borderline shortlist. Reserves an exploration budget so
  the stream never collapses into a filter bubble.
  """

  import Ecto.Query

  alias Librarian.Repo
  alias Librarian.{Interest, Stream}
  alias Librarian.Reader.Article

  @exploration 0.15
  @penalty_weight 0.5
  @recency_weight 0.1

  @doc """
  Returns ranked stream entries: maps of `%{article, score, components, why,
  exploration}`.
  """
  def rank_stream(opts \\ []) do
    limit = Keyword.get(opts, :limit, 30)
    topic = Keyword.get(opts, :topic)

    centroids = Interest.centroid_vectors()
    negatives = Interest.negative_embeddings()
    disliked = MapSet.new(Stream.negative_article_ids())

    candidates(topic)
    |> Enum.reject(&MapSet.member?(disliked, &1.id))
    |> Enum.map(&score(&1, centroids, negatives))
    |> Enum.sort_by(& &1.score, :desc)
    |> with_exploration(limit)
  end

  @doc "Distinct topics present across current candidates, for topic-lens chips."
  def available_topics do
    Repo.all(
      from a in Article,
        where: not is_nil(a.embedding) and a.topics != [],
        select: a.topics
    )
    |> List.flatten()
    |> Enum.frequencies()
    |> Enum.sort_by(fn {_t, n} -> -n end)
    |> Enum.map(&elem(&1, 0))
  end

  defp candidates(topic) do
    base =
      from a in Article,
        where: not is_nil(a.embedding),
        order_by: [desc: a.published_at],
        limit: 200,
        preload: [:feed, :read_state]

    query = if topic, do: from(a in base, where: ^topic in a.topics), else: base
    Repo.all(query)
  end

  defp score(article, centroids, negatives) do
    vec = Pgvector.to_list(article.embedding)
    affinity = max_cosine(vec, centroids)
    penalty = max_cosine(vec, negatives)
    recency = recency_boost(article)
    total = affinity - @penalty_weight * penalty + @recency_weight * recency

    %{
      article: article,
      score: total,
      exploration: false,
      components: %{affinity: affinity, penalty: penalty, recency: recency},
      why: why(article, affinity, penalty)
    }
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

  defp recency_boost(%{published_at: nil}), do: 0.0

  defp recency_boost(%{published_at: published_at}) do
    days = DateTime.diff(DateTime.utc_now(), published_at, :day)
    max(0.0, 1.0 - days / 30.0)
  end

  defp max_cosine(_vec, []), do: 0.0
  defp max_cosine(vec, others), do: others |> Enum.map(&cosine(vec, &1)) |> Enum.max()

  defp cosine(a, b) do
    dot = a |> Enum.zip(b) |> Enum.reduce(0.0, fn {x, y}, acc -> acc + x * y end)
    na = :math.sqrt(Enum.reduce(a, 0.0, &(&2 + &1 * &1)))
    nb = :math.sqrt(Enum.reduce(b, 0.0, &(&2 + &1 * &1)))
    if na == 0.0 or nb == 0.0, do: 0.0, else: dot / (na * nb)
  end
end
