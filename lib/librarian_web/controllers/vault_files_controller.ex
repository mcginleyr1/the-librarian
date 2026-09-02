defmodule LibrarianWeb.VaultFilesController do
  use LibrarianWeb, :controller

  import Ecto.Query

  alias Librarian.Repo
  alias Librarian.Vault.Note

  # Storage keys are guessable (small sequential integers), so possession of a
  # URL is not authorization: the file is only served if one of the current
  # user's notes points at it. Note is tenanted, so the exists check is
  # auto-scoped by Repo.prepare_query.
  def show(conn, %{"key" => key_parts}) do
    key = Enum.join(key_parts, "/")

    with true <- Repo.exists?(from n in Note, where: n.storage_key == ^key),
         {:ok, data} <- Librarian.Storage.get(key) do
      ext = Path.extname(key)
      content_type = MIME.type(String.trim_leading(ext, "."))

      conn
      |> put_resp_content_type(content_type)
      |> sandbox_html(ext)
      |> send_resp(200, data)
    else
      _ -> send_resp(conn, 404, "Not found")
    end
  end

  # Clipped pages are someone else's HTML; the sandbox directive stops their
  # scripts from running with this origin's cookies whether opened directly
  # or embedded in a canvas card.
  defp sandbox_html(conn, ext) when ext in [".html", ".htm"] do
    csp = conn |> get_resp_header("content-security-policy") |> List.first("")
    put_resp_header(conn, "content-security-policy", String.trim("#{csp} sandbox;"))
  end

  defp sandbox_html(conn, _ext), do: conn
end
