defmodule Librarian.TenancyTest do
  # async: false — shared sandbox so spawned Tasks can reach the DB, and the
  # enex import races the global tags.name unique index (see ImportEvernoteTest).
  use Librarian.DataCase, async: false

  alias Librarian.{Accounts, Repo, Vault}
  alias Librarian.Accounts.User

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

  describe "Accounts.each_user/1" do
    test "runs the body once per user, each scoped to that user's data" do
      owner_id = Accounts.owner!().id
      other = second_user()

      {:ok, _} = Vault.create_note(%{title: "o1", body: ""}, [])
      {:ok, _} = Vault.create_note(%{title: "o2", body: ""}, [])
      Repo.with_user(other.id, fn -> Vault.create_note(%{title: "b1", body: ""}, []) end)

      parent = self()

      Accounts.each_user(fn ->
        send(parent, {:seen, Repo.user_id!(), length(Vault.list_notes())})
      end)

      assert_received {:seen, ^owner_id, 2}
      assert_received {:seen, other_id, 1} when other_id == other.id
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
