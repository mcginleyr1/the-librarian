defmodule Librarian.Interest do
  @moduledoc """
  The learned interest model. Positive signals (likes, saves) plus the existing
  vault notes form the positive corpus; k-means over their embeddings yields a
  handful of interest centroids (your distinct topic clusters). Disliked items
  form the negative set used as a ranking penalty.

  Call `rebuild/0` after signal changes.
  """

  import Ecto.Query

  alias Librarian.Repo
  alias Librarian.Stream
  alias Librarian.Interest.Centroid
  alias Librarian.Reader.Article
  alias Librarian.Vault.Note

  @clusters 8
  @iterations 8
  # Behaviour must outweigh the archive: deliberate endorsements count 10x,
  # and the vault contributes only its most recent notes so a large historical
  # import can't pin the centroids against live feedback.
  @strong_weight 10
  @vault_cap 300

  @doc "Recomputes interest centroids from the current positive corpus."
  # One transaction, so concurrent rebuilds and ranking reads never see an
  # empty or doubled set of centroids.
  def rebuild do
    positives = positive_embeddings()

    Repo.transaction(fn ->
      Repo.delete_all(Centroid)
      if positives == [], do: 0, else: insert_centroids(positives)
    end)
  end

  defp insert_centroids(positives) do
    k = min(@clusters, length(positives))
    {centroids, counts} = kmeans(positives, k)
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    user_id = Repo.user_id!()

    # Drop empty clusters: their centroid is the zero vector, which makes
    # cosine distance undefined (NaN) in the SQL ranking.
    centroids
    |> Enum.zip(counts)
    |> Enum.reject(fn {_vector, count} -> count == 0 end)
    |> Enum.with_index(1)
    |> Enum.map(fn {{vector, count}, i} ->
      Repo.insert!(%Centroid{
        label: "Cluster #{i}",
        embedding: Pgvector.new(vector),
        member_count: count,
        user_id: user_id,
        inserted_at: now,
        updated_at: now
      })
    end)
    |> length()
  end

  def centroids, do: Repo.all(from c in Centroid, order_by: [desc: c.member_count])

  @doc "Topic frequencies across tagged articles, most common first."
  def topic_frequencies do
    Repo.all(from a in Article, where: a.topics != [], select: a.topics)
    |> List.flatten()
    |> Enum.frequencies()
    |> Enum.sort_by(fn {_topic, n} -> -n end)
  end

  @doc """
  Regenerates a human-readable interest profile from the learned model, so it
  stays inspectable and hand-editable. Returns markdown.
  """
  def regenerate_profile_doc do
    summary = Librarian.Stream.signal_summary()
    clusters = centroids()
    topics = topic_frequencies()

    """
    # Learned Interest Profile

    _Regenerated from your behaviour — no longer hand-written._

    ## Signal so far

    - 👍 likes: #{Map.get(summary, "like", 0)}
    - 💾 saves: #{Map.get(summary, "save", 0)}
    - 👎 dislikes: #{Map.get(summary, "dislike", 0)}
    - 👁 opens: #{Map.get(summary, "open", 0)}

    ## Interest clusters (#{length(clusters)})

    #{Enum.map_join(clusters, "\n", fn c -> "- **#{c.label}** — #{c.member_count} exemplars" end)}

    ## Top topics

    #{Enum.map_join(Enum.take(topics, 10), "\n", fn {t, n} -> "- #{t} (#{n})" end)}
    """
  end

  def centroid_vectors do
    Enum.map(centroids(), &Pgvector.to_list(&1.embedding))
  end

  @doc """
  Embeddings of positively-signalled articles plus the most recent vault notes.
  Level-2 signals (likes/saves) are weighted by repetition so deliberate
  endorsements pull centroids hardest; the vault is capped so it acts as a
  prior rather than drowning out behaviour.
  """
  def positive_embeddings do
    strong = article_embeddings(Stream.positive_article_ids())
    weak = article_embeddings(Stream.weak_positive_article_ids())
    Enum.concat(List.duplicate(strong, @strong_weight)) ++ note_embeddings() ++ weak
  end

  def negative_embeddings do
    article_embeddings(Stream.negative_article_ids())
  end

  defp article_embeddings([]), do: []

  defp article_embeddings(ids) do
    Repo.all(
      from a in Article, where: a.id in ^ids and not is_nil(a.embedding), select: a.embedding
    )
    |> Enum.map(&Pgvector.to_list/1)
  end

  defp note_embeddings do
    Repo.all(
      from n in Note,
        where: not is_nil(n.embedding),
        order_by: [desc: n.updated_at],
        limit: @vault_cap,
        select: n.embedding
    )
    |> Enum.map(&Pgvector.to_list/1)
  end

  # Minimal k-means over L2-normalized embeddings (Euclidean ~ cosine).
  # Returns {list_of_centroid_lists, list_of_member_counts}.
  defp kmeans(points, k) do
    tensor = Nx.tensor(points)
    n = Nx.axis_size(tensor, 0)
    seed_rows = for i <- 0..(k - 1), do: div(i * n, k)
    init = Nx.take(tensor, Nx.tensor(seed_rows))

    final =
      Enum.reduce(1..@iterations, init, fn _, cs ->
        assignment = assign_clusters(tensor, cs)
        update_centroids(tensor, assignment, k)
      end)

    assignment = assign_clusters(tensor, final)
    counts = cluster_counts(assignment, k)
    {Nx.to_list(final), counts}
  end

  defp assign_clusters(points, centroids) do
    p2 = Nx.sum(Nx.pow(points, 2), axes: [1]) |> Nx.new_axis(1)
    c2 = Nx.sum(Nx.pow(centroids, 2), axes: [1]) |> Nx.new_axis(0)
    cross = Nx.dot(points, Nx.transpose(centroids))
    distances = Nx.add(Nx.subtract(p2, Nx.multiply(2, cross)), c2)
    Nx.argmin(distances, axis: 1)
  end

  defp update_centroids(points, assignment, k) do
    onehot = Nx.equal(Nx.new_axis(assignment, 1), Nx.iota({1, k}))
    counts = Nx.sum(onehot, axes: [0]) |> Nx.max(1) |> Nx.new_axis(1)
    sums = Nx.dot(Nx.transpose(onehot), points)
    Nx.divide(sums, counts)
  end

  defp cluster_counts(assignment, k) do
    list = Nx.to_flat_list(assignment)
    Enum.map(0..(k - 1), fn j -> Enum.count(list, &(&1 == j)) end)
  end
end
