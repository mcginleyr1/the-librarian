defmodule Librarian.Vault do
  import Ecto.Query
  alias Librarian.Repo
  alias Librarian.Vault.{Note, Notebook, Tag}

  def list_notebooks do
    Repo.all(from n in Notebook, order_by: n.name)
  end

  def get_notebook!(id), do: Repo.get!(Notebook, id)

  def create_notebook(attrs) do
    %Notebook{}
    |> Notebook.changeset(attrs)
    |> Repo.insert()
  end

  def list_notes(opts \\ []) do
    notebook_id = Keyword.get(opts, :notebook_id)
    limit = Keyword.get(opts, :limit, 50)
    offset = Keyword.get(opts, :offset, 0)

    query =
      from n in Note,
        order_by: [desc: n.inserted_at],
        limit: ^limit,
        offset: ^offset,
        preload: [:notebook, :tags]

    query =
      if notebook_id do
        from n in query, where: n.notebook_id == ^notebook_id
      else
        query
      end

    Repo.all(query)
  end

  def get_note!(id), do: Repo.get!(Note, id) |> Repo.preload([:notebook, :tags])

  def create_note(attrs, tags \\ []) do
    tag_records = find_or_create_tags(tags)

    %Note{}
    |> Note.changeset(attrs)
    |> Ecto.Changeset.put_assoc(:tags, tag_records)
    |> Repo.insert()
  end

  def create_note_from_import(attrs, tags) do
    tag_records = find_or_create_tags(tags)

    changeset =
      %Note{}
      |> Note.changeset(attrs)
      |> Ecto.Changeset.put_assoc(:tags, tag_records)

    if attrs[:evernote_guid] do
      Repo.insert(changeset, on_conflict: :nothing, conflict_target: :evernote_guid)
    else
      Repo.insert(changeset)
    end
  end

  def update_note(%Note{} = note, attrs, tags \\ nil) do
    changeset = Note.changeset(note, attrs)

    changeset =
      if tags do
        tag_records = find_or_create_tags(tags)
        Ecto.Changeset.put_assoc(changeset, :tags, tag_records)
      else
        changeset
      end

    Repo.update(changeset)
  end

  def delete_note(%Note{} = note), do: Repo.delete(note)

  def search(query_str, opts \\ []) when is_binary(query_str) do
    limit = Keyword.get(opts, :limit, 50)
    notebook_id = Keyword.get(opts, :notebook_id)

    query =
      from n in Note,
        where: fragment("search_vector @@ plainto_tsquery('english', ?)", ^query_str),
        order_by: [
          desc: fragment("ts_rank(search_vector, plainto_tsquery('english', ?))", ^query_str)
        ],
        limit: ^limit,
        preload: [:notebook, :tags]

    query =
      if notebook_id do
        from n in query, where: n.notebook_id == ^notebook_id
      else
        query
      end

    Repo.all(query)
  end

  def count_notes_by_notebook do
    Repo.all(
      from n in Note,
        group_by: n.notebook_id,
        select: {n.notebook_id, count(n.id)}
    )
    |> Map.new()
  end

  def list_all_notes(opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)

    Repo.all(
      from n in Note,
        order_by: [desc: n.inserted_at],
        limit: ^limit,
        preload: [:notebook, :tags]
    )
  end

  def list_notes_for_notebook(notebook_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)

    Repo.all(
      from n in Note,
        where: n.notebook_id == ^notebook_id,
        order_by: [desc: n.inserted_at],
        limit: ^limit,
        preload: [:notebook, :tags]
    )
  end

  def update_notebook(%Notebook{} = notebook, attrs) do
    notebook
    |> Notebook.changeset(attrs)
    |> Repo.update()
  end

  def delete_notebook(%Notebook{} = notebook) do
    Repo.delete(notebook)
  end

  def list_tags, do: Repo.all(from t in Tag, order_by: t.name)

  defp find_or_create_tags(names) when is_list(names) do
    Enum.map(names, fn name ->
      name = String.downcase(String.trim(name))
      Repo.insert!(%Tag{name: name}, on_conflict: :nothing, conflict_target: :name)
      Repo.get_by!(Tag, name: name)
    end)
  end
end
