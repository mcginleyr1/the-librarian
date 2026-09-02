defmodule Librarian.Vault do
  import Ecto.Query
  alias Librarian.Repo
  alias Librarian.Vault.{Annotation, Edge, Note, Notebook, Tag, Wikilink}
  alias Librarian.Workers.RebuildInterestWorker

  def list_notebooks do
    Repo.all(from n in Notebook, order_by: n.name)
  end

  def get_notebook!(id), do: Repo.get!(Notebook, id)

  def create_notebook(attrs) do
    %Notebook{user_id: Repo.user_id!()}
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
      %Note{user_id: Repo.user_id!()}
      |> Note.changeset(attrs)
      |> Ecto.Changeset.put_assoc(:tags, tag_records)
      |> Repo.insert()

    with {:ok, note} <- result do
      sync_wikilink_edges(note)
      RebuildInterestWorker.enqueue()
    end

    result
  end

  def create_note_from_import(attrs, tags) do
    tag_records = find_or_create_tags(tags)

    changeset =
      %Note{user_id: Repo.user_id!()}
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
    # scoped: WHERE user_id = $1 with Repo.user_id!()
    # credo:disable-for-next-line Librarian.CredoChecks.RawSQL
    %{rows: [[n]]} =
      Repo.query!(
        """
        SELECT COALESCE(SUM(c - 1), 0)::bigint FROM (
          SELECT COUNT(*) AS c
          FROM notes
          WHERE user_id = $1
          GROUP BY notebook_id, title, md5(coalesce(body, ''))
          HAVING COUNT(*) > 1
        ) dupes
        """,
        [Repo.user_id!()]
      )

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
        # scoped: WHERE user_id = $1 with Repo.user_id!()
        # credo:disable-for-next-line Librarian.CredoChecks.RawSQL
        %{rows: rows} =
          Repo.query!(
            """
            SELECT id,
                   MIN(id) OVER (PARTITION BY notebook_id, title, md5(coalesce(body, ''))) AS survivor
            FROM notes
            WHERE user_id = $1
            """,
            [Repo.user_id!()]
          )

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

    result = Repo.update(changeset)

    with {:ok, updated} <- result, do: sync_wikilink_edges(updated)

    result
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

  @doc """
  Title-substring note suggestions (case-insensitive), newest first — powers
  the quick switcher and `[[` autocomplete. An empty query returns the most
  recent titled notes.
  """
  def suggest_notes(query_str, opts \\ []) do
    limit = Keyword.get(opts, :limit, 8)
    q = query_str |> to_string() |> String.trim() |> String.downcase()

    base =
      from n in Note,
        where: not is_nil(n.title),
        order_by: [desc: n.inserted_at],
        limit: ^limit

    query =
      if q == "" do
        base
      else
        from n in base, where: fragment("position(? in lower(?)) > 0", ^q, n.title)
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

  def upsert_edges(entries, opts \\ []) when is_list(entries) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    user_id = Repo.user_id!()

    on_conflict =
      Keyword.get(opts, :on_conflict, {:replace, [:reason, :weight, :origin, :updated_at]})

    rows =
      entries
      |> Enum.filter(fn e ->
        e.kind in Edge.kinds() and e.source_note_id != e.target_note_id
      end)
      |> Enum.map(&Map.merge(&1, %{user_id: user_id, inserted_at: now, updated_at: now}))

    case rows do
      [] ->
        {0, nil}

      rows ->
        Repo.insert_all(Edge, rows,
          on_conflict: on_conflict,
          conflict_target: [:source_note_id, :target_note_id, :kind]
        )
    end
  end

  def delete_edge(id) do
    Repo.delete_all(from e in Edge, where: e.id == ^id)
    :ok
  end

  @doc "Manually connects two notes (an explicit, user-authored edge)."
  def link_notes(source_note_id, target_note_id, kind \\ "references") do
    upsert_edges([
      %{
        source_note_id: source_note_id,
        target_note_id: target_note_id,
        kind: kind,
        reason: nil,
        weight: 1.0,
        origin: "user"
      }
    ])

    :ok
  end

  @doc "The note body as HTML: markdown is rendered, clipped HTML gets its wiki-links resolved."
  def render_note_html(%Note{clip_mode: "markdown", body: body}) when is_binary(body) do
    body
    |> Wikilink.to_markdown_links(wikilink_targets(body))
    |> MDEx.to_html!()
  end

  def render_note_html(%Note{body: body}) when is_binary(body) do
    Wikilink.to_html_links(body, wikilink_targets(body))
  end

  def render_note_html(_), do: "<p class='text-base-content/40 italic'>No content</p>"

  @doc """
  Resolves the `[[Title]]` links in a body to notes: a map of downcased
  title -> note id. Titles match case-insensitively; ties go to the oldest note.
  """
  def wikilink_targets(body) do
    body |> Wikilink.extract_titles() |> resolve_titles()
  end

  defp resolve_titles([]), do: %{}

  defp resolve_titles(titles) do
    lowered = titles |> Enum.map(&String.downcase/1) |> Enum.uniq()

    Repo.all(
      from n in Note,
        where: fragment("lower(?)", n.title) in ^lowered,
        # oldest note wins a title tie: Map.new keeps the last row it sees
        order_by: [desc: n.id],
        select: {fragment("lower(?)", n.title), n.id}
    )
    |> Map.new()
  end

  @doc """
  Mirrors the body's `[[Title]]` links into `references` edges with origin
  `wikilink`. The set is replaced on every save, so removing a link from the
  body removes its edge — similarity/llm/user edges are never touched.
  """
  def sync_wikilink_edges(%Note{} = note) do
    target_ids =
      note.body
      |> wikilink_targets()
      |> Map.values()
      |> Enum.reject(&(&1 == note.id))

    Repo.delete_all(
      from e in Edge,
        where:
          e.source_note_id == ^note.id and e.origin == "wikilink" and
            e.target_note_id not in ^target_ids
    )

    target_ids
    |> Enum.map(
      &%{
        source_note_id: note.id,
        target_note_id: &1,
        kind: "references",
        reason: nil,
        weight: 1.0,
        origin: "wikilink"
      }
    )
    |> upsert_edges()

    :ok
  end

  @doc """
  Notes whose body mentions this note's title without any edge between the
  two — Obsidian's \"unlinked mentions\". Trivially short titles are skipped
  to avoid noise.
  """
  def unlinked_mentions(%Note{} = note, opts \\ []) do
    limit = Keyword.get(opts, :limit, 6)
    title = note.title && String.trim(note.title)

    if is_nil(title) or String.length(title) < 3 do
      []
    else
      connected_ids =
        Repo.all(
          from e in Edge,
            where: e.source_note_id == ^note.id or e.target_note_id == ^note.id,
            select: {e.source_note_id, e.target_note_id}
        )
        |> Enum.flat_map(fn {s, t} -> [s, t] end)

      exclude = [note.id | connected_ids]

      Repo.all(
        from n in Note,
          where: n.id not in ^exclude,
          where:
            fragment("position(? in lower(coalesce(?, ''))) > 0", ^String.downcase(title), n.body),
          order_by: [desc: n.inserted_at],
          limit: ^limit
      )
    end
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
        do: {"AND n.id = $4", [k, threshold, Repo.user_id!(), note_filter]},
        else: {"", [k, threshold, Repo.user_id!()]}

    # scoped: WHERE n.user_id = $3, lateral join on m2.user_id = n.user_id, stamps n.user_id
    # credo:disable-for-next-line Librarian.CredoChecks.RawSQL
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
          WHERE m2.id != n.id AND m2.embedding IS NOT NULL AND m2.user_id = n.user_id
          ORDER BY m2.embedding <=> n.embedding
          LIMIT $1
        ) m ON m.sim >= $2
        WHERE n.embedding IS NOT NULL AND n.user_id = $3 #{filter_sql}
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
    %Annotation{user_id: Repo.user_id!()}
    |> Annotation.changeset(%{note_id: note_id, body: body})
    |> Repo.insert()
  end

  def delete_annotation(id) do
    Repo.delete_all(from a in Annotation, where: a.id == ^id)
    :ok
  end

  @flat_notebook_limit 24

  @doc """
  The full vault as a Notebook -> tag group -> note tree for the mind map,
  plus the typed edges as cross-links. Notebooks over #{@flat_notebook_limit}
  notes bucket their notes by first tag so no branch dumps hundreds of
  leaves at once.
  """
  def mind_map do
    notes = Repo.all(from n in Note, order_by: n.title, preload: [:tags])

    links =
      Repo.all(
        from e in Edge,
          where: e.kind != "related",
          select: %{source: e.source_note_id, target: e.target_note_id, kind: e.kind}
      )

    by_notebook = Enum.group_by(notes, & &1.notebook_id)

    children =
      Enum.map(list_notebooks(), fn nb ->
        notebook_node(nb.id, nb.name, Map.get(by_notebook, nb.id, []))
      end) ++
        case Map.get(by_notebook, nil, []) do
          [] -> []
          unfiled -> [notebook_node(nil, "Unfiled", unfiled)]
        end

    children = Enum.reject(children, &(&1.count == 0))

    %{
      tree: %{uid: "root", kind: "root", name: "Vault", children: children},
      links: links,
      note_count: length(notes)
    }
  end

  defp notebook_node(id, name, notes) do
    children =
      if length(notes) > @flat_notebook_limit do
        notes
        |> Enum.group_by(&tag_bucket/1)
        |> Enum.sort_by(fn {tag, group} -> {-length(group), tag} end)
        |> Enum.map(fn {tag, group} ->
          %{
            uid: "tag-#{id}-#{tag}",
            kind: "tag",
            name: tag,
            count: length(group),
            children: Enum.map(group, &note_node/1)
          }
        end)
      else
        Enum.map(notes, &note_node/1)
      end

    %{uid: "nb-#{id}", kind: "notebook", name: name, count: length(notes), children: children}
  end

  defp tag_bucket(%Note{tags: tags}) do
    tags |> Enum.map(& &1.name) |> Enum.sort() |> List.first() || "untagged"
  end

  defp note_node(n) do
    %{uid: "note-#{n.id}", kind: "note", id: n.id, name: n.title || "(Untitled)"}
  end

  @doc "Clears the graph marker so the next BuildGraphWorker pass re-types this note."
  def mark_graph_stale(note_id) do
    Repo.update_all(from(n in Note, where: n.id == ^note_id), set: [graph_indexed_at: nil])
    :ok
  end

  defp find_or_create_tags([]), do: []

  defp find_or_create_tags(names) when is_list(names) do
    user_id = Repo.user_id!()

    Enum.map(names, fn name ->
      name = String.downcase(String.trim(name))

      Repo.insert!(%Tag{name: name, user_id: user_id},
        on_conflict: :nothing,
        conflict_target: [:user_id, :name]
      )

      Repo.get_by!(Tag, name: name)
    end)
  end
end
