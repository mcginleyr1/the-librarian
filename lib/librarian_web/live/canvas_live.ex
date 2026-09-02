defmodule LibrarianWeb.CanvasLive do
  use LibrarianWeb, :live_view

  alias Librarian.{Canvas, Storage, Vault}
  alias Librarian.Vault.Note

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       pages: [],
       page: nil,
       doc: Canvas.empty_doc(),
       notes: %{},
       editing_node_id: nil
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
       editing_node_id: nil
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

  defp card_count(%{"nodes" => nodes}), do: length(nodes)
  defp card_count(_doc), do: 0
end
