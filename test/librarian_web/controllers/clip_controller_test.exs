defmodule LibrarianWeb.ClipControllerTest do
  use LibrarianWeb.ConnCase, async: false

  alias Librarian.{Accounts, Repo, Storage, Vault}
  alias Librarian.Accounts.User

  setup %{conn: conn} do
    tmp = System.tmp_dir!() |> Path.join("librarian_clip_test_#{:rand.uniform(999_999)}")
    previous = Application.get_env(:librarian, :storage_path)
    Application.put_env(:librarian, :storage_path, tmp)

    on_exit(fn ->
      Application.put_env(:librarian, :storage_path, previous)
      File.rm_rf!(tmp)
    end)

    user = Accounts.ensure_api_token!(Accounts.owner!())

    conn =
      conn
      |> put_req_header("authorization", "Bearer #{user.api_token}")
      |> put_req_header("content-type", "application/json")

    %{conn: conn, user: user}
  end

  defp clip(conn, body), do: post(conn, "/api/clips", Jason.encode!(body))

  test "binary clips get a random, per-user storage key", %{conn: conn, user: user} do
    conn = clip(conn, %{title: "Paper", clip_mode: "pdf", body: Base.encode64("%PDF-1.4")})

    assert %{"status" => "ok", "id" => id} = json_response(conn, 200)
    key = Vault.get_note!(id).storage_key
    assert key =~ ~r"^clips/#{user.id}/[0-9a-f-]{36}\.pdf$"
    assert {:ok, "%PDF-1.4"} = Storage.get(key)
  end

  test "malformed notebook ids and tags are rejected, not crashed on", %{conn: conn} do
    assert %{"errors" => %{"notebook_id" => _}} =
             conn |> clip(%{title: "x", notebook_id: "abc"}) |> json_response(422)

    assert %{"errors" => %{"tags" => _}} =
             conn |> clip(%{title: "x", tags: "not-a-list"}) |> json_response(422)
  end

  test "another user's notebook is refused", %{conn: conn} do
    other = Repo.insert!(%User{email: "clip-#{System.unique_integer([:positive])}@example.com"})
    {:ok, notebook} = Repo.with_user(other.id, fn -> Vault.create_notebook(%{name: "theirs"}) end)

    assert %{"errors" => %{"notebook_id" => ["does not exist"]}} =
             conn |> clip(%{title: "x", notebook_id: notebook.id}) |> json_response(422)
  end
end
