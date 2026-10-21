defmodule LibrarianWeb.NoteApiController do
  @moduledoc """
  Search, read and two-way sync for editor clients (e.g. an Emacs org-roam
  package). Every query is scoped to the bearer token's user by the Repo
  tenant, so another user's note is indistinguishable from a missing one.
  """
  use LibrarianWeb, :controller

  alias Librarian.Vault

  @default_limit 50
  @max_limit 200

  def index(conn, params) do
    limit =
      with raw when is_binary(raw) <- params["limit"],
           {n, ""} when n > 0 <- Integer.parse(raw) do
        min(n, @max_limit)
      else
        _ -> @default_limit
      end

    query = if is_binary(params["q"]), do: params["q"], else: ""
    notes = Vault.find_notes(query, limit)
    json(conn, %{notes: Enum.map(notes, &summary/1)})
  end

  def show(conn, %{"id" => id}) do
    with {:ok, id} <- parse_id(id), %Vault.Note{} = note <- Vault.get_note(id) do
      related =
        Enum.map(Vault.related_notes(note.id), fn %{edge: edge, note: other} ->
          %{
            id: other.id,
            title: other.title,
            kind: edge.kind,
            direction: if(edge.source_note_id == note.id, do: "outgoing", else: "incoming")
          }
        end)

      json(conn, %{
        note:
          Map.merge(summary(note), %{
            body: note.body,
            body_format: if(note.clip_mode == "markdown", do: "markdown", else: "html"),
            related: related
          })
      })
    else
      _ -> render_error(conn, {:error, :not_found})
    end
  end

  def sync(conn, %{"external_id" => external_id} = params) do
    attrs =
      params
      |> Map.take(~w(body notebook_id source_url))
      |> Map.put("title", params["title"])

    with {:ok, id} <- parse_id(params["id"]),
         {:ok, tags} <- parse_tags(params["tags"]),
         {:ok, note, created?} <- Vault.sync_note(external_id, attrs, tags, id) do
      json(conn, %{status: "ok", id: note.id, created: created?})
    else
      error -> render_error(conn, error)
    end
  end

  defp summary(note) do
    %{
      id: note.id,
      title: note.title,
      external_id: note.external_id,
      notebook: note.notebook && %{id: note.notebook.id, name: note.notebook.name},
      tags: Enum.map(note.tags, & &1.name),
      clip_mode: note.clip_mode,
      source_url: note.source_url,
      updated_at: note.updated_at
    }
  end

  defp parse_id(nil), do: {:ok, nil}
  defp parse_id(id) when is_integer(id), do: {:ok, id}

  defp parse_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {int, ""} -> {:ok, int}
      _ -> {:error, :not_found}
    end
  end

  defp parse_id(_id), do: {:error, :not_found}

  defp parse_tags(nil), do: {:ok, nil}

  defp parse_tags(tags) when is_list(tags) do
    if Enum.all?(tags, &is_binary/1), do: {:ok, tags}, else: {:error, :invalid_tags}
  end

  defp parse_tags(_tags), do: {:error, :invalid_tags}

  defp render_error(conn, {:error, :not_found}),
    do: conn |> put_status(404) |> json(%{error: "not_found"})

  defp render_error(conn, {:error, :external_id_conflict}),
    do: conn |> put_status(409) |> json(%{error: "external_id_conflict"})

  defp render_error(conn, {:error, :invalid_tags}),
    do: conn |> put_status(422) |> json(%{status: "error", errors: %{tags: ["is invalid"]}})

  defp render_error(conn, {:error, %Ecto.Changeset{} = changeset}) do
    errors =
      Ecto.Changeset.traverse_errors(changeset, &LibrarianWeb.CoreComponents.translate_error/1)

    conn |> put_status(422) |> json(%{status: "error", errors: errors})
  end
end
