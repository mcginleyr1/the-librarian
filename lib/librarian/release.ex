defmodule Librarian.Release do
  @moduledoc """
  Tasks for a running release via `bin/librarian eval`: migrations and
  rollback, note dedupe, demo seeding, stream preparation, and OPML/Evernote
  imports into the owner's account.
  """

  @app :librarian

  import Ecto.Query

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
  Removes duplicate vault notes (same notebook, title, body), keeping the
  oldest copy and moving annotations to it. Safe to run repeatedly.

      bin/librarian eval "Librarian.Release.dedupe_notes()"
  """
  def dedupe_notes do
    load_app()

    {:ok, removed, _} =
      Ecto.Migrator.with_repo(Librarian.Repo, fn _repo ->
        Librarian.Repo.put_user_id(Librarian.Accounts.owner!().id)
        before = Librarian.Vault.duplicate_note_count()
        removed = Librarian.Vault.dedupe_notes()

        IO.puts(
          "Dedupe: #{before} surplus copies found, #{removed} removed. " <>
            "Survivors re-link on the next hourly graph pass (or press Build Graph Now)."
        )

        removed
      end)

    removed
  end

  @doc "Seeds reviewable demo data when DEMO_SEED=true. Safe to run repeatedly."
  def seed_demo do
    if System.get_env("DEMO_SEED") == "true" do
      load_app()

      {:ok, result, _} =
        Ecto.Migrator.with_repo(Librarian.Repo, fn _ -> Librarian.DemoSeed.run() end)

      IO.puts("DemoSeed: #{inspect(result)}")
      result
    else
      :skipped
    end
  end

  @doc """
  One-time stream prep for an existing corpus: embeds all vault notes and the most
  recent `article_limit` articles, tags untagged articles, and rebuilds the interest
  model. Builds its own embedding serving (so it works while the app's serving is off)
  and warms the BUMBLEBEE_CACHE_DIR cache on the PVC.

      bin/librarian eval "Librarian.Release.prepare_for_stream(3000)"
  """
  def prepare_for_stream(article_limit \\ 3000) do
    load_app()
    {:ok, _} = Application.ensure_all_started(:exla)
    {:ok, _} = Application.ensure_all_started(:bumblebee)

    repo_name = Application.fetch_env!(:librarian, :embedding_model)
    {:ok, model} = Bumblebee.load_model({:hf, repo_name})
    {:ok, tokenizer} = Bumblebee.load_tokenizer({:hf, repo_name})

    serving =
      Bumblebee.Text.text_embedding(model, tokenizer,
        compile: [batch_size: 8, sequence_length: 512],
        defn_options: [compiler: EXLA],
        output_attribute: :hidden_state,
        output_pool: :mean_pooling,
        embedding_processor: :l2_norm
      )

    {:ok, result, _} =
      Ecto.Migrator.with_repo(Librarian.Repo, fn _repo ->
        Librarian.Repo.put_user_id(Librarian.Accounts.owner!().id)

        notes =
          embed_rows(serving, from(n in Librarian.Vault.Note, where: is_nil(n.embedding)), fn n ->
            "#{n.title}\n\n#{n.body}"
          end)

        articles =
          embed_rows(
            serving,
            from(a in Librarian.Reader.Article,
              where: is_nil(a.embedding),
              order_by: [desc: a.published_at],
              limit: ^article_limit
            ),
            fn a -> "#{a.title}\n\n#{a.summary}\n\n#{a.content}" end
          )

        tagged = Librarian.Tagging.tag_untagged()
        {:ok, clusters} = Librarian.Interest.rebuild()
        %{notes: notes, articles: articles, tagged: tagged, clusters: clusters}
      end)

    IO.puts("prepare_for_stream: #{inspect(result)}")
    result
  end

  defp embed_rows(serving, query, to_text) do
    Librarian.Repo.all(query)
    |> Enum.reduce(0, fn row, acc ->
      text = row |> to_text.() |> String.trim() |> String.slice(0, 8_000)

      if text == "" do
        acc
      else
        %{embedding: tensor} = Nx.Serving.run(serving, text)
        vector = tensor |> Nx.to_flat_list() |> Pgvector.new()
        row |> Ecto.Changeset.change(embedding: vector) |> Librarian.Repo.update!()
        acc + 1
      end
    end)
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
        Librarian.Repo.with_user(Librarian.Accounts.owner!().id, fn ->
          run_opml_import(File.read!(file_path))
        end)
      end)

    result
  end

  @doc """
  Imports OPML feeds into the **current tenant**. The caller must have set the
  tenant (via the auth plug/LiveView mount, or `Repo.with_user/2`). Console
  entrypoints go through `import_opml/1`, which sets the owner.
  """
  def run_opml_import(contents) do
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
        Librarian.Repo.with_user(Librarian.Accounts.owner!().id, fn ->
          run_evernote_import(file_path, notebook_name)
        end)
      end)

    result
  end

  @doc """
  Imports an Evernote `.enex` file into the **current tenant**. The caller must
  have set the tenant (via the auth plug/LiveView mount, or `Repo.with_user/2`).
  Console entrypoints go through `import_evernote/2`, which sets the owner.
  """
  def run_evernote_import(file_path, notebook_name \\ nil) do
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
