defmodule LibrarianWeb.SettingsLive do
  use LibrarianWeb, :live_view

  alias Librarian.{Reader, Vault, Settings}
  alias Librarian.Reader.{Feed, FeedDiscoverer}
  alias Librarian.Workers.{FetchFeedWorker, BackupWorker}
  alias Librarian.Repo

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(
       tab: :import,
       # Import tab
       importing_opml: false,
       importing_enex: false,
       import_result: nil,
       enex_notebook: "",
       # Feeds tab
       feeds: Reader.list_all_feeds(),
       categories: Reader.list_categories(),
       editing_feed_id: nil,
       feed_form: nil,
       new_feed_form: to_form(%{"title" => "", "feed_url" => "", "category" => ""}),
       # Feed discovery
       discovering: false,
       discovered_feeds: nil,
       discover_error: nil,
       # Notebooks tab
       notebooks: Vault.list_notebooks(),
       note_counts: Vault.count_notes_by_notebook(),
       editing_notebook_id: nil,
       # Backup tab
       backup_form: backup_settings_form()
     )
     |> allow_upload(:opml,
       accept: :any,
       max_entries: 1,
       max_file_size: 10_000_000
     )
     |> allow_upload(:enex,
       accept: :any,
       max_entries: 1,
       max_file_size: 500_000_000
     )}
  end

  @impl true
  def handle_params(%{"tab" => tab}, _uri, socket) do
    {:noreply, assign(socket, tab: String.to_existing_atom(tab))}
  end

  def handle_params(_params, _uri, socket), do: {:noreply, socket}

  @impl true
  # --- Import tab ---

  def handle_event("import_opml", _params, socket) do
    result =
      consume_uploaded_entries(socket, :opml, fn %{path: path}, _entry ->
        {:ok, Librarian.Release.import_opml(path)}
      end)

    case result do
      [{:ok, stats}] ->
        {:noreply,
         socket
         |> assign(
           import_result: {:opml, stats},
           feeds: Reader.list_all_feeds(),
           categories: Reader.list_categories()
         )}

      _ ->
        {:noreply, put_flash(socket, :error, "Import failed")}
    end
  end

  def handle_event("import_enex", %{"notebook" => notebook_name}, socket) do
    [{:ok, {path, client_name}}] =
      consume_uploaded_entries(socket, :enex, fn %{path: path}, entry ->
        dest =
          Path.join(
            System.tmp_dir!(),
            "librarian_enex_#{System.unique_integer([:positive])}.enex"
          )

        File.cp!(path, dest)
        {:ok, {dest, entry.client_name}}
      end)

    notebook =
      if notebook_name == "", do: Path.basename(client_name, ".enex"), else: notebook_name

    lv = self()

    Task.start(fn ->
      result = Librarian.Release.import_evernote(path, notebook)
      File.rm(path)
      send(lv, {:enex_done, result})
    end)

    {:noreply, assign(socket, importing_enex: true, import_result: nil)}
  end

  def handle_event("clear_result", _params, socket) do
    {:noreply, assign(socket, import_result: nil)}
  end

  def handle_event("cancel_opml", %{"ref" => ref}, socket) do
    {:noreply, cancel_upload(socket, :opml, ref)}
  end

  def handle_event("cancel_enex", %{"ref" => ref}, socket) do
    {:noreply, cancel_upload(socket, :enex, ref)}
  end

  def handle_event("validate_opml", _params, socket), do: {:noreply, socket}
  def handle_event("validate_enex", _params, socket), do: {:noreply, socket}

  # --- Feed discovery ---

  def handle_event("discover_feed", %{"url" => url}, socket) when byte_size(url) > 0 do
    lv = self()
    Task.start(fn -> send(lv, {:discovery_result, FeedDiscoverer.discover(url)}) end)
    {:noreply, assign(socket, discovering: true, discovered_feeds: nil, discover_error: nil)}
  end

  def handle_event("discover_feed", _params, socket) do
    {:noreply, assign(socket, discover_error: "Please enter a URL")}
  end

  def handle_event(
        "add_discovered",
        %{"feed_url" => url, "title" => title, "category" => cat},
        socket
      ) do
    case Reader.create_feed(%{
           title: title,
           feed_url: url,
           category: if(cat == "", do: nil, else: cat)
         }) do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign(
           feeds: Reader.list_all_feeds(),
           categories: Reader.list_categories(),
           discovered_feeds: nil,
           discover_error: nil
         )
         |> put_flash(:info, "Feed added: #{title}")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Could not add feed — may already exist")}
    end
  end

  def handle_event("clear_discovery", _params, socket) do
    {:noreply, assign(socket, discovered_feeds: nil, discover_error: nil)}
  end

  # --- Feeds tab ---

  def handle_event("fetch_all_feeds", _params, socket) do
    count =
      Reader.list_active_feeds()
      |> Enum.reduce(0, fn feed, acc ->
        %{feed_id: feed.id}
        |> FetchFeedWorker.new()
        |> Oban.insert()

        acc + 1
      end)

    {:noreply, put_flash(socket, :info, "Queued #{count} feeds for refresh")}
  end

  def handle_event("fetch_feed", %{"id" => id}, socket) do
    %{feed_id: String.to_integer(id)}
    |> FetchFeedWorker.new()
    |> Oban.insert()

    {:noreply, put_flash(socket, :info, "Feed queued for refresh")}
  end

  def handle_event("edit_feed", %{"id" => id}, socket) do
    feed = Repo.get!(Feed, String.to_integer(id))
    changeset = Feed.changeset(feed, %{})
    {:noreply, assign(socket, editing_feed_id: feed.id, feed_form: to_form(changeset))}
  end

  def handle_event("cancel_edit_feed", _params, socket) do
    {:noreply, assign(socket, editing_feed_id: nil, feed_form: nil)}
  end

  def handle_event("save_feed", %{"feed" => params}, socket) do
    feed = Enum.find(socket.assigns.feeds, &(&1.id == socket.assigns.editing_feed_id))

    case Reader.update_feed(feed, params) do
      {:ok, _} ->
        {:noreply,
         assign(socket,
           editing_feed_id: nil,
           feed_form: nil,
           feeds: Reader.list_all_feeds(),
           categories: Reader.list_categories()
         )}

      {:error, changeset} ->
        {:noreply, assign(socket, feed_form: to_form(changeset))}
    end
  end

  def handle_event("toggle_feed_active", %{"id" => id}, socket) do
    feed = Enum.find(socket.assigns.feeds, &(&1.id == String.to_integer(id)))
    Reader.update_feed(feed, %{active: !feed.active})
    {:noreply, assign(socket, feeds: Reader.list_all_feeds())}
  end

  def handle_event("delete_feed", %{"id" => id}, socket) do
    feed = Enum.find(socket.assigns.feeds, &(&1.id == String.to_integer(id)))
    Reader.delete_feed(feed)

    {:noreply,
     assign(socket, feeds: Reader.list_all_feeds(), categories: Reader.list_categories())}
  end

  def handle_event(
        "add_feed",
        %{"title" => title, "feed_url" => url, "category" => cat},
        socket
      ) do
    case Reader.create_feed(%{title: title, feed_url: url, category: cat}) do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign(
           feeds: Reader.list_all_feeds(),
           categories: Reader.list_categories(),
           new_feed_form: to_form(%{"title" => "", "feed_url" => "", "category" => ""})
         )
         |> put_flash(:info, "Feed added")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Invalid feed URL or duplicate")}
    end
  end

  # --- Notebooks tab ---

  def handle_event("edit_notebook", %{"id" => id}, socket) do
    {:noreply, assign(socket, editing_notebook_id: String.to_integer(id))}
  end

  def handle_event("cancel_edit_notebook", _params, socket) do
    {:noreply, assign(socket, editing_notebook_id: nil)}
  end

  def handle_event("save_notebook", %{"notebook_id" => id, "name" => name}, socket) do
    notebook =
      Enum.find(socket.assigns.notebooks, &(&1.id == String.to_integer(id)))

    Vault.update_notebook(notebook, %{name: name})
    {:noreply, assign(socket, notebooks: Vault.list_notebooks(), editing_notebook_id: nil)}
  end

  def handle_event("delete_notebook", %{"id" => id}, socket) do
    notebook =
      Enum.find(socket.assigns.notebooks, &(&1.id == String.to_integer(id)))

    Vault.delete_notebook(notebook)

    {:noreply,
     assign(socket,
       notebooks: Vault.list_notebooks(),
       note_counts: Vault.count_notes_by_notebook()
     )}
  end

  # --- Backup tab ---

  def handle_event("save_backup", %{"settings" => params}, socket) do
    case Settings.save_settings(params) do
      {:ok, _settings} ->
        {:noreply,
         socket
         |> put_flash(:info, "Backup settings saved")
         |> assign(backup_form: backup_settings_form())}

      {:error, changeset} ->
        {:noreply, assign(socket, backup_form: to_form(changeset))}
    end
  end

  def handle_event("run_backup", _params, socket) do
    %{}
    |> BackupWorker.new()
    |> Oban.insert()

    {:noreply, put_flash(socket, :info, "Backup queued — running in background")}
  end

  @impl true
  def handle_info({:discovery_result, {:ok, []}}, socket) do
    {:noreply, assign(socket, discovering: false, discover_error: "No feeds found at that URL")}
  end

  def handle_info({:discovery_result, {:ok, feeds}}, socket) do
    {:noreply, assign(socket, discovering: false, discovered_feeds: feeds)}
  end

  def handle_info({:discovery_result, {:error, reason}}, socket) do
    {:noreply,
     assign(socket, discovering: false, discover_error: "Could not reach URL: #{reason}")}
  end

  def handle_info({:enex_done, result}, socket) do
    {:noreply,
     socket
     |> assign(
       importing_enex: false,
       import_result: {:enex, result},
       notebooks: Vault.list_notebooks(),
       note_counts: Vault.count_notes_by_notebook()
     )}
  end

  defp tab_class(current, tab) do
    if current == tab, do: "tab tab-active", else: "tab"
  end

  defp backup_settings_form do
    settings = Settings.get_settings() || %Settings{id: 1}
    settings |> Settings.changeset(%{}) |> to_form()
  end
end
