defmodule LibrarianWeb.VaultFilesController do
  use LibrarianWeb, :controller

  def show(conn, %{"key" => key_parts}) do
    key = Enum.join(key_parts, "/")

    case Librarian.Storage.get(key) do
      {:ok, data} ->
        ext = Path.extname(key)
        content_type = MIME.type(String.trim_leading(ext, "."))

        conn
        |> put_resp_content_type(content_type)
        |> send_resp(200, data)

      {:error, _} ->
        send_resp(conn, 404, "Not found")
    end
  end
end
