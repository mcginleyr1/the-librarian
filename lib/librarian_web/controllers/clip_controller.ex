defmodule LibrarianWeb.ClipController do
  use LibrarianWeb, :controller

  @binary_modes %{"pdf" => ".pdf", "screenshot" => ".png", "full_page" => ".html"}

  def create(conn, params) do
    clip_mode = Map.get(params, "clip_mode", "selection")
    body_raw = Map.get(params, "body", "")

    with {:ok, notebook_id} <- parse_notebook_id(params["notebook_id"]),
         {:ok, tags} <- parse_tags(Map.get(params, "tags", [])) do
      {storage_key, body_text} = store_binary(clip_mode, body_raw)

      attrs = %{
        title: params["title"],
        source_url: params["source_url"],
        clip_mode: clip_mode,
        body: body_text,
        storage_key: storage_key,
        notebook_id: notebook_id
      }

      case Librarian.Vault.create_note(attrs, tags) do
        {:ok, note} ->
          json(conn, %{status: "ok", id: note.id})

        {:error, changeset} ->
          storage_key && Librarian.Storage.delete(storage_key)

          conn
          |> put_status(422)
          |> json(%{status: "error", errors: format_errors(changeset)})
      end
    else
      {:error, field} ->
        conn
        |> put_status(422)
        |> json(%{status: "error", errors: %{field => ["is invalid"]}})
    end
  end

  defp store_binary(clip_mode, body_raw) when is_map_key(@binary_modes, clip_mode) do
    with true <- is_binary(body_raw),
         {:ok, data} <- Base.decode64(body_raw, ignore: :whitespace) do
      key = Librarian.Storage.unique_key("clips", @binary_modes[clip_mode])
      :ok = Librarian.Storage.put(key, data)
      {key, nil}
    else
      _ -> {nil, body_raw}
    end
  end

  defp store_binary(_clip_mode, body_raw), do: {nil, body_raw}

  defp parse_notebook_id(id) when id in [nil, ""], do: {:ok, nil}
  defp parse_notebook_id(id) when is_integer(id), do: {:ok, id}

  defp parse_notebook_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {int, ""} -> {:ok, int}
      _ -> {:error, :notebook_id}
    end
  end

  defp parse_notebook_id(_id), do: {:error, :notebook_id}

  defp parse_tags(tags) when is_list(tags) do
    if Enum.all?(tags, &is_binary/1), do: {:ok, tags}, else: {:error, :tags}
  end

  defp parse_tags(_tags), do: {:error, :tags}

  defp format_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r/%{(\w+)}/, msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
