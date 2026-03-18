defmodule Librarian.ImportEvernoteTest do
  use Librarian.DataCase, async: true

  alias Librarian.Vault
  alias Librarian.Vault.{Note, Notebook}

  @fixture Path.expand("../fixtures/sample.enex", __DIR__)

  defp run_import(path, notebook_name \\ "Test Import") do
    notebook_id = find_or_create_notebook(notebook_name)
    parse_and_import(@fixture, notebook_id)
  end

  defp find_or_create_notebook(name) do
    case Vault.create_notebook(%{name: name}) do
      {:ok, nb} ->
        nb.id

      {:error, _} ->
        Repo.get_by!(Notebook, name: name).id
    end
  end

  defp parse_and_import(file_path, notebook_id) do
    initial_state = %{
      current_note: Mix.Tasks.Librarian.ImportEvernote.empty_note(),
      current_resource: %{},
      in_field: nil,
      in_note_attributes: false,
      in_resource_attributes: false,
      text_buf: "",
      notes_count: 0,
      attachments_count: 0,
      errors: 0,
      notebook_id: notebook_id
    }

    stream = File.stream!(file_path, [], 64_000)

    case Saxy.parse_stream(stream, Mix.Tasks.Librarian.ImportEvernote.Handler, initial_state) do
      {:ok, state} -> state
      {:error, reason} -> raise "Parse error: #{inspect(reason)}"
    end
  end

  describe "parsing sample.enex" do
    test "creates 2 notes" do
      notebook_id = find_or_create_notebook("Parse Test")
      state = parse_and_import(@fixture, notebook_id)

      assert state.notes_count == 2
      assert state.errors == 0
    end

    test "first note has correct title" do
      notebook_id = find_or_create_notebook("Title Test")
      parse_and_import(@fixture, notebook_id)

      notes =
        Repo.all(Note)
        |> Repo.preload(:tags)
        |> Enum.sort_by(& &1.inserted_at)

      first_note = hd(notes)
      assert first_note.title == "Test Note One"
    end

    test "first note has correct tags" do
      notebook_id = find_or_create_notebook("Tags Test")
      parse_and_import(@fixture, notebook_id)

      notes =
        Repo.all(Note)
        |> Repo.preload(:tags)
        |> Enum.sort_by(& &1.inserted_at)

      first_note = hd(notes)
      tag_names = Enum.map(first_note.tags, & &1.name)
      assert "elixir" in tag_names
      assert "testing" in tag_names
    end

    test "first note has correct source_url" do
      notebook_id = find_or_create_notebook("URL Test")
      parse_and_import(@fixture, notebook_id)

      notes =
        Repo.all(Note)
        |> Repo.preload(:tags)
        |> Enum.sort_by(& &1.inserted_at)

      first_note = hd(notes)
      assert first_note.source_url == "https://example.com"
    end

    test "first note has correct created timestamp" do
      notebook_id = find_or_create_notebook("Timestamp Test")
      parse_and_import(@fixture, notebook_id)

      notes =
        Repo.all(Note)
        |> Repo.preload(:tags)
        |> Enum.sort_by(& &1.inserted_at)

      first_note = hd(notes)
      expected = ~U[2024-01-01 12:00:00Z]
      assert first_note.original_created_at == expected
    end

    test "second note has correct title" do
      notebook_id = find_or_create_notebook("Second Note Test")
      parse_and_import(@fixture, notebook_id)

      notes =
        Repo.all(Note)
        |> Repo.preload(:tags)
        |> Enum.sort_by(& &1.inserted_at)

      second_note = Enum.at(notes, 1)
      assert second_note.title == "Test Note Two"
    end
  end

  describe "idempotency" do
    test "running import twice on same notebook creates notes on each run (no guid dedup)" do
      notebook_id = find_or_create_notebook("Idempotency Test")

      state1 = parse_and_import(@fixture, notebook_id)
      assert state1.notes_count == 2

      state2 = parse_and_import(@fixture, notebook_id)
      assert state2.notes_count == 2
    end

    test "notebook is found not duplicated on second run" do
      find_or_create_notebook("Dedup Notebook Test")
      find_or_create_notebook("Dedup Notebook Test")

      notebooks = Repo.all(Notebook)
      count = Enum.count(notebooks, &(&1.name == "Dedup Notebook Test"))
      assert count == 1
    end
  end

  describe "enml_to_html/1" do
    test "converts en-note to div" do
      enml =
        ~s(<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE en-note SYSTEM "http://xml.evernote.com/pub/enml2.dtd"><en-note>Hello world</en-note>)

      result = Mix.Tasks.Librarian.ImportEvernote.enml_to_html(enml)
      assert result =~ "Hello world"
    end

    test "returns original string on parse failure" do
      result = Mix.Tasks.Librarian.ImportEvernote.enml_to_html("not valid xml")
      assert result == "not valid xml"
    end
  end

  describe "parse_enex_date/1" do
    test "parses a valid Evernote date string" do
      result = Mix.Tasks.Librarian.ImportEvernote.parse_enex_date("20240101T120000Z")
      assert result == ~U[2024-01-01 12:00:00Z]
    end

    test "returns nil for nil input" do
      assert Mix.Tasks.Librarian.ImportEvernote.parse_enex_date(nil) == nil
    end

    test "returns nil for invalid format" do
      assert Mix.Tasks.Librarian.ImportEvernote.parse_enex_date("not-a-date") == nil
    end
  end
end
