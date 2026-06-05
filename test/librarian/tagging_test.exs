defmodule Librarian.TaggingTest do
  use Librarian.DataCase, async: true

  alias Librarian.Tagging
  alias Librarian.Reader.Article

  defp article(attrs) do
    {:ok, feed} =
      Librarian.Reader.create_feed(%{
        title: "F",
        feed_url: "https://x/#{System.unique_integer([:positive])}"
      })

    now = DateTime.utc_now() |> DateTime.truncate(:second)

    %Article{}
    |> Article.changeset(
      Map.merge(
        %{feed_id: feed.id, guid: "g-#{System.unique_integer([:positive])}", fetched_at: now},
        attrs
      )
    )
    |> Repo.insert!()
  end

  test "derives topics and content type from text" do
    a =
      article(%{
        title: "Building an OTP GenServer supervision tree in Elixir",
        content: "```elixir\n...```"
      })

    tagged = Tagging.tag_article(a)

    assert "beam" in tagged.topics
    assert tagged.content_type in ~w(article tutorial paper release)
    assert tagged.tagged_at
    assert tagged.depth_score >= 0.0
  end

  test "tag_untagged only processes untagged rows" do
    article(%{title: "Postgres index internals and the query planner"})
    assert Tagging.tag_untagged() == 1
    # second run finds nothing new
    assert Tagging.tag_untagged() == 0
  end
end
