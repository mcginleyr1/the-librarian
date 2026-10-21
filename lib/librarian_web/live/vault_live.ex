defmodule LibrarianWeb.VaultLive do
  use LibrarianWeb, :live_view

  alias Librarian.{Canvas, Vault}
  alias Librarian.Vault.Note

  @page_size 50

  @impl true
  def mount(_params, _session, socket) do
    notebooks = Vault.list_notebooks()
    note_counts = Vault.count_notes_by_notebook()

    {:ok,
     socket
     |> assign(
       notebooks: notebooks,
       note_counts: note_counts,
       selected_notebook_id: nil,
       selected_note: nil,
       editing: false,
       selection_mode: false,
       search_query: "",
       tags_input: "",
       note_offset: 0,
       more_notes?: false,
       related: [],
       annotations: [],
       mentions: [],
       rendered_body: nil,
       note_changeset: Note.changeset(%Note{}, %{}),
       show_notebooks: false,
       draft_body: "",
       editor_tab: :write,
       preview_html: nil,
       switcher_open: false,
       switcher_query: "",
       switcher_results: [],
       switcher_index: 0
     )
     |> stream(:notes, [])}
  end

  # Below `md` only one pane fits, so the three panes become a drill-down.
  defp mobile_pane(assigns) do
    cond do
      assigns.show_notebooks -> :notebooks
      assigns.selected_note || assigns.editing -> :note
      true -> :list
    end
  end

  @impl true
  def handle_params(%{"notebook_id" => nb_id}, _uri, socket) do
    {:noreply,
     socket
     |> assign(
       selected_notebook_id: String.to_integer(nb_id),
       selected_note: nil,
       editing: false,
       search_query: "",
       show_notebooks: false
     )
     |> load_notes(reset: true)}
  end

  def handle_params(%{"note_id" => note_id}, _uri, socket) do
    {:noreply,
     socket
     |> assign(selected_notebook_id: nil, search_query: "", show_notebooks: false)
     |> load_notes(reset: true)
     |> select_note(String.to_integer(note_id))}
  end

  def handle_params(_params, _uri, socket) do
    {:noreply,
     socket
     |> assign(
       selected_notebook_id: nil,
       selected_note: nil,
       editing: false,
       search_query: "",
       show_notebooks: false
     )
     |> load_notes(reset: true)}
  end

  @impl true
  def handle_event("select_note", %{"id" => id}, socket) do
    {:noreply, select_note(socket, String.to_integer(id))}
  end

  def handle_event("toggle_notebooks", _params, socket) do
    {:noreply, assign(socket, show_notebooks: !socket.assigns.show_notebooks)}
  end

  def handle_event("back_to_list", _params, socket) do
    {:noreply, assign(socket, selected_note: nil, editing: false)}
  end

  def handle_event("add_annotation", %{"body" => body}, socket) do
    note = socket.assigns.selected_note

    case Vault.create_annotation(note.id, body) do
      {:ok, _} ->
        Vault.mark_graph_stale(note.id)
        {:noreply, assign(socket, annotations: Vault.list_annotations(note.id))}

      {:error, _} ->
        {:noreply, socket}
    end
  end

  def handle_event("delete_annotation", %{"id" => id}, socket) do
    :ok = Vault.delete_annotation(String.to_integer(id))
    note = socket.assigns.selected_note
    {:noreply, assign(socket, annotations: Vault.list_annotations(note.id))}
  end

  def handle_event("delete_edge", %{"id" => id}, socket) do
    :ok = Vault.delete_edge(String.to_integer(id))
    note = socket.assigns.selected_note
    {:noreply, assign(socket, related: Vault.related_notes(note.id))}
  end

  def handle_event("refresh_connections", _params, socket) do
    note = socket.assigns.selected_note
    Vault.mark_graph_stale(note.id)
    Vault.generate_similarity_edges(note_id: note.id)
    %{"note_id" => note.id} |> Librarian.Workers.ExtractEdgesWorker.new() |> Oban.insert()

    {:noreply,
     socket
     |> assign(related: Vault.related_notes(note.id))
     |> put_flash(:info, "Rebuilding connections in the background")}
  end

  def handle_event("new_note", _params, socket) do
    {:noreply,
     socket
     |> assign(
       selected_note: nil,
       editing: true,
       tags_input: "",
       draft_body: "",
       editor_tab: :write,
       note_changeset: Note.changeset(%Note{}, %{})
     )}
  end

  def handle_event("edit_note", _params, socket) do
    note = socket.assigns.selected_note
    tags_str = Enum.map_join(note.tags, ", ", & &1.name)

    {:noreply,
     assign(socket,
       editing: true,
       tags_input: tags_str,
       draft_body: note.body || "",
       editor_tab: :write,
       note_changeset: Note.changeset(note, %{})
     )}
  end

  def handle_event("editor_change", %{"note" => %{"body" => body}}, socket) do
    {:noreply, assign(socket, draft_body: body)}
  end

  def handle_event("set_editor_tab", %{"tab" => "preview"}, socket) do
    html =
      Vault.render_note_html(%Note{clip_mode: "markdown", body: socket.assigns.draft_body})

    {:noreply, assign(socket, editor_tab: :preview, preview_html: html)}
  end

  def handle_event("set_editor_tab", %{"tab" => _}, socket) do
    {:noreply, assign(socket, editor_tab: :write)}
  end

  def handle_event("wikilink_suggest", %{"q" => q}, socket) do
    suggestions =
      Vault.suggest_notes(q, limit: 6)
      |> Enum.reject(&(socket.assigns.selected_note && &1.id == socket.assigns.selected_note.id))
      |> Enum.map(&%{id: &1.id, title: &1.title})

    {:reply, %{suggestions: suggestions}, socket}
  end

  def handle_event("compose", _params, socket) do
    {:ok, page} = Canvas.create_page_for_note(socket.assigns.selected_note)
    {:noreply, push_navigate(socket, to: "/canvas/#{page.id}")}
  end

  def handle_event("cancel_edit", _params, socket) do
    {:noreply, assign(socket, editing: false)}
  end

  def handle_event("save_note", %{"note" => params, "tags_input" => tags_str}, socket) do
    tags = split_tags(tags_str)
    nb_id = socket.assigns.selected_notebook_id

    attrs =
      if nb_id && !Map.has_key?(params, "notebook_id"),
        do: Map.put(params, "notebook_id", nb_id),
        else: params

    result =
      case socket.assigns.selected_note do
        # Notes authored in the app are markdown; clips/imports keep their mode.
        nil -> Vault.create_note(Map.put(attrs, "clip_mode", "markdown"), tags)
        note -> Vault.update_note(note, attrs, tags)
      end

    case result do
      {:ok, saved} ->
        note_counts = Vault.count_notes_by_notebook()

        {:noreply,
         socket
         |> select_note(saved.id)
         |> assign(note_counts: note_counts, notebooks: Vault.list_notebooks())
         |> stream_insert(:notes, Vault.get_note!(saved.id), at: 0)}

      {:error, changeset} ->
        {:noreply, assign(socket, note_changeset: changeset)}
    end
  end

  def handle_event("move_note", %{"_target" => _, "move-notebook-select" => ""}, socket) do
    note = socket.assigns.selected_note
    {:ok, updated} = Vault.update_note(note, %{notebook_id: nil})
    note = Vault.get_note!(updated.id)

    {:noreply,
     socket
     |> assign(selected_note: note, note_counts: Vault.count_notes_by_notebook())
     |> stream_insert(:notes, note)}
  end

  def handle_event("move_note", params, socket) do
    nb_id = params["move-notebook-select"] || params["notebook_id"]
    note = socket.assigns.selected_note
    {:ok, updated} = Vault.update_note(note, %{notebook_id: nb_id})
    note = Vault.get_note!(updated.id)

    {:noreply,
     socket
     |> assign(selected_note: note, note_counts: Vault.count_notes_by_notebook())
     |> stream_insert(:notes, note)}
  end

  def handle_event("delete_note", _params, socket) do
    note = socket.assigns.selected_note
    {:ok, _} = Vault.delete_note(note)
    note_counts = Vault.count_notes_by_notebook()

    {:noreply,
     socket
     |> assign(selected_note: nil, editing: false, note_counts: note_counts)
     |> stream_delete(:notes, note)}
  end

  def handle_event("load_more", _params, socket) do
    if socket.assigns.more_notes? do
      {:noreply, load_notes(socket, reset: false)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("toggle_selection_mode", _params, socket) do
    new_mode = !socket.assigns.selection_mode

    {:noreply,
     socket
     |> assign(selection_mode: new_mode, selected_note: nil, editing: false)
     |> load_notes(reset: true)}
  end

  def handle_event("bulk_delete", %{"ids" => ids}, socket) when is_list(ids) and ids != [] do
    {:ok, _count} = Vault.delete_notes(ids)
    note_counts = Vault.count_notes_by_notebook()

    {:noreply,
     socket
     |> assign(
       selection_mode: false,
       selected_note: nil,
       editing: false,
       note_counts: note_counts
     )
     |> load_notes(reset: true)}
  end

  def handle_event("bulk_delete", _params, socket) do
    {:noreply, assign(socket, selection_mode: false)}
  end

  def handle_event("search", %{"q" => q}, socket) do
    if String.trim(q) == "" do
      {:noreply, socket |> assign(search_query: q) |> load_notes(reset: true)}
    else
      notes = Vault.search(q, notebook_id: socket.assigns.selected_notebook_id)

      {:noreply,
       socket
       |> assign(search_query: q, more_notes?: false)
       |> stream(:notes, notes, reset: true)}
    end
  end

  def handle_event("create_notebook", %{"name" => name}, socket) when name != "" do
    case Vault.create_notebook(%{name: String.trim(name)}) do
      {:ok, _} ->
        {:noreply, assign(socket, notebooks: Vault.list_notebooks())}

      {:error, _} ->
        {:noreply, socket}
    end
  end

  def handle_event("create_notebook", _params, socket), do: {:noreply, socket}

  def handle_event("link_mention", %{"id" => id}, socket) do
    note = socket.assigns.selected_note
    :ok = Vault.link_notes(String.to_integer(id), note.id)

    {:noreply,
     assign(socket,
       related: Vault.related_notes(note.id),
       mentions: Vault.unlinked_mentions(note)
     )}
  end

  def handle_event("open_switcher", _params, socket) do
    {:noreply,
     assign(socket,
       switcher_open: true,
       switcher_query: "",
       switcher_results: Vault.suggest_notes(""),
       switcher_index: 0
     )}
  end

  def handle_event("close_switcher", _params, socket) do
    {:noreply, assign(socket, switcher_open: false)}
  end

  def handle_event("switcher_search", %{"q" => q}, socket) do
    {:noreply,
     assign(socket,
       switcher_query: q,
       switcher_results: Vault.suggest_notes(q),
       switcher_index: 0
     )}
  end

  def handle_event("switcher_keydown", %{"key" => "ArrowDown"}, socket) do
    max = max(length(socket.assigns.switcher_results) - 1, 0)
    {:noreply, assign(socket, switcher_index: min(socket.assigns.switcher_index + 1, max))}
  end

  def handle_event("switcher_keydown", %{"key" => "ArrowUp"}, socket) do
    {:noreply, assign(socket, switcher_index: max(socket.assigns.switcher_index - 1, 0))}
  end

  def handle_event("switcher_keydown", %{"key" => "Escape"}, socket) do
    {:noreply, assign(socket, switcher_open: false)}
  end

  def handle_event("switcher_keydown", _params, socket), do: {:noreply, socket}

  def handle_event("switcher_submit", _params, socket) do
    {:noreply,
     switcher_go(socket, Enum.at(socket.assigns.switcher_results, socket.assigns.switcher_index))}
  end

  def handle_event("switcher_select", %{"id" => id}, socket) do
    {:noreply, switcher_go(socket, %{id: String.to_integer(id)})}
  end

  defp switcher_go(socket, nil), do: assign(socket, switcher_open: false)

  defp switcher_go(socket, %{id: id}) do
    socket
    |> assign(switcher_open: false)
    |> push_patch(to: "/vault/note/#{id}")
  end

  defp select_note(socket, id) do
    note = Vault.get_note!(id)

    assign(socket,
      selected_note: note,
      editing: false,
      related: Vault.related_notes(id),
      annotations: Vault.list_annotations(id),
      mentions: Vault.unlinked_mentions(note),
      rendered_body: Vault.render_note_html(note)
    )
  end

  @kind_order ~w(extends contradicts example_of references same_topic related)
  @kind_labels %{
    "extends" => "Extends",
    "contradicts" => "Contradicts",
    "example_of" => "Example of",
    "references" => "References",
    "same_topic" => "Same topic",
    "related" => "Related"
  }

  defp group_related(related) do
    related
    |> Enum.group_by(fn %{edge: e} -> e.kind end)
    |> Enum.sort_by(fn {kind, _} -> Enum.find_index(@kind_order, &(&1 == kind)) || 99 end)
    |> Enum.map(fn {kind, entries} -> {Map.get(@kind_labels, kind, kind), entries} end)
  end

  defp split_tags(""), do: []

  defp split_tags(s),
    do: s |> String.split(",") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))

  defp load_notes(socket, opts) do
    reset = Keyword.fetch!(opts, :reset)
    offset = if reset, do: 0, else: socket.assigns.note_offset

    notes =
      Vault.list_notes(
        notebook_id: socket.assigns.selected_notebook_id,
        limit: @page_size,
        offset: offset
      )

    socket
    |> assign(note_offset: offset + length(notes), more_notes?: length(notes) == @page_size)
    |> stream(:notes, notes, reset: reset)
  end

  defp markdown_note?(nil), do: true
  defp markdown_note?(%Note{clip_mode: mode}), do: mode == "markdown"
end
