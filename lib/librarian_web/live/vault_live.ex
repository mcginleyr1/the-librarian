defmodule LibrarianWeb.VaultLive do
  use LibrarianWeb, :live_view

  alias Librarian.Vault
  alias Librarian.Vault.Note

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
       search_query: "",
       tags_input: "",
       note_changeset: Note.changeset(%Note{}, %{})
     )
     |> stream(:notes, [])}
  end

  @impl true
  def handle_params(%{"notebook_id" => nb_id}, _uri, socket) do
    nb_id = String.to_integer(nb_id)
    notes = Vault.list_notes_for_notebook(nb_id)

    {:noreply,
     socket
     |> assign(selected_notebook_id: nb_id, selected_note: nil, editing: false)
     |> stream(:notes, notes, reset: true)}
  end

  def handle_params(_params, _uri, socket) do
    notes = Vault.list_all_notes(limit: 50)

    {:noreply,
     socket
     |> assign(selected_notebook_id: nil, selected_note: nil, editing: false)
     |> stream(:notes, notes, reset: true)}
  end

  @impl true
  def handle_event("select_note", %{"id" => id}, socket) do
    note = Vault.get_note!(String.to_integer(id))
    {:noreply, assign(socket, selected_note: note, editing: false)}
  end

  def handle_event("new_note", _params, socket) do
    {:noreply,
     socket
     |> assign(
       selected_note: nil,
       editing: true,
       tags_input: "",
       note_changeset: Note.changeset(%Note{}, %{})
     )}
  end

  def handle_event("edit_note", _params, socket) do
    note = socket.assigns.selected_note
    tags_str = note.tags |> Enum.map(& &1.name) |> Enum.join(", ")

    {:noreply,
     assign(socket,
       editing: true,
       tags_input: tags_str,
       note_changeset: Note.changeset(note, %{})
     )}
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
        nil -> Vault.create_note(attrs, tags)
        note -> Vault.update_note(note, attrs, tags)
      end

    case result do
      {:ok, saved} ->
        note = Vault.get_note!(saved.id)
        note_counts = Vault.count_notes_by_notebook()

        {:noreply,
         socket
         |> assign(
           selected_note: note,
           editing: false,
           note_counts: note_counts,
           notebooks: Vault.list_notebooks()
         )
         |> stream_insert(:notes, note, at: 0)}

      {:error, changeset} ->
        {:noreply, assign(socket, note_changeset: changeset)}
    end
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

  def handle_event("search", %{"q" => q}, socket) do
    notes =
      if String.trim(q) == "" do
        reload_notes(socket)
      else
        Vault.search(q)
      end

    {:noreply, socket |> assign(search_query: q) |> stream(:notes, notes, reset: true)}
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

  defp split_tags(""), do: []

  defp split_tags(s),
    do: s |> String.split(",") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))

  defp reload_notes(%{assigns: %{selected_notebook_id: nil}}), do: Vault.list_all_notes(limit: 50)

  defp reload_notes(%{assigns: %{selected_notebook_id: id}}),
    do: Vault.list_notes_for_notebook(id)
end
