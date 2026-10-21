defmodule Librarian.TenancyTest do
  # async: false — shared sandbox so spawned Tasks can reach the DB, and the
  # enex import races the global tags.name unique index (see ImportEvernoteTest).
  use Librarian.DataCase, async: false
  use Oban.Testing, repo: Librarian.Repo

  alias Librarian.{Accounts, Repo, Vault}
  alias Librarian.Accounts.User
  alias Librarian.Workers.BuildGraphWorker

  @enex_fixture Path.expand("../fixtures/sample.enex", __DIR__)

  # DataCase sets the tenant to the owner; add a second user to prove isolation.
  defp second_user do
    Repo.insert!(%User{email: "second-#{System.unique_integer([:positive])}@example.com"})
  end

  describe "bind_tenant/1 across a process boundary" do
    test "re-establishes the captured tenant in a freshly spawned process" do
      owner_id = Accounts.owner!().id
      other = second_user()

      {:ok, _} = Vault.create_note(%{title: "owner note", body: ""}, [])
      Repo.with_user(other.id, fn -> Vault.create_note(%{title: "other note", body: ""}, []) end)

      # Capture the other user's tenant, then run the query in a spawned Task
      # that inherits none of this process's dictionary.
      bound = Repo.with_user(other.id, fn -> Repo.bind_tenant(&Vault.list_notes/0) end)
      titles = bound |> Task.async() |> Task.await() |> Enum.map(& &1.title)

      assert titles == ["other note"]
      # The test process is still scoped to the owner — bind_tenant restored it.
      assert Repo.user_id!() == owner_id
      assert Enum.map(Vault.list_notes(), & &1.title) == ["owner note"]
    end
  end

  describe "cron workers fan out per user" do
    test "the cron run enqueues one job per user" do
      other = second_user()

      assert :ok = perform_job(BuildGraphWorker, %{})

      assert_enqueued(worker: BuildGraphWorker, args: %{user_id: Accounts.owner!().id})
      assert_enqueued(worker: BuildGraphWorker, args: %{user_id: other.id})
    end
  end

  describe "cross-tenant references are refused" do
    test "edges between another user's notes are dropped" do
      other = second_user()

      {a, b} =
        Repo.with_user(other.id, fn ->
          {:ok, a} = Vault.create_note(%{title: "a", body: ""}, [])
          {:ok, b} = Vault.create_note(%{title: "b", body: ""}, [])
          {a, b}
        end)

      :ok = Vault.link_notes(a.id, b.id)
      assert Repo.all(Librarian.Vault.Edge) == []

      # Nothing was planted in their graph, and they can still link the pair.
      Repo.with_user(other.id, fn ->
        assert Vault.related_notes(a.id) == []
        :ok = Vault.link_notes(a.id, b.id)
        assert [%{note: %{id: target}}] = Vault.related_notes(a.id)
        assert target == b.id
      end)
    end

    test "a note can't be filed into another user's notebook" do
      other = second_user()

      {:ok, notebook} =
        Repo.with_user(other.id, fn -> Vault.create_notebook(%{name: "theirs"}) end)

      assert {:error, changeset} =
               Vault.create_note(%{title: "mine", body: "", notebook_id: notebook.id}, [])

      assert %{notebook_id: ["does not exist"]} = errors_on(changeset)
    end

    test "another user's private feed articles are invisible" do
      other = second_user()

      article =
        Repo.with_user(other.id, fn ->
          {:ok, feed} =
            Librarian.Reader.create_feed(%{title: "Private", feed_url: "https://p.example/rss"})

          Repo.insert!(%Librarian.Reader.Article{
            feed_id: feed.id,
            guid: "g1",
            title: "secret",
            fetched_at: DateTime.utc_now(:second)
          })
        end)

      assert_raise Ecto.NoResultsError, fn -> Librarian.Reader.get_article!(article.id) end
      assert {:error, :not_found} = Librarian.Reader.mark_starred(article.id, true)
      assert {:error, :not_found} = Librarian.Stream.record_interaction(article.id, :open)
    end
  end

  describe "imports land in the current tenant, not the owner" do
    test "an enex import scoped to another user writes into that user's vault" do
      other = second_user()

      result =
        Repo.with_user(other.id, fn ->
          Librarian.Release.run_evernote_import(@enex_fixture, "Second Vault")
        end)

      assert result.notes_count > 0

      other_notes = Repo.with_user(other.id, fn -> Vault.list_notes() end)
      assert length(other_notes) == result.notes_count

      # The owner (this process's default tenant) sees none of it.
      assert Vault.list_notes() == []
    end
  end
end
