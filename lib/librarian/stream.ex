defmodule Librarian.Stream do
  @moduledoc """
  The personalized stream: signal capture (P1) and, on top of it, the ranked
  "For You" feed (P2). Every reaction the user makes is logged here as an
  `Interaction`, which is the training corpus the interest model learns from.
  """

  import Ecto.Query

  alias Librarian.Reader.Subscription
  alias Librarian.Repo
  alias Librarian.Stream.Interaction
  alias Librarian.Workers.RebuildInterestWorker

  # Level-2 success: deliberate endorsement. Pulls the interest model hardest.
  @positive ~w(like save more_like)
  # Level-1 success: you engaged but didn't endorse. A gentle positive nudge.
  @weak_positive ~w(open done)
  @negative ~w(dislike less_like mute_source mute_topic)
  # Terminal reactions remove an article from the For You feed. Reading alone
  # (`open`/`dwell`) is NOT terminal — read items stay so you can still act.
  @consumed @positive ++ @negative ++ ~w(done)
  # Signals that change the positive corpus and so warrant a model rebuild.
  # Negatives are applied live as a ranking penalty, not baked into centroids.
  @model_kinds @positive ++ @weak_positive

  def positive_kinds, do: @positive
  def weak_positive_kinds, do: @weak_positive
  def negative_kinds, do: @negative
  def consumed_kinds, do: @consumed

  @doc """
  Logs an interaction for an article. `kind` is one of `Interaction.kinds/0`.
  Returns `{:ok, interaction}`, `{:error, changeset}`, or `{:error, :not_found}`
  for an article the user can't see.
  """
  def record_interaction(article_id, kind, attrs \\ %{}) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    result =
      if Librarian.Reader.visible_article?(article_id) do
        %Interaction{user_id: Repo.user_id!()}
        |> Interaction.changeset(
          Map.merge(%{article_id: article_id, kind: to_string(kind), occurred_at: now}, attrs)
        )
        |> Repo.insert()
      else
        {:error, :not_found}
      end

    if match?({:ok, _}, result) and to_string(kind) in @model_kinds do
      RebuildInterestWorker.enqueue()
    end

    result
  end

  @doc "Most recent interactions, newest first."
  def list_recent_interactions(limit \\ 100) do
    Repo.all(from i in Interaction, order_by: [desc: i.occurred_at], limit: ^limit)
  end

  @doc "Counts of interactions grouped by kind, e.g. %{\"like\" => 12, \"dislike\" => 3}."
  def signal_summary do
    Repo.all(from i in Interaction, group_by: i.kind, select: {i.kind, count(i.id)})
    |> Map.new()
  end

  @doc "Article ids the user reacted to positively (liked / saved / more-like)."
  def positive_article_ids do
    interaction_article_ids(@positive)
  end

  @doc "Article ids the user engaged with weakly (read / marked done) — level-1 signal."
  def weak_positive_article_ids do
    interaction_article_ids(@weak_positive)
  end

  @doc "Article ids the user reacted to negatively (disliked / less-like / muted)."
  def negative_article_ids do
    interaction_article_ids(@negative)
  end

  @doc "Article ids terminally acted on, so they drop out of the For You feed."
  def consumed_article_ids do
    interaction_article_ids(@consumed)
  end

  @doc """
  What the user read since `since`: one row per article they opened or reacted
  to, most recent first, with its feed, the user's category for that feed, when
  they last touched it and their reactions (like, save, dislike, …; reading
  itself isn't listed).
  """
  def recent_reading(since, limit) do
    categories =
      from s in Subscription,
        where: s.user_id == ^Repo.user_id!(),
        select: %{feed_id: s.feed_id, category: s.category}

    Repo.all(
      from i in Interaction,
        join: a in assoc(i, :article),
        join: f in assoc(a, :feed),
        left_join: s in subquery(categories),
        on: s.feed_id == f.id,
        where: i.occurred_at >= ^since,
        group_by: [a.id, f.title, s.category],
        order_by: [desc: max(i.occurred_at)],
        limit: ^limit,
        select: %{
          id: a.id,
          title: a.title,
          url: a.url,
          feed: f.title,
          category: s.category,
          last_read_at: max(i.occurred_at),
          reactions:
            fragment(
              "array_remove(array_remove(array_agg(DISTINCT ?), 'open'), 'dwell')",
              i.kind
            )
        }
    )
  end

  defp interaction_article_ids(kinds) do
    Repo.all(
      from i in Interaction,
        where: i.kind in ^kinds,
        distinct: true,
        select: i.article_id
    )
  end
end
