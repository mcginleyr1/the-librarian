defmodule LibrarianWeb.CanvasUploadTest do
  # Overrides the app-wide storage path, so it cannot run alongside other tests.
  use LibrarianWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Librarian.{Canvas, Storage, Vault}

  setup :log_in_owner

  setup do
    tmp = System.tmp_dir!() |> Path.join("librarian_canvas_test_#{:rand.uniform(999_999)}")
    File.mkdir_p!(tmp)
    previous = Application.get_env(:librarian, :storage_path)
    Application.put_env(:librarian, :storage_path, tmp)

    on_exit(fn ->
      Application.put_env(:librarian, :storage_path, previous)
      File.rm_rf!(tmp)
    end)

    :ok
  end

  test "a pasted image becomes an image note and a card at the drop point", %{conn: conn} do
    {:ok, page} = Canvas.create_page(%{title: "Board"})
    {:ok, view, _html} = live(conn, "/canvas/#{page.id}")

    png = <<137, 80, 78, 71, 13, 10, 26, 10>>

    image =
      file_input(view, "#canvas-upload", :images, [
        %{name: "whiteboard.png", content: png, type: "image/png"}
      ])

    render_hook(view, "drop_position", %{"x" => 50, "y" => 60})
    render_upload(image, "whiteboard.png")

    assert [note] = Vault.list_notes()
    assert note.clip_mode == "image"
    assert note.title == "whiteboard"
    assert String.ends_with?(note.storage_key, ".png")
    assert {:ok, ^png} = Storage.get(note.storage_key)

    assert [%{"type" => "file", "file" => file, "x" => 50, "y" => 60}] =
             Canvas.get_page!(page.id).doc["nodes"]

    assert file == "note:#{note.id}"

    assert has_element?(
             view,
             "[data-node-type='file'] img[src='/vault/files/#{note.storage_key}']"
           )

    assert conn |> get("/vault/files/#{note.storage_key}") |> response(200)
  end
end
