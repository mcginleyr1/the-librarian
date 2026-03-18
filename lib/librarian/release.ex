defmodule Librarian.Release do
  @app :librarian

  def migrate do
    load_app()

    for repo <- repos() do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end
  end

  def rollback(repo, version) do
    load_app()
    {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))
  end

  @doc """
  Import feeds from an OPML file. Safe to run multiple times (idempotent).

  Usage in a release:
      bin/librarian eval "Librarian.Release.import_opml('/tmp/feedly.opml')"
  """
  def import_opml(file_path) do
    load_app()

    {:ok, result, _} =
      Ecto.Migrator.with_repo(Librarian.Repo, fn _repo ->
        contents = File.read!(file_path)

        case Saxy.SimpleForm.parse_string(contents) do
          {:ok, {"opml", _attrs, children}} ->
            body =
              Enum.find(children, fn
                {"body", _, _} -> true
                _ -> false
              end)

            {"body", _attrs, outlines} = body
            feeds = extract_opml_feeds(outlines)
            {imported, skipped} = import_opml_feeds(feeds)
            categories = feeds |> Enum.map(& &1.category) |> Enum.uniq() |> length()

            IO.puts(
              "Imported #{imported} feeds across #{categories} categories (#{skipped} skipped as duplicates)"
            )

            %{imported: imported, skipped: skipped, categories: categories}

          _ ->
            IO.puts("Error: not a valid OPML file")
            %{imported: 0, skipped: 0, categories: 0}
        end
      end)

    result
  end

  @doc """
  Import notes from an Evernote .enex export file. Safe to run multiple times (idempotent).

  Usage in a release:
      bin/librarian eval "Librarian.Release.import_evernote('/tmp/export.enex', 'My Notebook')"
  """
  def import_evernote(file_path, notebook_name \\ nil) do
    load_app()

    {:ok, result, _} =
      Ecto.Migrator.with_repo(Librarian.Repo, fn _repo ->
        name = notebook_name || Path.basename(file_path, ".enex")
        notebook_id = Mix.Tasks.Librarian.ImportEvernote.find_or_create_notebook(name)

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

        stream = Mix.Tasks.Librarian.ImportEvernote.cdata_fixing_stream(file_path)

        case Saxy.parse_stream(stream, Mix.Tasks.Librarian.ImportEvernote.Handler, initial_state) do
          {:ok, state} ->
            IO.puts(
              "Imported #{state.notes_count} notes, #{state.attachments_count} attachments (#{state.errors} errors)"
            )

            %{
              notes_count: state.notes_count,
              attachments_count: state.attachments_count,
              errors: state.errors
            }

          {:error, reason} ->
            IO.puts("Error: #{inspect(reason)}")
            %{notes_count: 0, attachments_count: 0, errors: 1}
        end
      end)

    result
  end

  defp extract_opml_feeds(outlines) do
    Enum.flat_map(outlines, fn
      {"outline", attrs, children} ->
        case get_opml_attr(attrs, "xmlUrl") do
          nil ->
            category = get_opml_attr(attrs, "text") || "Uncategorized"
            extract_opml_feeds_with_category(children, category)

          _ ->
            []
        end

      _ ->
        []
    end)
  end

  defp extract_opml_feeds_with_category(outlines, category) do
    Enum.flat_map(outlines, fn
      {"outline", attrs, _} ->
        url = get_opml_attr(attrs, "xmlUrl")

        cond do
          is_nil(url) ->
            []

          String.contains?(url, "feedly.com/f/alert") ->
            []

          true ->
            [
              %{
                title: get_opml_attr(attrs, "title") || get_opml_attr(attrs, "text") || url,
                feed_url: url,
                site_url: get_opml_attr(attrs, "htmlUrl"),
                category: category
              }
            ]
        end

      _ ->
        []
    end)
  end

  defp import_opml_feeds(feeds) do
    Enum.reduce(feeds, {0, 0}, fn attrs, {imported, skipped} ->
      case Librarian.Reader.upsert_feed(attrs) do
        {:ok, %{id: nil}} -> {imported, skipped + 1}
        {:ok, _} -> {imported + 1, skipped}
        {:error, _} -> {imported, skipped + 1}
      end
    end)
  end

  defp get_opml_attr(attrs, name) do
    Enum.find_value(attrs, fn {k, v} -> if k == name, do: v end)
  end

  defp repos, do: Application.fetch_env!(@app, :ecto_repos)

  defp load_app do
    Application.load(@app)
    Application.ensure_all_started(:ssl)
  end
end
