defmodule Librarian.StorageTest do
  use ExUnit.Case, async: true

  alias Librarian.Storage

  setup do
    tmp = System.tmp_dir!() |> Path.join("librarian_storage_test_#{:rand.uniform(999_999)}")
    File.mkdir_p!(tmp)
    Application.put_env(:librarian, :storage_path, tmp)
    on_exit(fn -> File.rm_rf!(tmp) end)
    %{tmp: tmp}
  end

  test "put/2 writes a file and get/1 reads it back" do
    assert :ok = Storage.put("test/hello.txt", "hello world")
    assert {:ok, "hello world"} = Storage.get("test/hello.txt")
  end

  test "put/2 creates intermediate directories" do
    assert :ok = Storage.put("deep/nested/dir/file.bin", <<1, 2, 3>>)
    assert {:ok, <<1, 2, 3>>} = Storage.get("deep/nested/dir/file.bin")
  end

  test "get/1 returns error for missing file" do
    assert {:error, :enoent} = Storage.get("does/not/exist.txt")
  end

  test "delete/1 removes the file" do
    Storage.put("to_delete.txt", "bye")
    assert :ok = Storage.delete("to_delete.txt")
    assert {:error, :enoent} = Storage.get("to_delete.txt")
  end

  test "exists?/1 returns true for existing file" do
    Storage.put("check.txt", "data")
    assert Storage.exists?("check.txt")
  end

  test "exists?/1 returns false for missing file" do
    refute Storage.exists?("nope.txt")
  end

  test "url/1 returns the serving path" do
    assert Storage.url("notes/abc.pdf") == "/vault/files/notes/abc.pdf"
  end
end
