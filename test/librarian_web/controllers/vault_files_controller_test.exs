defmodule LibrarianWeb.VaultFilesControllerTest do
  use LibrarianWeb.ConnCase, async: false

  alias Librarian.{Repo, Storage, Vault}
  alias Librarian.Accounts.User

  setup :log_in_owner

  setup do
    tmp = System.tmp_dir!() |> Path.join("librarian_files_test_#{:rand.uniform(999_999)}")
    File.mkdir_p!(tmp)
    previous = Application.get_env(:librarian, :storage_path)
    Application.put_env(:librarian, :storage_path, tmp)

    on_exit(fn ->
      Application.put_env(:librarian, :storage_path, previous)
      File.rm_rf!(tmp)
    end)

    :ok
  end

  test "serves a stored file only to the note's owner", %{conn: conn} do
    :ok = Storage.put("clips/42.png", <<137, 80, 78, 71>>)
    {:ok, _note} = Vault.create_note(%{title: "Clip", storage_key: "clips/42.png"}, [])

    assert conn |> get("/vault/files/clips/42.png") |> response(200)

    other =
      Repo.insert!(%User{email: "other-#{System.unique_integer([:positive])}@example.com"})

    other_conn = log_in_user(build_conn(), other)
    assert other_conn |> get("/vault/files/clips/42.png") |> response(404)
  end

  test "clipped HTML is served sandboxed; other attachments are not", %{conn: conn} do
    :ok = Storage.put("clips/7.html", "<script>alert(1)</script>")
    :ok = Storage.put("clips/8.pdf", "%PDF-1.4")
    {:ok, _} = Vault.create_note(%{title: "Page", storage_key: "clips/7.html"}, [])
    {:ok, _} = Vault.create_note(%{title: "Paper", storage_key: "clips/8.pdf"}, [])

    html = get(conn, "/vault/files/clips/7.html")
    assert response(html, 200)
    assert [csp] = get_resp_header(html, "content-security-policy")
    assert csp =~ "sandbox"

    pdf = get(conn, "/vault/files/clips/8.pdf")
    assert response_content_type(pdf, :pdf)
    refute get_resp_header(pdf, "content-security-policy") |> Enum.join() =~ "sandbox"
  end

  test "404s for keys no note points at, even for the owner", %{conn: conn} do
    :ok = Storage.put("clips/orphan.png", <<1>>)
    assert conn |> get("/vault/files/clips/orphan.png") |> response(404)
  end
end
