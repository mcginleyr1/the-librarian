defmodule Librarian.StreamTest do
  use Librarian.DataCase, async: true

  alias Librarian.{Reader, Stream}

  defp article_fixture do
    {:ok, feed} =
      Reader.create_feed(%{
        title: "Feed",
        feed_url: "https://x/#{System.unique_integer([:positive])}"
      })

    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Repo.insert!(
      Librarian.Reader.Article.changeset(%Librarian.Reader.Article{}, %{
        feed_id: feed.id,
        guid: "g-#{System.unique_integer([:positive])}",
        title: "Article",
        fetched_at: now
      })
    )
  end

  test "record_interaction stores an event and rejects unknown kinds" do
    article = article_fixture()

    assert {:ok, interaction} = Stream.record_interaction(article.id, :like)
    assert interaction.kind == "like"
    assert interaction.occurred_at

    assert {:error, changeset} = Stream.record_interaction(article.id, :bogus)
    refute changeset.valid?
  end

  test "signal_summary and positive/negative partitions reflect logged events" do
    a = article_fixture()
    b = article_fixture()

    Stream.record_interaction(a.id, :like)
    Stream.record_interaction(a.id, :save)
    Stream.record_interaction(b.id, :dislike)

    assert %{"like" => 1, "save" => 1, "dislike" => 1} = Stream.signal_summary()
    assert Enum.sort(Stream.positive_article_ids()) == Enum.sort([a.id])
    assert Stream.negative_article_ids() == [b.id]
  end
end
