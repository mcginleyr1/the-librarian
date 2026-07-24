defmodule Librarian.Repo.Migrations.AddKnowledgeGraph do
  use Ecto.Migration

  def change do
    create table(:note_edges) do
      add :source_note_id, references(:notes, on_delete: :delete_all), null: false
      add :target_note_id, references(:notes, on_delete: :delete_all), null: false
      add :kind, :string, null: false
      add :reason, :text
      add :weight, :float, null: false, default: 1.0
      add :origin, :string, null: false
      add :user_id, references(:users, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:note_edges, [:source_note_id, :target_note_id, :kind])
    create index(:note_edges, [:target_note_id])

    create table(:annotations) do
      add :body, :text, null: false
      add :note_id, references(:notes, on_delete: :delete_all), null: false
      add :user_id, references(:users, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime)
    end

    create index(:annotations, [:note_id])

    create table(:llm_usage) do
      add :model, :string, null: false
      add :purpose, :string, null: false
      add :input_tokens, :integer, null: false, default: 0
      add :output_tokens, :integer, null: false, default: 0
      add :cost_cents, :float, null: false, default: 0.0

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:llm_usage, [:inserted_at])

    alter table(:settings) do
      add :anthropic_api_key, :string
      add :llm_monthly_budget_cents, :integer, null: false, default: 2000
    end

    alter table(:notes) do
      add :graph_indexed_at, :utc_datetime
    end
  end
end
