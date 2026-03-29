defmodule Librarian.Backup do
  require Logger
  alias Librarian.{Repo, Storage}
  alias Librarian.Vault.Note

  def run(settings) do
    import Ecto.Query
    ids = Repo.all(from n in Note, select: n.id, order_by: n.id)

    Enum.each(ids, fn id ->
      note = Repo.get!(Note, id) |> Repo.preload([:notebook, :tags])
      backup_note(note, settings)
      :erlang.garbage_collect()
    end)

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
        "title: #{yaml_value(note.title || "")}",
        if(notebook_name, do: "notebook: #{yaml_value(notebook_name)}"),
        if(tags != [], do: "tags: [#{Enum.map(tags, &yaml_value/1) |> Enum.join(", ")}]"),
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
              Logger.warning(
                "Backup: could not read attachment for note #{note.id}: #{inspect(reason)}"
              )
          end
        end
      end
    rescue
      e ->
        Logger.warning("Backup: failed to back up note #{note.id}: #{inspect(e)}")
    after
      :erlang.garbage_collect()
    end
  end

  defp b2_exists?(key, settings) do
    url = b2_url(key, settings)
    config = b2_auth_config(settings)
    empty_hash = sha256_hex("")
    headers = [{"x-amz-content-sha256", empty_hash}]

    case ExAws.Auth.headers(:head, url, :s3, config, headers, "") do
      {:ok, signed_headers} ->
        case Req.head(url, headers: signed_headers) do
          {:ok, %{status: 200}} -> true
          {:ok, %{status: 404}} -> false
          {:ok, %{status: status}} ->
            Logger.warning("Backup: unexpected HEAD status #{status} for #{key}")
            false
          {:error, reason} ->
            Logger.warning("Backup: HEAD request failed for #{key}: #{inspect(reason)}")
            false
        end

      {:error, reason} ->
        Logger.warning("Backup: signing failed for #{key}: #{inspect(reason)}")
        false
    end
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
            :ok

          {:error, reason} ->
            Logger.warning("Backup: upload request failed for #{key}: #{inspect(reason)}")
            :ok
        end

      {:error, reason} ->
        Logger.warning("Backup: signing failed for #{key}: #{inspect(reason)}")
        :ok
    end
  end

  defp sha256_hex(data) do
    :crypto.hash(:sha256, data) |> Base.encode16(case: :lower)
  end

  defp b2_url(key, settings) do
    encoded_key = key |> String.split("/") |> Enum.map(&URI.encode/1) |> Enum.join("/")
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
