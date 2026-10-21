defmodule Librarian.Storage do
  @moduledoc """
  Local filesystem storage for binary vault content (PDFs, HTML snapshots, images).
  Mounted at STORAGE_PATH in production (k8s PVC), backed up to B2 by Mac mini.
  """

  def base_path, do: Application.fetch_env!(:librarian, :storage_path)

  @doc """
  A fresh key under `dir`, namespaced by the current tenant. Random rather than
  sequential so keys never collide across restarts or users.
  """
  def unique_key(dir, suffix) do
    "#{dir}/#{Librarian.Repo.user_id!()}/#{Ecto.UUID.generate()}#{suffix}"
  end

  def put(key, data) do
    full_path = path(key)
    full_path |> Path.dirname() |> File.mkdir_p!()
    File.write(full_path, data, [:binary])
  end

  def get(key), do: File.read(path(key))

  def delete(key), do: File.rm(path(key))

  def exists?(key), do: File.exists?(path(key))

  def url(key), do: "/vault/files/#{key}"

  # Keys can carry client-supplied names; anything resolving outside the
  # storage root (`..`, absolute paths) is refused.
  defp path(key) do
    case Path.safe_relative(key) do
      {:ok, relative} -> Path.join(base_path(), relative)
      :error -> raise ArgumentError, "unsafe storage key: #{inspect(key)}"
    end
  end
end
