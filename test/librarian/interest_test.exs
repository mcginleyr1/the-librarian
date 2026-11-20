defmodule Librarian.InterestTest do
  use Librarian.DataCase, async: true

  alias Librarian.{Interest, Reader}
  alias Librarian.Accounts.User
  alias Librarian.Reader.Article

  defp article(feed, topics) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    %Article{topics: topics}
    |> Article.changeset(%{
      feed_id: feed.id,
      guid: "g-#{System.unique_integer([:positive])}",
      title: "A",
      fetched_at: now
    })
    |> Repo.insert!()
  end

  defp feed do
    {:ok, feed} =
      Reader.create_feed(%{
        title: "F",
        feed_url: "https://t.example/#{System.unique_integer([:positive])}"
      })

    feed
  end

  test "topic_frequencies counts the user's visible articles, most common first" do
    mine = feed()
    article(mine, ["elixir", "otp"])
    article(mine, ["elixir"])
    article(mine, [])

    assert Interest.topic_frequencies() == [{"elixir", 2}, {"otp", 1}]
  end

  test "topic_frequencies ignores feeds only other users follow" do
    other = Repo.insert!(%User{email: "o-#{System.unique_integer([:positive])}@example.com"})
    theirs = Repo.with_user(other.id, &feed/0)
    article(theirs, ["secret"])
    article(feed(), ["public"])

    assert Interest.topic_frequencies() == [{"public", 1}]
  end

  test "regenerate_profile_doc accepts precomputed topics" do
    assert Interest.regenerate_profile_doc([{"rust", 3}]) =~ "- rust (3)"
  end
end
