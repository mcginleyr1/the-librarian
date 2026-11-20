defmodule Librarian.VaultDataIntegrityTest do
  # async: false — mutates the global storage path and Req default options.
  use Librarian.DataCase, async: false

  alias Librarian.{Settings, Storage, Vault}
  alias Librarian.Vault.{Edge, Note, Tag}
  alias Librarian.Workers.ExtractEdgesWorker

  @dims Librarian.Embeddings.dimensions()

  setup do
    tmp = System.tmp_dir!() |> Path.join("librarian_vault_integrity_#{:rand.uniform(999_999)}")
    File.mkdir_p!(tmp)
    previous = Application.fetch_env(:librarian, :storage_path)
    Application.put_env(:librarian, :storage_path, tmp)

    on_exit(fn ->
      case previous do
        {:ok, path} -> Application.put_env(:librarian, :storage_path, path)
        :error -> Application.delete_env(:librarian, :storage_path)
      end

      File.rm_rf!(tmp)
    end)
  end

  defp embed!(note) do
    note
    |> Ecto.Changeset.change(
      embedding: Pgvector.new(List.duplicate(1.0, @dims)),
      graph_indexed_at: DateTime.utc_now(:second)
    )
    |> Repo.update!()
  end

  describe "editing a note" do
    test "resets embedding and graph state when the body changes" do
      {:ok, note} = Vault.create_note(%{title: "T", body: "old"})
      note = embed!(note)

      {:ok, updated} = Vault.update_note(note, %{body: "new"})

      assert updated.embedding == nil
      assert updated.graph_indexed_at == nil
    end

    test "keeps them when only other fields change" do
      {:ok, note} = Vault.create_note(%{title: "T", body: "same"})
      note = embed!(note)

      {:ok, updated} =
        Vault.update_note(note, %{title: "T", body: "same", source_url: "https://x.test"})

      assert updated.embedding != nil
      assert updated.graph_indexed_at != nil
    end
  end

  describe "deleting notes removes their stored files" do
    defp note_with_file!(title, key, body \\ "b") do
      :ok = Storage.put(key, "data")
      {:ok, note} = Vault.create_note(%{title: title, body: body, storage_key: key})
      note
    end

    test "delete_note/1" do
      note = note_with_file!("A", "clips/a.png")
      {:ok, _} = Vault.delete_note(note)
      refute Storage.exists?("clips/a.png")
    end

    test "delete_notes/1" do
      note = note_with_file!("A", "clips/a.png")
      {:ok, 1} = Vault.delete_notes([note.id])
      refute Storage.exists?("clips/a.png")
    end

    test "dedupe_notes/0 keeps a file the surviving copy still uses" do
      _keep = note_with_file!("Same", "clips/shared.png")

      {:ok, _dupe} =
        Vault.create_note(%{title: "Same", body: "b", storage_key: "clips/shared.png"})

      _other = note_with_file!("Other", "clips/other.png", "x")

      {:ok, _dupe2} =
        Vault.create_note(%{title: "Other", body: "x", storage_key: "clips/other2.png"})

      :ok = Storage.put("clips/other2.png", "data")

      assert Vault.dedupe_notes() == 2
      assert Storage.exists?("clips/shared.png")
      assert Storage.exists?("clips/other.png")
      refute Storage.exists?("clips/other2.png")
    end
  end

  test "LLM edges refresh llm edges but leave user edges untouched" do
    {:ok, source} = Vault.create_note(%{title: "Source", body: "s"})
    {:ok, user_target} = Vault.create_note(%{title: "User", body: "u"})
    {:ok, llm_target} = Vault.create_note(%{title: "Llm", body: "l"})
    source = embed!(source)
    embed!(user_target)
    embed!(llm_target)

    {2, _} =
      Vault.upsert_edges([
        %{
          source_note_id: source.id,
          target_note_id: user_target.id,
          kind: "references",
          reason: "mine",
          weight: 1.0,
          origin: "user"
        },
        %{
          source_note_id: source.id,
          target_note_id: llm_target.id,
          kind: "references",
          reason: "stale",
          weight: 0.1,
          origin: "llm"
        }
      ])

    {:ok, _} = Settings.save_settings(%{"anthropic_api_key" => "sk-test"})

    Req.Test.stub(:extract_edges, fn conn ->
      edges =
        for t <- [user_target, llm_target],
            do: %{target_id: t.id, kind: "references", reason: "fresh", weight: 0.9}

      Req.Test.json(conn, %{
        "content" => [%{"type" => "text", "text" => Jason.encode!(%{edges: edges})}],
        "usage" => %{"input_tokens" => 1, "output_tokens" => 1},
        "stop_reason" => "end_turn"
      })
    end)

    previous = Req.default_options()
    Req.default_options(plug: {Req.Test, :extract_edges})
    on_exit(fn -> Application.put_env(:req, :default_options, previous) end)

    assert :ok = ExtractEdgesWorker.perform(%Oban.Job{args: %{"note_id" => source.id}})

    user_edge = Repo.get_by!(Edge, target_note_id: user_target.id)
    assert {user_edge.origin, user_edge.reason, user_edge.weight} == {"user", "mine", 1.0}

    llm_edge = Repo.get_by!(Edge, target_note_id: llm_target.id)
    assert {llm_edge.origin, llm_edge.reason} == {"llm", "fresh"}
  end

  describe "tags on notes" do
    test "are created in bulk, normalised and reused" do
      {:ok, a} = Vault.create_note(%{title: "A"}, [" Elixir ", "elixir", "OTP"])
      {:ok, b} = Vault.create_note(%{title: "B"}, ["otp", "web"])

      assert a.tags |> Enum.map(& &1.name) |> Enum.sort() == ["elixir", "otp"]
      assert b.tags |> Enum.map(& &1.name) |> Enum.sort() == ["otp", "web"]
      assert Repo.aggregate(Tag, :count) == 3
      assert Repo.get!(Note, a.id)
    end
  end
end
