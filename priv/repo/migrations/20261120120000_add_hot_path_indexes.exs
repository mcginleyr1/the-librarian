defmodule Librarian.Repo.Migrations.AddHotPathIndexes do
  use Ecto.Migration

  def change do
    # Vector similarity (similarity edges, neighbor_candidates) is O(N^2)
    # sequential scan without an ANN index.
    create index(:notes, ["embedding vector_cosine_ops"],
             using: :hnsw,
             name: :notes_embedding_hnsw_index
           )

    # Per-user list/backup/graph scans and the /vault/files lookup.
    create index(:notes, [:user_id, :storage_key])
    create index(:notes, [:user_id, :updated_at])
    create index(:notes, [:user_id, :inserted_at])

    # Ranking, recent reading, and discovery pruning.
    create index(:interactions, [:user_id, :article_id, :kind])
    create index(:interactions, [:user_id, :occurred_at])
  end
end
