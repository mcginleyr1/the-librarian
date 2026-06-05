defmodule Librarian.Repo.Migrations.CreateInterestModel do
  use Ecto.Migration

  def change do
    create table(:interest_centroids) do
      add :label, :string, null: false
      add :embedding, :vector, size: 384, null: false
      add :weight, :float, default: 1.0, null: false
      add :member_count, :integer, default: 0, null: false
      timestamps(type: :utc_datetime)
    end

    create table(:affinities) do
      add :kind, :string, null: false
      add :key, :string, null: false
      add :score, :float, default: 0.0, null: false
      timestamps(type: :utc_datetime)
    end

    create unique_index(:affinities, [:kind, :key])
  end
end
