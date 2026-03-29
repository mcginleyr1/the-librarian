defmodule Librarian.Repo.Migrations.CreateSettings do
  use Ecto.Migration

  def change do
    create table(:settings) do
      add :b2_key_id, :string
      add :b2_application_key, :string
      add :b2_bucket_name, :string
      add :b2_endpoint, :string

      timestamps(type: :utc_datetime)
    end
  end
end
