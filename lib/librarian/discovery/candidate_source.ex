defmodule Librarian.Discovery.CandidateSource do
  use Ecto.Schema
  import Ecto.Changeset

  @statuses ~w(pending vetting accepted rejected)

  schema "candidate_sources" do
    field :domain, :string
    field :feed_url, :string
    field :channel, :string
    field :status, :string, default: "pending"
    field :mention_count, :integer, default: 1
    field :sample_hit_rate, :float
    field :intent_query, :string

    belongs_to :discovered_from_article, Librarian.Reader.Article
    belongs_to :user, Librarian.Accounts.User

    timestamps(type: :utc_datetime)
  end

  def changeset(candidate, attrs) do
    candidate
    |> cast(attrs, [
      :domain,
      :feed_url,
      :channel,
      :status,
      :mention_count,
      :sample_hit_rate,
      :intent_query,
      :discovered_from_article_id
    ])
    |> validate_required([:domain, :channel])
    |> validate_inclusion(:status, @statuses)
    |> unique_constraint(:domain, name: :candidate_sources_user_id_domain_index)
  end
end
