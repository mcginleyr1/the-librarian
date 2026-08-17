defmodule Librarian.TenancyTest do
  use Librarian.DataCase, async: true

  alias Librarian.{Reader, Repo, Settings, Stream, Vault}
  alias Librarian.Accounts.User
  alias Librarian.Reader.Article

  defp second_user! do
    Repo.insert!(%User{email: "second-#{System.unique_integer([:positive])}@example.com"})
  end

  defp article!(feed_id) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    %Article{}
    |> Article.changeset(%{
      feed_id: feed_id,
      guid: "g-#{System.unique_integer([:positive])}",
      title: "Shared catalog article",
      fetched_at: now
    })
    |> Repo.insert!()
  end

  test "subscriptions and categories are invisible to another user" do
    {:ok, _} =
      Reader.create_feed(%{title: "Mine", feed_url: "https://mine.example/rss", category: "Tech"})

    other = second_user!()

    Repo.with_user(other.id, fn ->
      assert Reader.list_all_feeds() == []
      assert Reader.list_categories() == []
      assert Reader.list_feeds_by_category() == []
    end)
  end

  test "vault notes don't leak across users" do
    {:ok, _} = Vault.create_note(%{title: "Secret plan", body: "the body"}, [])
    other = second_user!()

    Repo.with_user(other.id, fn ->
      assert Vault.list_notes() == []
      assert Vault.search("Secret") == []
    end)
  end

  test "two users share a catalog feed but keep independent read state" do
    {:ok, feed} =
      Reader.create_feed(%{title: "Shared", feed_url: "https://shared.example/rss"})

    article = article!(feed.id)
    other = second_user!()

    Repo.with_user(other.id, fn ->
      # subscribing to the same URL reuses the catalog row
      {:ok, their_view} =
        Reader.create_feed(%{title: "Shared", feed_url: "https://shared.example/rss"})

      assert their_view.id == feed.id
      Reader.mark_read(article.id)
      assert Reader.unread_count(feed.id) == 0
    end)

    # the other user's read state doesn't mark it read for the owner
    assert Reader.unread_count(feed.id) == 1
  end

  test "interactions and settings are per user" do
    {:ok, feed} = Reader.create_feed(%{title: "F", feed_url: "https://f.example/rss"})
    Stream.record_interaction(article!(feed.id).id, :like)
    {:ok, _} = Settings.save_settings(%{discovery_paused: true})
    other = second_user!()

    Repo.with_user(other.id, fn ->
      assert Stream.signal_summary() == %{}
      refute Settings.discovery_paused?()
      {:ok, _} = Settings.save_settings(%{discovery_paused: false})
    end)

    assert Settings.discovery_paused?()
  end

  test "two users can use the same tag name without collision" do
    {:ok, note_a} = Vault.create_note(%{title: "A note", body: "x"}, ["shared-tag"])
    other = second_user!()

    Repo.with_user(other.id, fn ->
      {:ok, note_b} = Vault.create_note(%{title: "B note", body: "y"}, ["shared-tag"])
      assert Enum.map(note_b.tags, & &1.name) == ["shared-tag"]
      assert Enum.all?(note_b.tags, &(&1.user_id == other.id))
    end)

    assert Enum.map(note_a.tags, & &1.name) == ["shared-tag"]
  end

  test "candidate sources for the same domain stay per user" do
    [mine] =
      Librarian.Discovery.register_intent_sources(
        [%{"domain" => "example.org", "title" => "E"}],
        "my private query"
      )

    other = second_user!()

    Repo.with_user(other.id, fn ->
      [theirs] =
        Librarian.Discovery.register_intent_sources(
          [%{"domain" => "example.org", "title" => "E"}],
          "their query"
        )

      assert theirs.id != mine.id
      assert theirs.user_id == other.id
    end)

    reloaded = Repo.get!(Librarian.Discovery.CandidateSource, mine.id)
    assert reloaded.intent_query == "my private query"
  end

  test "tenanted queries without a tenant raise instead of leaking" do
    Repo.with_user(nil, fn ->
      assert_raise RuntimeError, ~r/no tenant set/, fn -> Vault.list_notes() end
    end)
  end

  test "joining a tenanted schema directly raises" do
    import Ecto.Query

    assert_raise ArgumentError, ~r/user-scoped subquery/, fn ->
      Repo.all(
        from a in Article,
          join: s in Librarian.Reader.Subscription,
          on: s.feed_id == a.feed_id
      )
    end
  end
end
