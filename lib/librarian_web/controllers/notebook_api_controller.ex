defmodule LibrarianWeb.NotebookApiController do
  use LibrarianWeb, :controller

  def index(conn, _params) do
    notebooks = Librarian.Vault.list_notebooks()
    json(conn, Enum.map(notebooks, &%{id: &1.id, name: &1.name}))
  end
end
