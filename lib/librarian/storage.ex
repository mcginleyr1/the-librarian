defmodule Librarian.Storage do
  @moduledoc """
  Local filesystem storage for binary vault content (PDFs, HTML snapshots, images).
  Mounted at STORAGE_PATH in production (k8s PVC), backed up to B2 by Mac mini.
  """

  def base_path, do: Application.fetch_env!(:librarian, :storage_path)

  def put(key, data) do
    full_path = path(key)
    full_path |> Path.dirname() |> File.mkdir_p!()
    File.write(full_path, data, [:binary])
  end

  def get(key), do: File.read(path(key))

  def delete(key), do: File.rm(path(key))

  def exists?(key), do: File.exists?(path(key))

  def url(key), do: "/vault/files/#{key}"

  defp path(key), do: Path.join(base_path(), key)
end
