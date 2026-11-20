defmodule LibrarianWeb.HealthController do
  @moduledoc "Kubernetes probe target: 200 while the database answers, 503 otherwise."
  use LibrarianWeb, :controller

  def show(conn, _params) do
    # credo:disable-for-next-line Librarian.CredoChecks.RawSQL
    case Librarian.Repo.query("SELECT 1") do
      {:ok, _} -> send_resp(conn, 200, "ok")
      {:error, _} -> send_resp(conn, 503, "database unavailable")
    end
  end
end
