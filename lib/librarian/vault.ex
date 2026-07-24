defmodule Librarian.Vault do
  import Ecto.Query
  alias Librarian.Accounts
  alias Librarian.Repo
  alias Librarian.Vault.{Annotation, Edge, GraphLayout, Note, Notebook, Tag}
  alias Librarian.Workers.RebuildInterestWorker

  def list_notebooks do
    Repo.all(from n in Notebook, order_by: n.name)
  end

  def get_notebook!(id), do: Repo.get!(Notebook, id)

  def create_notebook(attrs) do
    %Notebook{user_id: Accounts.owner!().id}
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

    result =
      %Note{user_id: Accounts.owner!().id}
      |> Note.changeset(attrs)
      |> Ecto.Changeset.put_assoc(:tags, tag_records)
      |> Repo.insert()

    if match?({:ok, _}, result), do: RebuildInterestWorker.enqueue()
    result
  end

  def create_note_from_import(attrs, tags) do
    tag_records = find_or_create_tags(tags)

    changeset =
      %Note{user_id: Accounts.owner!().id}
      |> Note.changeset(attrs)
      |> Ecto.Changeset.put_assoc(:tags, tag_records)

    cond do
      attrs[:evernote_guid] ->
        Repo.insert(changeset, on_conflict: :nothing, conflict_target: :evernote_guid)

      existing = find_import_duplicate(attrs) ->
        {:ok, existing}

      true ->
        Repo.insert(changeset)
    end
  end

  # ENEX exports carry no note GUIDs, so guid-less imports dedupe on content:
  # same notebook, title, and body means the note is already here.
  defp find_import_duplicate(attrs) do
    Repo.one(
      from n in Note,
        where:
          fragment(
            "coalesce(?, '') = coalesce(?, '')",
            n.title,
            type(^attrs[:title], :string)
          ) and
            fragment(
              "md5(coalesce(?, '')) = md5(coalesce(?, ''))",
              n.body,
              type(^attrs[:body], :string)
            ) and
            fragment(
              "coalesce(?, -1) = coalesce(?, -1)",
              n.notebook_id,
              type(^attrs[:notebook_id], :integer)
            ),
        limit: 1
    )
  end

  @doc "Number of surplus copies among identical (notebook, title, body) notes."
  def duplicate_note_count do
    %{rows: [[n]]} =
      Repo.query!("""
      SELECT COALESCE(SUM(c - 1), 0)::bigint FROM (
        SELECT COUNT(*) AS c
        FROM notes
        GROUP BY notebook_id, title, md5(coalesce(body, ''))
        HAVING COUNT(*) > 1
      ) dupes
      """)

    n
  end

  @doc """
  Deletes surplus copies of identical (notebook, title, body) notes, keeping
  the oldest. Annotations move to the survivor; edges cascade away, and
  survivors are marked graph-stale so the next build re-links them.
  """
  def dedupe_notes do
    {:ok, removed} =
      Repo.transaction(fn ->
        %{rows: rows} =
          Repo.query!("""
          SELECT id,
                 MIN(id) OVER (PARTITION BY notebook_id, title, md5(coalesce(body, ''))) AS survivor
          FROM notes
          """)

        dupes = for [id, survivor] <- rows, id != survivor, do: {id, survivor}

        Enum.each(dupes, fn {id, survivor} ->
          Repo.update_all(from(a in Annotation, where: a.note_id == ^id),
            set: [note_id: survivor]
          )
        end)

        dupe_ids = Enum.map(dupes, &elem(&1, 0))
        survivor_ids = dupes |> Enum.map(&elem(&1, 1)) |> Enum.uniq()

        Repo.delete_all(from n in Note, where: n.id in ^dupe_ids)

        Repo.update_all(from(n in Note, where: n.id in ^survivor_ids),
          set: [graph_indexed_at: nil]
        )

        length(dupe_ids)
      end)

    removed
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

  def delete_notes(ids) when is_list(ids) do
    int_ids =
      ids
      |> Enum.map(fn
        id when is_integer(id) ->
          id

        id when is_binary(id) ->
          case Integer.parse(id) do
            {n, ""} -> n
            _ -> nil
          end
      end)
      |> Enum.reject(&is_nil/1)

    {count, _} = Repo.delete_all(from n in Note, where: n.id in ^int_ids)
    {:ok, count}
  end

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

  def update_notebook(%Notebook{} = notebook, attrs) do
    notebook
    |> Notebook.changeset(attrs)
    |> Repo.update()
  end

  def delete_notebook(%Notebook{} = notebook) do
    Repo.delete(notebook)
  end

  def list_tags, do: Repo.all(from t in Tag, order_by: t.name)

  @doc """
  Edges touching a note in either direction, deduped per {kind, other note}
  (mutual similarity edges exist in both directions), strongest first.
  Returns [%{edge: edge, note: other_note}].
  """
  def related_notes(note_id) do
    from(e in Edge,
      where: e.source_note_id == ^note_id or e.target_note_id == ^note_id,
      order_by: [desc: e.weight],
      preload: [:source_note, :target_note]
    )
    |> Repo.all()
    |> Enum.map(fn e ->
      other = if e.source_note_id == note_id, do: e.target_note, else: e.source_note
      %{edge: e, note: other}
    end)
    |> Enum.uniq_by(fn %{edge: e, note: n} -> {e.kind, n.id} end)
  end

  def upsert_edges(entries) when is_list(entries) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    owner_id = Accounts.owner!().id

    rows =
      entries
      |> Enum.filter(fn e ->
        e.kind in Edge.kinds() and e.source_note_id != e.target_note_id
      end)
      |> Enum.map(&Map.merge(&1, %{user_id: owner_id, inserted_at: now, updated_at: now}))

    Repo.insert_all(Edge, rows,
      on_conflict: {:replace, [:reason, :weight, :origin, :updated_at]},
      conflict_target: [:source_note_id, :target_note_id, :kind]
    )
  end

  def delete_edge(id) do
    Repo.delete_all(from e in Edge, where: e.id == ^id)
    :ok
  end

  @doc """
  Builds `related` edges from pgvector neighbors for every embedded note
  (or one note via `:note_id`). Weight is cosine similarity; pairs below
  `:threshold` are skipped.
  """
  def generate_similarity_edges(opts \\ []) do
    k = Keyword.get(opts, :k, 8)
    threshold = Keyword.get(opts, :threshold, 0.5)
    note_filter = Keyword.get(opts, :note_id)

    {filter_sql, params} =
      if note_filter,
        do: {"AND n.id = $3", [k, threshold, note_filter]},
        else: {"", [k, threshold]}

    {:ok, %{num_rows: count}} =
      Repo.query(
        """
        INSERT INTO note_edges
          (source_note_id, target_note_id, kind, weight, origin, user_id, inserted_at, updated_at)
        SELECT n.id, m.id, 'related', m.sim, 'similarity', n.user_id, now(), now()
        FROM notes n
        JOIN LATERAL (
          SELECT m2.id, 1 - (m2.embedding <=> n.embedding) AS sim
          FROM notes m2
          WHERE m2.id != n.id AND m2.embedding IS NOT NULL
          ORDER BY m2.embedding <=> n.embedding
          LIMIT $1
        ) m ON m.sim >= $2
        WHERE n.embedding IS NOT NULL #{filter_sql}
        ON CONFLICT (source_note_id, target_note_id, kind)
        DO UPDATE SET weight = EXCLUDED.weight, updated_at = now()
        """,
        params
      )

    {:ok, count}
  end

  @doc "Top-k embedded neighbors of a note — candidate set for LLM edge typing."
  def neighbor_candidates(%Note{id: id, embedding: embedding}, k \\ 10) when embedding != nil do
    Repo.all(
      from n in Note,
        where: n.id != ^id and not is_nil(n.embedding),
        order_by: fragment("embedding <=> ?", ^embedding),
        limit: ^k
    )
  end

  def list_annotations(note_id) do
    Repo.all(from a in Annotation, where: a.note_id == ^note_id, order_by: [desc: a.inserted_at])
  end

  def create_annotation(note_id, body) do
    %Annotation{user_id: Accounts.owner!().id}
    |> Annotation.changeset(%{note_id: note_id, body: body})
    |> Repo.insert()
  end

  def delete_annotation(id) do
    Repo.delete_all(from a in Annotation, where: a.id == ^id)
    :ok
  end

  @graph_node_cap 400

  @doc """
  Nodes (notes with at least one edge) and edges for the graph view, capped
  to the #{@graph_node_cap} highest-degree notes so layout stays fast.
  """
  def graph do
    edges =
      Repo.all(
        from e in Edge,
          select: %{
            source: e.source_note_id,
            target: e.target_note_id,
            kind: e.kind,
            weight: e.weight
          }
      )

    degrees =
      edges
      |> Enum.flat_map(&[&1.source, &1.target])
      |> Enum.frequencies()

    kept =
      degrees
      |> Enum.sort_by(fn {_id, degree} -> -degree end)
      |> Enum.take(@graph_node_cap)
      |> Map.new()

    edges =
      Enum.filter(edges, &(Map.has_key?(kept, &1.source) and Map.has_key?(kept, &1.target)))

    nodes =
      Repo.all(
        from n in Note,
          where: n.id in ^Map.keys(kept),
          select: %{id: n.id, title: n.title, notebook_id: n.notebook_id}
      )
      |> Enum.map(&Map.put(&1, :degree, Map.fetch!(kept, &1.id)))

    %{nodes: nodes, edges: edges}
  end

  @doc "graph/0 plus force-layout coordinates, ready for SVG rendering."
  def graph_layout(width \\ 1200.0, height \\ 800.0) do
    %{nodes: nodes, edges: edges} = graph()

    pos =
      GraphLayout.layout(
        Enum.map(nodes, & &1.id),
        Enum.map(edges, &{&1.source, &1.target}),
        width,
        height
      )

    nodes =
      Enum.map(nodes, fn n ->
        {x, y} = pos[n.id]
        Map.merge(n, %{x: Float.round(x, 1), y: Float.round(y, 1)})
      end)

    edges =
      Enum.map(edges, fn e ->
        {x1, y1} = pos[e.source]
        {x2, y2} = pos[e.target]

        Map.merge(e, %{
          x1: Float.round(x1, 1),
          y1: Float.round(y1, 1),
          x2: Float.round(x2, 1),
          y2: Float.round(y2, 1)
        })
      end)

    %{nodes: nodes, edges: edges}
  end

  @doc "Clears the graph marker so the next BuildGraphWorker pass re-types this note."
  def mark_graph_stale(note_id) do
    Repo.update_all(from(n in Note, where: n.id == ^note_id), set: [graph_indexed_at: nil])
    :ok
  end

  defp find_or_create_tags([]), do: []

  defp find_or_create_tags(names) when is_list(names) do
    owner_id = Accounts.owner!().id

    Enum.map(names, fn name ->
      name = String.downcase(String.trim(name))

      Repo.insert!(%Tag{name: name, user_id: owner_id},
        on_conflict: :nothing,
        conflict_target: :name
      )

      Repo.get_by!(Tag, name: name)
    end)
  end
end
