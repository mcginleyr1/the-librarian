defmodule LibrarianWeb.GraphLive do
  use LibrarianWeb, :live_view

  alias Librarian.Vault

  @palette ~w(#6366f1 #f59e0b #10b981 #ef4444 #06b6d4 #d946ef #84cc16 #f97316)
  @edge_legend [
    {"related", "#9ca3af"},
    {"extends", "#6366f1"},
    {"contradicts", "#ef4444"},
    {"example_of", "#10b981"},
    {"references", "#06b6d4"},
    {"same_topic", "#f59e0b"}
  ]
  @edge_colors Map.new(@edge_legend)

  @impl true
  def mount(_params, _session, socket) do
    socket =
      assign(socket,
        loading: true,
        nodes: [],
        edges: [],
        node_count: 0,
        edge_count: 0,
        notebooks: Vault.list_notebooks()
      )

    socket =
      if connected?(socket) do
        start_async(socket, :layout, fn -> Vault.graph_layout() end)
      else
        socket
      end

    {:ok, socket}
  end

  @impl true
  def handle_async(:layout, {:ok, %{nodes: nodes, edges: edges}}, socket) do
    {:noreply,
     assign(socket,
       loading: false,
       nodes: nodes,
       edges: edges,
       node_count: length(nodes),
       edge_count: length(edges)
     )}
  end

  def handle_async(:layout, {:exit, reason}, socket) do
    {:noreply,
     socket
     |> assign(loading: false)
     |> put_flash(:error, "Graph layout failed: #{inspect(reason)}")}
  end

  @impl true
  def handle_event("open_note", %{"id" => id}, socket) do
    {:noreply, push_navigate(socket, to: "/vault/note/#{id}")}
  end

  def notebook_color(nil), do: "#9ca3af"

  def notebook_color(notebook_id),
    do: Enum.at(@palette, rem(:erlang.phash2(notebook_id), length(@palette)))

  def edge_color(kind), do: Map.get(@edge_colors, kind, "#9ca3af")

  def edge_legend, do: @edge_legend

  def node_radius(degree), do: min(4 + degree * 1.5, 14)
end
