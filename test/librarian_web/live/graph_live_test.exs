defmodule LibrarianWeb.GraphLiveTest do
  use LibrarianWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Librarian.Vault

  setup :log_in_owner

  describe "mind map async load" do
    test "loads the map in the async task with the tenant set", %{conn: conn} do
      {:ok, _note} = Vault.create_note(%{title: "Graphed note", body: "hello"}, ["topic"])

      {:ok, view, _html} = live(conn, "/vault/graph")

      # start_async runs mind_map/0 in a fresh Task process; before the fix it
      # raised "no tenant set" there and surfaced as a "Map failed to load" flash.
      html = render_async(view)

      refute html =~ "Map failed to load"
      assert html =~ "1 notes"
    end
  end
end
