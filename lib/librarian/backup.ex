defmodule Librarian.Backup do
  @moduledoc """
  Incremental vault backup to the user's Backblaze B2 bucket (S3 API): notes
  as Markdown with YAML front matter plus their attachments, and canvas pages
  as Obsidian `.canvas` files.
  """

  require Logger
  import Ecto.Query

  alias Librarian.{Canvas, Repo, Storage}
  alias Librarian.Canvas.Page
  alias Librarian.Vault.Note

  @doc """
  Uploads every note and canvas page changed since the last clean run. The
  cursor (`last_backup_at`) only advances when every upload succeeded, so a
  failed run is retried in full instead of silently skipping what it missed.
  """
  def run(settings) do
    # The endpoint is user-supplied; never sign requests to an internal host.
    with {:ok, _uri} <- Librarian.SafeHTTP.check_url("https://#{settings.b2_endpoint}/") do
      started_at = DateTime.utc_now()
      results = backup_notes(settings) ++ backup_pages(settings)

      case Enum.count(results, &(&1 != :ok)) do
        0 ->
          settings
          |> Ecto.Changeset.change(last_backup_at: DateTime.truncate(started_at, :second))
          |> Repo.update!()

          :ok

        failures ->
          {:error, "#{failures} backup uploads failed"}
      end
    end
  end

  defp backup_notes(settings) do
    query =
      case settings.last_backup_at do
        nil -> from n in Note, select: n.id, order_by: n.id
        since -> from n in Note, where: n.updated_at > ^since, select: n.id, order_by: n.id
      end

    query
    |> Repo.all()
    |> Enum.map(fn id ->
      case Repo.get(Note, id) do
        # Deleted since the id list was read: nothing left to back up.
        nil -> :ok
        note -> note |> Repo.preload([:notebook, :tags]) |> backup_note(settings)
      end
    end)
  end

  defp backup_pages(settings) do
    pages =
      case settings.last_backup_at do
        nil -> from p in Page, order_by: p.id
        since -> from p in Page, where: p.updated_at > ^since, order_by: p.id
      end

    Enum.map(Repo.all(pages), &backup_page(&1, settings))
  end

  def note_key(note, notebook_name) do
    slug = "#{note.id}-#{slugify(note.title)}"
    "vault/#{slugify(notebook_name)}/#{slug}/index.md"
  end

  def attachment_key(note, notebook_name) do
    slug = "#{note.id}-#{slugify(note.title)}"
    ext = Path.extname(note.storage_key || "")
    "vault/#{slugify(notebook_name)}/#{slug}/attachment#{ext}"
  end

  def page_key(page), do: "vault/canvas/#{page.id}-#{slugify(page.title)}.canvas"

  @doc """
  The page as an Obsidian-openable `.canvas` file: note cards point at the
  note's markdown in this same backup instead of the app's `note:<id>` refs.
  """
  def render_canvas(page) do
    ids = Canvas.note_ids(page.doc)

    paths =
      Repo.all(from n in Note, where: n.id in ^ids, preload: [:notebook])
      |> Map.new(fn note ->
        notebook_name = if note.notebook, do: note.notebook.name, else: "Unsorted"
        {note.id, note_key(note, notebook_name)}
      end)

    nodes =
      Enum.map(page.doc["nodes"] || [], fn node ->
        case Canvas.note_id(node) do
          nil -> node
          id -> Map.put(node, "file", Map.get(paths, id, node["file"]))
        end
      end)

    Jason.encode!(%{"nodes" => nodes, "edges" => page.doc["edges"] || []}, pretty: true)
  end

  def render_markdown(note, notebook_name) do
    created_at = note.original_created_at || note.inserted_at

    lines =
      [
        "---",
        "title: #{yaml_value(note.title || "")}",
        if(notebook_name, do: "notebook: #{yaml_value(notebook_name)}"),
        tags_line(note.tags),
        if(note.source_url, do: "source_url: #{yaml_value(note.source_url)}"),
        if(note.clip_mode, do: "clip_mode: #{note.clip_mode}"),
        if(created_at, do: "created_at: #{DateTime.to_iso8601(created_at)}"),
        "---",
        "",
        note.body || ""
      ]
      |> Enum.reject(&is_nil/1)

    Enum.join(lines, "\n")
  end

  defp tags_line(tags) when tags in [nil, []], do: nil
  defp tags_line(tags), do: "tags: [#{Enum.map_join(tags, ", ", &yaml_value(&1.name))}]"

  defp yaml_value(nil), do: nil
  defp yaml_value(str) when is_binary(str), do: ~s("#{String.replace(str, ~s("), ~s(\\"))}")

  def slugify(nil), do: "untitled"

  def slugify(str) do
    str
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9\s-]/, "")
    |> String.replace(~r/[\s-]+/, "-")
    |> String.trim("-")
  end

  defp backup_note(note, settings) do
    notebook_name = if note.notebook, do: note.notebook.name, else: "Unsorted"

    try do
      index_key = note_key(note, notebook_name)
      markdown = render_markdown(note, notebook_name)

      with :ok <- b2_put(index_key, markdown, "text/markdown; charset=utf-8", settings) do
        backup_attachment(note, notebook_name, settings)
      end
    rescue
      e ->
        Logger.warning("Backup: failed to back up note #{note.id}: #{inspect(e)}")
        {:error, e}
    after
      :erlang.garbage_collect()
    end
  end

  defp backup_attachment(%{storage_key: nil}, _notebook_name, _settings), do: :ok

  defp backup_attachment(note, notebook_name, settings) do
    case Storage.get(note.storage_key) do
      {:ok, data} ->
        b2_put(attachment_key(note, notebook_name), data, "application/octet-stream", settings)

      {:error, :enoent} ->
        Logger.warning("Backup: attachment for note #{note.id} is missing from storage")
        :ok

      {:error, reason} ->
        Logger.warning(
          "Backup: could not read attachment for note #{note.id}: #{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  defp backup_page(page, settings) do
    b2_put(page_key(page), render_canvas(page), "application/json", settings)
  rescue
    e ->
      Logger.warning("Backup: failed to back up page #{page.id}: #{inspect(e)}")
      {:error, e}
  end

  defp b2_put(key, data, content_type, settings) do
    url = b2_url(key, settings)
    config = b2_auth_config(settings)
    payload_hash = sha256_hex(data)

    headers = [
      {"content-type", content_type},
      {"x-amz-content-sha256", payload_hash}
    ]

    case ExAws.Auth.headers(:put, url, :s3, config, headers, data) do
      {:ok, signed_headers} ->
        case Req.put(url, headers: signed_headers, body: data) do
          {:ok, %{status: status}} when status in 200..299 ->
            :ok

          {:ok, %{status: status, body: body}} ->
            Logger.warning("Backup: upload failed for #{key} (#{status}): #{inspect(body)}")
            {:error, {:http, status}}

          {:error, reason} ->
            Logger.warning("Backup: upload request failed for #{key}: #{inspect(reason)}")
            {:error, reason}
        end

      {:error, reason} ->
        Logger.warning("Backup: signing failed for #{key}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp sha256_hex(data) do
    :crypto.hash(:sha256, data) |> Base.encode16(case: :lower)
  end

  defp b2_url(key, settings) do
    encoded_key = key |> String.split("/") |> Enum.map_join("/", &URI.encode/1)
    "https://#{settings.b2_endpoint}/#{settings.b2_bucket_name}/#{encoded_key}"
  end

  defp b2_auth_config(settings) do
    %{
      access_key_id: settings.b2_key_id,
      secret_access_key: settings.b2_application_key,
      region: region_from_endpoint(settings.b2_endpoint),
      host: settings.b2_endpoint
    }
  end

  defp region_from_endpoint(endpoint) do
    case String.split(endpoint || "", ".") do
      ["s3", region | _] -> region
      _ -> "auto"
    end
  end
end
