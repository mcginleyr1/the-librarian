defmodule LibrarianWeb.GraphLive do
  use LibrarianWeb, :live_view

  alias Librarian.Vault

  # Starlight palette — desaturated luminous hues that glow on the night canvas.
  @palette ~w(#8b9cf7 #e8c47d #8fd8a8 #ef9bb0 #7dd8e8 #c0a8f0 #efae8a #9fb8d8)
  @unfiled "#7a86a8"

  @edge_legend [
    {"extends", "#8b9cf7"},
    {"contradicts", "#ef7d95"},
    {"example_of", "#7fd8a0"},
    {"references", "#7dd0e8"},
    {"same_topic", "#e8c47d"}
  ]

  @impl true
  def mount(_params, _session, socket) do
    socket =
      assign(socket,
        loading: true,
        node_count: 0,
        typed_count: 0,
        similarity_count: 0,
        notebook_legend: []
      )

    socket =
      if connected?(socket) do
        start_async(socket, :graph, fn -> Vault.graph() end)
      else
        socket
      end

    {:ok, socket}
  end

  @impl true
  def handle_async(:graph, {:ok, %{nodes: nodes, edges: edges}}, socket) do
    notebooks = Map.new(Vault.list_notebooks(), &{&1.id, &1.name})

    node_payload =
      Enum.map(nodes, fn n ->
        %{
          id: n.id,
          title: n.title || "(Untitled)",
          notebook: Map.get(notebooks, n.notebook_id),
          color: notebook_color(n.notebook_id),
          degree: n.degree
        }
      end)

    edge_payload =
      Enum.map(edges, &%{source: &1.source, target: &1.target, kind: &1.kind, weight: &1.weight})

    legend =
      node_payload
      |> Enum.map(&{&1.notebook || "Unfiled", &1.color})
      |> Enum.uniq()
      |> Enum.sort()

    typed = Enum.count(edges, &(&1.kind != "related"))

    {:noreply,
     socket
     |> assign(
       loading: false,
       node_count: length(nodes),
       typed_count: typed,
       similarity_count: length(edges) - typed,
       notebook_legend: legend
     )
     |> push_event("graph", %{nodes: node_payload, edges: edge_payload})}
  end

  def handle_async(:graph, {:exit, reason}, socket) do
    {:noreply,
     socket
     |> assign(loading: false)
     |> put_flash(:error, "Graph failed to load: #{inspect(reason)}")}
  end

  @impl true
  def handle_event("open_note", %{"id" => id}, socket) do
    {:noreply, push_navigate(socket, to: "/vault/note/#{id}")}
  end

  def notebook_color(nil), do: @unfiled

  def notebook_color(notebook_id),
    do: Enum.at(@palette, rem(:erlang.phash2(notebook_id), length(@palette)))

  def edge_legend, do: @edge_legend
end
