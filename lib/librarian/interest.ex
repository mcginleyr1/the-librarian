defmodule Librarian.Interest do
  @moduledoc """
  The learned interest model. Positive signals (likes, saves) plus the existing
  vault notes form the positive corpus; k-means over their embeddings yields a
  handful of interest centroids (your distinct topic clusters). Disliked items
  form the negative set used as a ranking penalty.

  The hand-written `knowledge/profiles/*.md` are the cold-start prior; once real
  signal exists, this replaces them. Call `rebuild/0` after signal changes.
  """

  import Ecto.Query

  alias Librarian.Repo
  alias Librarian.Stream
  alias Librarian.Interest.Centroid
  alias Librarian.Reader.Article
  alias Librarian.Vault.Note

  @clusters 4
  @iterations 8

  @doc "Recomputes interest centroids from the current positive corpus."
  def rebuild do
    positives = positive_embeddings()
    Repo.delete_all(Centroid)

    if positives == [] do
      {:ok, 0}
    else
      k = min(@clusters, length(positives))
      {centroids, counts} = kmeans(positives, k)
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      centroids
      |> Enum.zip(counts)
      |> Enum.with_index(1)
      |> Enum.each(fn {{vector, count}, i} ->
        Repo.insert!(%Centroid{
          label: "Cluster #{i}",
          embedding: Pgvector.new(vector),
          member_count: count,
          inserted_at: now,
          updated_at: now
        })
      end)

      {:ok, k}
    end
  end

  def centroids, do: Repo.all(from c in Centroid, order_by: [desc: c.member_count])

  def centroid_vectors do
    Enum.map(centroids(), &Pgvector.to_list(&1.embedding))
  end

  @doc "Embeddings of positively-signalled articles plus all vault notes."
  def positive_embeddings do
    article_embeddings(Stream.positive_article_ids()) ++ note_embeddings()
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
    Repo.all(from n in Note, where: not is_nil(n.embedding), select: n.embedding)
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
