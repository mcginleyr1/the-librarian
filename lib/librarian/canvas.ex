defmodule Librarian.Canvas do
  @moduledoc """
  Composition pages: an infinite board where vault notes, free text, links and
  images are laid out as cards and joined by connectors. Each page is one
  JSON Canvas 1.0 document (`nodes` + `edges`, string keys). Connectors that
  join two note cards are mirrored into `note_edges` with origin `"canvas"`,
  the same way wiki-links are, so the rest of the vault sees them.
  """
  import Ecto.Query

  alias Librarian.Canvas.Page
  alias Librarian.Repo
  alias Librarian.Storage
  alias Librarian.Vault
  alias Librarian.Vault.Edge
  alias Librarian.Vault.Note

  @node_keys %{
    "text" => ~w(text),
    "file" => ~w(file subpath),
    "link" => ~w(url),
    "group" => ~w(label background backgroundStyle)
  }
  @required_node_key %{"text" => "text", "file" => "file", "link" => "url"}
  @base_node_keys ~w(id type x y width height color)
  @int_keys ~w(x y width height)
  @edge_keys ~w(id fromNode toNode fromSide toSide fromEnd toEnd color label)
  @sides ~w(top right bottom left)
  @edge_values %{
    "fromSide" => @sides,
    "toSide" => @sides,
    "fromEnd" => ~w(none arrow),
    "toEnd" => ~w(none arrow)
  }

  @note_width 360
  @text_width 260
  @default_height 120

  def empty_doc, do: %{"nodes" => [], "edges" => []}

  def list_pages do
    Repo.all(from p in Page, order_by: [desc: p.updated_at], preload: [:root_note])
  end

  def get_page!(id), do: Repo.get!(Page, id) |> Repo.preload(:root_note)

  def create_page(attrs) do
    with {:ok, doc} <- normalize_doc(Map.get(attrs, :doc, empty_doc())) do
      %Page{user_id: Repo.user_id!()}
      |> Page.changeset(Map.put(attrs, :doc, doc))
      |> Vault.validate_owned(:root_note_id, Note)
      |> Repo.insert()
    end
  end

  @doc "The Compose entry point: a page whose first card is the given note."
  def create_page_for_note(%Note{} = note) do
    create_page(%{
      title: note.title || "Untitled page",
      root_note_id: note.id,
      doc: %{"nodes" => [note_node(note.id, 0, 0)], "edges" => []}
    })
  end

  def update_page(%Page{} = page, attrs) do
    page |> Page.changeset(attrs) |> Vault.validate_owned(:root_note_id, Note) |> Repo.update()
  end

  def delete_page(%Page{} = page) do
    with {:ok, page} <- Repo.delete(page) do
      sync_edges()
      {:ok, page}
    end
  end

  @doc """
  Persists a client-authored document after normalizing it, and refreshes the
  mirrored note edges when the set of note-to-note connectors changed.
  """
  def save_doc(%Page{} = page, doc) do
    with {:ok, doc} <- normalize_doc(doc),
         {:ok, saved} <- page |> Page.changeset(%{doc: doc}) |> Repo.update() do
      if note_edges_for(doc) != note_edges_for(page.doc), do: sync_edges()
      {:ok, saved}
    end
  end

  @doc """
  Whitelists node and edge keys per type, truncates coordinates to integers and
  drops nodes of unknown type and edges whose endpoints are missing. This is the
  only validation the client-authored document gets.
  """
  def normalize_doc(%{} = doc) do
    nodes =
      doc
      |> Map.get("nodes", [])
      |> Enum.flat_map(&normalize_node/1)
      |> Enum.uniq_by(& &1["id"])

    ids = MapSet.new(nodes, & &1["id"])

    edges =
      doc
      |> Map.get("edges", [])
      |> Enum.flat_map(&normalize_edge(&1, ids))
      |> Enum.uniq_by(& &1["id"])

    {:ok, %{"nodes" => nodes, "edges" => edges}}
  end

  def normalize_doc(_), do: :error

  defp normalize_node(%{"id" => id, "type" => type} = node)
       when is_binary(id) and is_map_key(@node_keys, type) do
    node = Map.take(node, @base_node_keys ++ @node_keys[type])
    required = @required_node_key[type]

    if Enum.all?(@int_keys, &is_number(node[&1])) and
         (required == nil or is_binary(node[required])) do
      [Map.new(node, fn {k, v} -> {k, if(k in @int_keys, do: trunc(v), else: v)} end)]
    else
      []
    end
  end

  defp normalize_node(_), do: []

  defp normalize_edge(%{"id" => id, "fromNode" => from, "toNode" => to} = edge, ids)
       when is_binary(id) and from != to do
    if MapSet.member?(ids, from) and MapSet.member?(ids, to) do
      edge
      |> Map.take(@edge_keys)
      |> Enum.filter(fn {k, v} -> v in Map.get(@edge_values, k, [v]) end)
      |> Map.new()
      |> List.wrap()
    else
      []
    end
  end

  defp normalize_edge(_, _), do: []

  # ---- document values ------------------------------------------------------

  def text_node(x, y, text \\ "") do
    node(%{"type" => "text", "text" => text, "width" => @text_width}, x, y)
  end

  def note_node(note_id, x, y) do
    node(%{"type" => "file", "file" => "note:#{note_id}", "width" => @note_width}, x, y)
  end

  def link_node(url, x, y) do
    node(%{"type" => "link", "url" => url, "width" => @text_width}, x, y)
  end

  defp node(attrs, x, y) do
    Map.merge(
      %{"id" => Ecto.UUID.generate(), "x" => x, "y" => y, "height" => @default_height},
      attrs
    )
  end

  def add_node(doc, node), do: Map.update!(doc, "nodes", &(&1 ++ [node]))

  def update_node(doc, id, attrs) do
    Map.update!(doc, "nodes", fn nodes ->
      Enum.map(nodes, &if(&1["id"] == id, do: Map.merge(&1, attrs), else: &1))
    end)
  end

  def remove_node(doc, id) do
    %{
      doc
      | "nodes" => Enum.reject(doc["nodes"], &(&1["id"] == id)),
        "edges" => Enum.reject(doc["edges"], &(&1["fromNode"] == id or &1["toNode"] == id))
    }
  end

  def find_node(doc, id), do: Enum.find(doc["nodes"], &(&1["id"] == id))

  def add_edge(doc, edge) do
    edge = Map.merge(%{"id" => Ecto.UUID.generate(), "toEnd" => "arrow"}, edge)
    Map.update!(doc, "edges", &(&1 ++ [edge]))
  end

  def update_edge(doc, id, attrs) do
    Map.update!(doc, "edges", fn edges ->
      Enum.map(edges, &if(&1["id"] == id, do: Map.merge(&1, attrs), else: &1))
    end)
  end

  def remove_edge(doc, id) do
    Map.update!(doc, "edges", &Enum.reject(&1, fn e -> e["id"] == id end))
  end

  def find_edge(doc, id), do: Enum.find(doc["edges"], &(&1["id"] == id))

  # ---- notes behind file nodes ----------------------------------------------

  @doc "Vault note ids referenced by the document's file nodes."
  def note_ids(%{"nodes" => nodes}) do
    for %{"type" => "file", "file" => "note:" <> id} <- nodes,
        {n, ""} <- [Integer.parse(id)],
        uniq: true,
        do: n
  end

  def note_id(%{"type" => "file", "file" => "note:" <> id}) do
    case Integer.parse(id) do
      {n, ""} -> n
      _ -> nil
    end
  end

  def note_id(_), do: nil

  @doc """
  The notes behind a document's file nodes, keyed by id. Tenancy scoping means
  another user's note ids simply come back missing.
  """
  def notes_for(doc) do
    case note_ids(doc) do
      [] ->
        %{}

      ids ->
        Repo.all(from n in Note, where: n.id in ^ids, preload: [:tags]) |> Map.new(&{&1.id, &1})
    end
  end

  # ---- bringing things in ---------------------------------------------------

  @doc """
  Turns a text card into a vault note: the first line becomes the title, the
  card becomes a note card, and a page without a root note adopts it.
  """
  def promote_text_node(%Page{} = page, node_id) do
    with %{"type" => "text", "text" => text} = node <- find_node(page.doc, node_id),
         {:ok, note} <-
           Vault.create_note(%{title: first_line(text), body: text, clip_mode: "markdown"}) do
      doc =
        update_node(page.doc, node_id, %{
          "type" => "file",
          "file" => "note:#{note.id}",
          "width" => max(node["width"], @note_width)
        })

      attrs = %{doc: doc, root_note_id: page.root_note_id || note.id}

      with {:ok, doc} <- normalize_doc(doc),
           {:ok, saved} <- page |> Page.changeset(%{attrs | doc: doc}) |> Repo.update() do
        sync_edges()
        {:ok, saved}
      end
    else
      nil -> {:error, :not_a_text_node}
      %{} -> {:error, :not_a_text_node}
      error -> error
    end
  end

  defp first_line(text) do
    text
    |> String.split("\n", trim: true)
    |> List.first()
    |> Kernel.||("Untitled")
    |> String.replace(~r/^[#>\s*-]+/, "")
    |> String.slice(0, 120)
  end

  @doc """
  Stores an uploaded image as a vault note (so the file route and backup cover
  it) and drops it on the page at the given point.
  """
  def attach_image(%Page{} = page, %{path: path, client_name: name}, %{x: x, y: y}) do
    key = Storage.unique_key("clips", name |> Path.extname() |> String.downcase())

    with :ok <- Storage.put(key, File.read!(path)),
         {:ok, note} <-
           Vault.create_note(%{
             title: Path.rootname(name),
             clip_mode: "image",
             storage_key: key
           }) do
      node = %{note_node(note.id, x, y) | "width" => 320}
      save_doc(page, add_node(page.doc, node))
    end
  end

  # ---- mirrored note edges --------------------------------------------------

  @doc """
  Recomputes the tenant's canvas edges across all pages. Existing rows owned by
  another origin are left alone; canvas rows no page expresses any more are
  removed. Per tenant rather than per page because the unique index on
  `(source, target, kind)` is global.
  """
  def sync_edges do
    entries =
      Repo.all(from p in Page, select: p.doc)
      |> Enum.flat_map(&note_edges_for/1)
      |> Enum.uniq_by(&{&1.source_note_id, &1.target_note_id, &1.kind})

    Vault.upsert_edges(entries, on_conflict: :nothing)

    keep = MapSet.new(entries, &{&1.source_note_id, &1.target_note_id, &1.kind})

    stale =
      Repo.all(
        from e in Edge,
          where: e.origin == "canvas",
          select: {e.id, e.source_note_id, e.target_note_id, e.kind}
      )
      |> Enum.reject(fn {_id, s, t, k} -> MapSet.member?(keep, {s, t, k}) end)
      |> Enum.map(&elem(&1, 0))

    Repo.delete_all(from e in Edge, where: e.id in ^stale)
    :ok
  end

  @doc "Note-to-note edges a document expresses: connectors joining two note cards."
  def note_edges_for(%{"nodes" => nodes, "edges" => edges}) do
    notes = for node <- nodes, id = note_id(node), into: %{}, do: {node["id"], id}

    for %{"fromNode" => from, "toNode" => to} = edge <- edges,
        source = notes[from],
        target = notes[to],
        source != target do
      {kind, reason} = edge_kind(edge["label"])

      %{
        source_note_id: source,
        target_note_id: target,
        kind: kind,
        reason: reason,
        weight: 1.0,
        origin: "canvas"
      }
    end
  end

  def note_edges_for(_), do: []

  defp edge_kind(label) when label in [nil, ""], do: {"references", nil}

  defp edge_kind(label) do
    kind = label |> String.trim() |> String.downcase() |> String.replace(" ", "_")
    if kind in Edge.kinds(), do: {kind, nil}, else: {"references", String.trim(label)}
  end
end
