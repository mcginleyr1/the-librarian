defmodule Librarian.Backup do
  require Logger
  import Ecto.Query
  alias Librarian.{Repo, Storage}
  alias Librarian.Vault.Note

  def run(settings) do
    Repo.transaction(
      fn ->
        from(n in Note, preload: [:notebook, :tags])
        |> Repo.stream()
        |> Stream.each(&backup_note(&1, settings))
        |> Stream.run()
      end,
      timeout: :infinity
    )

    :ok
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

  def render_markdown(note, notebook_name) do
    tags = Enum.map(note.tags || [], & &1.name)
    created_at = note.original_created_at || note.inserted_at

    lines =
      [
        "---",
        "title: #{note.title || ""}",
        if(notebook_name, do: "notebook: #{notebook_name}"),
        if(tags != [], do: "tags: [#{Enum.join(tags, ", ")}]"),
        if(note.source_url, do: "source_url: #{note.source_url}"),
        if(note.clip_mode, do: "clip_mode: #{note.clip_mode}"),
        "created_at: #{DateTime.to_iso8601(created_at)}",
        "---",
        "",
        note.body || ""
      ]
      |> Enum.reject(&is_nil/1)

    Enum.join(lines, "\n")
  end

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

      unless b2_exists?(index_key, settings) do
        markdown = render_markdown(note, notebook_name)
        b2_put(index_key, markdown, "text/markdown; charset=utf-8", settings)
      end

      if note.storage_key && Storage.exists?(note.storage_key) do
        att_key = attachment_key(note, notebook_name)

        unless b2_exists?(att_key, settings) do
          case Storage.get(note.storage_key) do
            {:ok, data} ->
              b2_put(att_key, data, "application/octet-stream", settings)

            {:error, reason} ->
              Logger.warning("Backup: could not read attachment for note #{note.id}: #{inspect(reason)}")
          end
        end
      end
    rescue
      e ->
        Logger.warning("Backup: failed to back up note #{note.id}: #{inspect(e)}")
    end
  end

  defp b2_exists?(key, settings) do
    case ExAws.S3.head_object(settings.b2_bucket_name, key)
         |> ExAws.request(ex_aws_config(settings)) do
      {:ok, _} ->
        true

      {:error, {:http_error, 404, _}} ->
        false

      {:error, reason} ->
        Logger.warning("Backup: HEAD check failed for #{key}: #{inspect(reason)}")
        false
    end
  end

  defp b2_put(key, data, content_type, settings) do
    case ExAws.S3.put_object(settings.b2_bucket_name, key, data, content_type: content_type)
         |> ExAws.request(ex_aws_config(settings)) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.warning("Backup: upload failed for #{key}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp ex_aws_config(settings) do
    [
      access_key_id: settings.b2_key_id,
      secret_access_key: settings.b2_application_key,
      host: settings.b2_endpoint,
      scheme: "https://",
      region: region_from_endpoint(settings.b2_endpoint)
    ]
  end

  defp region_from_endpoint(endpoint) do
    case String.split(endpoint || "", ".") do
      ["s3", region | _] -> region
      _ -> "auto"
    end
  end
end
