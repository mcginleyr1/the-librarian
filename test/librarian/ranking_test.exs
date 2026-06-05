defmodule Librarian.RankingTest do
  use Librarian.DataCase, async: true

  alias Librarian.{Interest, Ranking, Stream}
  alias Librarian.Reader.Article

  # Two clearly separable directions in embedding space (normalized).
  defp beam_vec, do: unit([1.0, 0.2, 0.0])
  defp db_vec, do: unit([0.0, 0.2, 1.0])

  defp unit(v) do
    # pad to 384 dims and L2-normalize
    full = v ++ List.duplicate(0.0, 384 - length(v))
    norm = :math.sqrt(Enum.reduce(full, 0.0, &(&2 + &1 * &1)))
    Enum.map(full, &(&1 / norm))
  end

  defp article(vec, title) do
    {:ok, feed} =
      Librarian.Reader.create_feed(%{
        title: "F",
        feed_url: "https://x/#{System.unique_integer([:positive])}"
      })

    now = DateTime.utc_now() |> DateTime.truncate(:second)

    %Article{}
    |> Article.changeset(%{
      feed_id: feed.id,
      guid: "g-#{System.unique_integer([:positive])}",
      title: title,
      fetched_at: now,
      published_at: now
    })
    |> Ecto.Changeset.put_change(:embedding, Pgvector.new(vec))
    |> Repo.insert!()
  end

  test "rebuild builds centroids and ranks liked-similar content highest" do
    beam = article(beam_vec(), "OTP supervision")
    _db = article(db_vec(), "Postgres internals")

    # user likes the BEAM article -> it's a positive exemplar
    Stream.record_interaction(beam.id, :like)
    assert {:ok, k} = Interest.rebuild()
    assert k >= 1

    ranked = Ranking.rank_stream(limit: 10)
    assert length(ranked) == 2
    titles = Enum.map(ranked, & &1.article.title)
    # BEAM article should outrank the unrelated DB one
    assert hd(titles) == "OTP supervision"
  end
end
