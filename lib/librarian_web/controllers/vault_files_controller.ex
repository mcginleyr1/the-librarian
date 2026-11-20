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
         {:ok, file_path} <- Librarian.Storage.file_path(key) do
      ext = Path.extname(key)
      content_type = MIME.type(String.trim_leading(ext, "."))

      conn
      |> put_resp_content_type(content_type, nil)
      |> sandbox(ext)
      |> send_file(200, file_path)
    else
      _ -> send_resp(conn, 404, "Not found")
    end
  end

  # Stored files are someone else's content (clipped HTML, uploaded SVG, ...);
  # the sandbox directive stops their scripts from running with this origin's
  # cookies whether opened directly or embedded. PDFs are exempt: browsers
  # refuse to render them in a sandboxed document, and they carry no script
  # that runs in this origin.
  defp sandbox(conn, ".pdf"), do: conn

  defp sandbox(conn, _ext) do
    put_resp_header(conn, "content-security-policy", "sandbox")
  end
end
