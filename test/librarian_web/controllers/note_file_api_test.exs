defmodule LibrarianWeb.NoteFileApiTest do
  # async: false — swaps the global storage path for a temp dir.
  use LibrarianWeb.ConnCase, async: false

  alias Librarian.{Accounts, Repo, Storage, Vault}

  defp user!, do: insert_allowed_user!("file")

  setup %{conn: conn} do
    tmp =
      Path.join(
        System.tmp_dir!(),
        "librarian_note_file_test_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp)
    previous = Application.get_env(:librarian, :storage_path)
    Application.put_env(:librarian, :storage_path, tmp)

    on_exit(fn ->
      Application.put_env(:librarian, :storage_path, previous)
      File.rm_rf!(tmp)
    end)

    user = Accounts.ensure_api_token!(user!())
    Repo.put_user_id(user.id)
    %{conn: put_req_header(conn, "authorization", "Bearer #{user.api_token}")}
  end

  defp file_note!(title, key, data) do
    :ok = Storage.put(key, data)
    {:ok, note} = Vault.create_note(%{title: title, clip_mode: "pdf", storage_key: key}, [])
    note
  end

  test "serves a clip's stored file to its owner, sandboxed", %{conn: conn} do
    note = file_note!("Paper", Storage.unique_key("clips", ".pdf"), "%PDF-1.4 paper")

    conn =
      conn |> put_req_header("accept", "application/pdf") |> get(~p"/api/notes/#{note.id}/file")

    assert response(conn, 200) == "%PDF-1.4 paper"
    assert get_resp_header(conn, "content-type") == ["application/pdf"]
    assert get_resp_header(conn, "content-security-policy") == ["sandbox"]
    assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
  end

  test "404s for another user's file, a note without a file and unknown ids", %{conn: conn} do
    foreign =
      Repo.with_user(user!().id, fn ->
        file_note!("Theirs", Storage.unique_key("clips", ".pdf"), "%PDF-1.4 secret")
      end)

    {:ok, plain} = Vault.create_note(%{title: "Text only", body: "x"}, [])

    for id <- [foreign.id, plain.id, 0, "abc"] do
      assert json_response(get(conn, ~p"/api/notes/#{id}/file"), 404) == %{"error" => "not_found"}
    end
  end

  test "requires a bearer token" do
    assert json_response(get(build_conn(), ~p"/api/notes/1/file"), 401) == %{
             "error" => "unauthorized"
           }
  end
end
