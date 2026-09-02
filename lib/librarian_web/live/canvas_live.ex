defmodule LibrarianWeb.CanvasLive do
  use LibrarianWeb, :live_view

  alias Librarian.{Canvas, Storage, Vault}
  alias Librarian.Vault.{Edge, Note}

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(
       pages: [],
       page: nil,
       doc: Canvas.empty_doc(),
       notes: %{},
       editing_node_id: nil,
       edge_editor: nil,
       drawer_open: false,
       drawer_query: "",
       drawer_results: [],
       pending_drop: nil
     )
     |> allow_upload(:images,
       accept: ~w(.png .jpg .jpeg .gif .webp),
       max_entries: 5,
       max_file_size: 20_000_000,
       auto_upload: true,
       progress: &handle_progress/3
     )}
  end

  @impl true
  def handle_params(%{"id" => id}, _uri, socket) do
    page = Canvas.get_page!(id)

    {:noreply,
     assign(socket,
       page: page,
       doc: page.doc,
       notes: Canvas.notes_for(page.doc),
       page_title: page.title,
       editing_node_id: nil,
       edge_editor: nil
     )}
  end

  def handle_params(_params, _uri, socket) do
    {:noreply, assign(socket, pages: Canvas.list_pages(), page_title: "Canvas")}
  end

  # ---- index ----------------------------------------------------------------

  @impl true
  def handle_event("new_page", _params, socket) do
    {:ok, page} = Canvas.create_page(%{title: "Untitled page"})
    {:noreply, push_navigate(socket, to: "/canvas/#{page.id}")}
  end

  def handle_event("delete_page", %{"id" => id}, socket) do
    {:ok, _page} = Canvas.delete_page(Canvas.get_page!(id))
    {:noreply, assign(socket, pages: Canvas.list_pages())}
  end

  # ---- page -----------------------------------------------------------------

  def handle_event("rename", %{"title" => title}, socket) do
    case Canvas.update_page(socket.assigns.page, %{title: title}) do
      {:ok, page} -> {:noreply, assign(socket, page: page, page_title: page.title)}
      {:error, _changeset} -> {:noreply, socket}
    end
  end

  def handle_event("move_node", %{"id" => id, "x" => x, "y" => y} = params, socket) do
    attrs = put_height(%{"x" => x, "y" => y}, params)
    {:noreply, save(socket, Canvas.update_node(socket.assigns.doc, id, attrs))}
  end

  def handle_event("resize_node", %{"id" => id, "width" => width} = params, socket) do
    attrs = put_height(%{"width" => width}, params)
    {:noreply, save(socket, Canvas.update_node(socket.assigns.doc, id, attrs))}
  end

  def handle_event("add_text_node", %{"x" => x, "y" => y} = params, socket) do
    node = Canvas.text_node(x, y, Map.get(params, "text", ""))

    {:noreply,
     socket
     |> save(Canvas.add_node(socket.assigns.doc, node))
     |> assign(editing_node_id: node["id"])}
  end

  def handle_event("update_text", %{"node_id" => id, "text" => text}, socket) do
    {:noreply, save(socket, Canvas.update_node(socket.assigns.doc, id, %{"text" => text}))}
  end

  def handle_event("edit_text", %{"id" => id}, socket) do
    {:noreply, assign(socket, editing_node_id: id)}
  end

  def handle_event("stop_editing", %{"id" => id}, socket) do
    doc = socket.assigns.doc

    doc =
      case Canvas.find_node(doc, id) do
        %{"type" => "text", "text" => text} when is_binary(text) ->
          if String.trim(text) == "", do: Canvas.remove_node(doc, id), else: doc

        _ ->
          doc
      end

    {:noreply, socket |> save(doc) |> assign(editing_node_id: nil)}
  end

  def handle_event("delete_node", %{"id" => id}, socket) do
    {:noreply,
     socket
     |> save(Canvas.remove_node(socket.assigns.doc, id))
     |> assign(editing_node_id: nil)}
  end

  # ---- bringing things in ---------------------------------------------------

  def handle_event("toggle_drawer", _params, socket) do
    open? = !socket.assigns.drawer_open
    results = if open?, do: Vault.suggest_notes(socket.assigns.drawer_query, limit: 12), else: []
    {:noreply, assign(socket, drawer_open: open?, drawer_results: results)}
  end

  def handle_event("drawer_search", %{"q" => q}, socket) do
    {:noreply, assign(socket, drawer_query: q, drawer_results: Vault.suggest_notes(q, limit: 12))}
  end

  def handle_event("add_note_node", %{"note_id" => note_id, "x" => x, "y" => y}, socket) do
    node = Canvas.note_node(note_id, x, y)

    {:noreply,
     socket
     |> save(Canvas.add_node(socket.assigns.doc, node))
     |> reload_notes()}
  end

  def handle_event("add_link_node", %{"url" => url, "x" => x, "y" => y}, socket) do
    {:noreply, save(socket, Canvas.add_node(socket.assigns.doc, Canvas.link_node(url, x, y)))}
  end

  def handle_event("promote_node", %{"id" => id}, socket) do
    case Canvas.promote_text_node(socket.assigns.page, id) do
      {:ok, page} ->
        {:noreply,
         socket
         |> assign(page: page, doc: page.doc, editing_node_id: nil)
         |> reload_notes()}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Couldn't turn that card into a note")}
    end
  end

  def handle_event("wikilink_suggest", %{"q" => q}, socket) do
    suggestions = q |> Vault.suggest_notes(limit: 6) |> Enum.map(&%{id: &1.id, title: &1.title})
    {:reply, %{suggestions: suggestions}, socket}
  end

  def handle_event("drop_position", %{"x" => x, "y" => y}, socket) do
    {:noreply, assign(socket, pending_drop: %{x: x, y: y})}
  end

  def handle_event("validate_upload", _params, socket), do: {:noreply, socket}

  # ---- connectors -----------------------------------------------------------

  def handle_event("add_edge", %{"from" => from, "to" => to} = params, socket) do
    edge =
      %{"fromNode" => from, "toNode" => to}
      |> put_side("fromSide", params["fromSide"])
      |> put_side("toSide", params["toSide"])

    {:noreply, save(socket, Canvas.add_edge(socket.assigns.doc, edge))}
  end

  def handle_event("delete_edge", %{"id" => id}, socket) do
    {:noreply,
     socket
     |> save(Canvas.remove_edge(socket.assigns.doc, id))
     |> assign(edge_editor: nil)}
  end

  def handle_event("edit_edge", %{"id" => id, "x" => x, "y" => y}, socket) do
    editor = if Canvas.find_edge(socket.assigns.doc, id), do: %{id: id, x: x, y: y}
    {:noreply, assign(socket, edge_editor: editor)}
  end

  def handle_event("update_edge", %{"edge_id" => id, "label" => label}, socket) do
    attrs =
      case String.trim(label) do
        "" -> %{"label" => nil}
        label -> %{"label" => label}
      end

    doc = Canvas.update_edge(socket.assigns.doc, id, attrs)
    doc = %{doc | "edges" => Enum.map(doc["edges"], &Map.reject(&1, fn {_k, v} -> is_nil(v) end))}
    {:noreply, socket |> save(doc) |> assign(edge_editor: nil)}
  end

  def handle_event("close_edge_editor", _params, socket) do
    {:noreply, assign(socket, edge_editor: nil)}
  end

  defp put_side(edge, key, side) when side in ~w(top right bottom left),
    do: Map.put(edge, key, side)

  defp put_side(edge, _key, _side), do: edge

  defp handle_progress(:images, entry, socket) do
    if entry.done? do
      at = socket.assigns.pending_drop || %{x: 0, y: 0}

      [page] =
        consume_uploaded_entries(socket, :images, fn %{path: path}, entry ->
          Canvas.attach_image(
            socket.assigns.page,
            %{path: path, client_name: entry.client_name},
            at
          )
        end)

      {:noreply,
       socket
       |> assign(page: page, doc: page.doc, pending_drop: nil)
       |> reload_notes()}
    else
      {:noreply, socket}
    end
  end

  defp reload_notes(socket) do
    assign(socket, notes: Canvas.notes_for(socket.assigns.doc))
  end

  defp save(socket, doc) do
    if doc == socket.assigns.doc do
      socket
    else
      {:ok, page} = Canvas.save_doc(socket.assigns.page, doc)
      assign(socket, page: page, doc: page.doc)
    end
  end

  defp put_height(attrs, %{"height" => height}) when is_number(height) do
    Map.put(attrs, "height", height)
  end

  defp put_height(attrs, _params), do: attrs

  # ---- template helpers -----------------------------------------------------

  defp ordered_nodes(%{"nodes" => nodes}), do: Enum.sort_by(nodes, &(&1["type"] != "group"))

  defp text_html(text) do
    Phoenix.HTML.raw(Vault.render_note_html(%Note{clip_mode: "markdown", body: text}))
  end

  defp note_html(note), do: Phoenix.HTML.raw(Vault.render_note_html(note))

  defp framed?(%{"type" => "group"}, _note), do: true
  defp framed?(_node, %Note{clip_mode: mode}), do: mode in ~w(pdf full_page)
  defp framed?(_node, _note), do: false

  defp card_style(node, note) do
    base = "transform:translate(#{node["x"]}px,#{node["y"]}px);width:#{node["width"]}px"
    if framed?(node, note), do: base <> ";height:#{node["height"]}px", else: base
  end

  defp card_chrome("text"),
    do: "border border-transparent hover:border-base-300 focus-within:border-primary/50"

  defp card_chrome("group"), do: "border border-dashed border-primary/30 bg-primary/5 rounded-2xl"

  defp card_chrome(_),
    do: "bg-base-100 border border-base-300 shadow-sm hover:shadow-lg flex flex-col"

  defp clip_icon(%Note{clip_mode: "pdf"}), do: "hero-document"
  defp clip_icon(%Note{clip_mode: mode}) when mode in ~w(screenshot image), do: "hero-photo"

  defp clip_icon(%Note{clip_mode: mode}) when mode in ~w(full_page full_article selection),
    do: "hero-globe-alt"

  defp clip_icon(_note), do: "hero-document-text"

  defp edge_kinds, do: Edge.kinds() -- ["related"]

  defp card_count(%{"nodes" => nodes}), do: length(nodes)
  defp card_count(_doc), do: 0
end
