defmodule LibrarianWeb.ClipController do
  use LibrarianWeb, :controller

  def create(conn, params) do
    clip_mode = Map.get(params, "clip_mode", "selection")
    body_raw = Map.get(params, "body", "")
    title = Map.get(params, "title")
    source_url = Map.get(params, "source_url")
    tags = Map.get(params, "tags", [])

    notebook_id =
      case Map.get(params, "notebook_id") do
        nil -> nil
        "" -> nil
        id when is_integer(id) -> id
        id -> String.to_integer(to_string(id))
      end

    {storage_key, body_text} =
      if clip_mode in ["pdf", "screenshot", "full_page"] do
        case Base.decode64(body_raw, ignore: :whitespace) do
          {:ok, data} ->
            ext =
              case clip_mode do
                "pdf" -> ".pdf"
                "screenshot" -> ".png"
                _ -> ".html"
              end

            key = "clips/#{System.unique_integer([:positive, :monotonic])}#{ext}"
            Librarian.Storage.put(key, data)
            {key, nil}

          :error ->
            {nil, body_raw}
        end
      else
        {nil, body_raw}
      end

    attrs = %{
      title: title,
      source_url: source_url,
      clip_mode: clip_mode,
      body: body_text,
      storage_key: storage_key,
      notebook_id: notebook_id
    }

    case Librarian.Vault.create_note(attrs, tags) do
      {:ok, note} ->
        json(conn, %{status: "ok", id: note.id})

      {:error, changeset} ->
        conn
        |> put_status(422)
        |> json(%{status: "error", errors: format_errors(changeset)})
    end
  end

  defp format_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r/%{(\w+)}/, msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
