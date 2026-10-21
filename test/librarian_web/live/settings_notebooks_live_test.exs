defmodule LibrarianWeb.SettingsNotebooksLiveTest do
  use LibrarianWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Librarian.Vault

  setup :log_in_owner

  test "the duplicate-note warning shows once counted and clears after dedupe", %{conn: conn} do
    {:ok, _} = Vault.create_note(%{title: "Twin", body: "same"})
    {:ok, _} = Vault.create_note(%{title: "Twin", body: "same"})

    {:ok, view, _html} = live(conn, "/settings?tab=notebooks")

    render_async(view)
    assert has_element?(view, "button[phx-click='dedupe_notes']")

    view |> element("button[phx-click='dedupe_notes']") |> render_click()
    render_async(view)

    refute has_element?(view, "button[phx-click='dedupe_notes']")
    assert length(Vault.list_notes()) == 1
  end
end
