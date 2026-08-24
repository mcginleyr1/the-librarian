defmodule LibrarianWeb.GraphLive do
  use LibrarianWeb, :live_view

  alias Librarian.Repo
  alias Librarian.Vault

  # Mid-tone branch palette — readable on both light and dark themes.
  @palette ~w(#6366f1 #d97706 #059669 #db2777 #0891b2 #7c3aed #ca8a04 #64748b)

  @edge_legend [
    {"extends", "#6366f1"},
    {"contradicts", "#e11d48"},
    {"example_of", "#059669"},
    {"references", "#0891b2"},
    {"same_topic", "#d97706"}
  ]

  @impl true
  def mount(_params, _session, socket) do
    socket = assign(socket, loading: true, note_count: 0, link_count: 0)

    socket =
      if connected?(socket) do
        start_async(socket, :mind_map, Repo.bind_tenant(&Vault.mind_map/0))
      else
        socket
      end

    {:ok, socket}
  end

  @impl true
  def handle_async(:mind_map, {:ok, %{tree: tree, links: links, note_count: note_count}}, socket) do
    colored_children =
      tree.children
      |> Enum.with_index()
      |> Enum.map(fn {nb, i} ->
        Map.put(nb, :color, Enum.at(@palette, rem(i, length(@palette))))
      end)

    {:noreply,
     socket
     |> assign(loading: false, note_count: note_count, link_count: length(links))
     |> push_event("mindmap", %{tree: %{tree | children: colored_children}, links: links})}
  end

  def handle_async(:mind_map, {:exit, reason}, socket) do
    {:noreply,
     socket
     |> assign(loading: false)
     |> put_flash(:error, "Map failed to load: #{inspect(reason)}")}
  end

  @impl true
  def handle_event("open_note", %{"id" => id}, socket) do
    {:noreply, push_navigate(socket, to: "/vault/note/#{id}")}
  end

  def edge_legend, do: @edge_legend
end
