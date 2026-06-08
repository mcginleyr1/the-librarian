defmodule Librarian.Stream do
  @moduledoc """
  The personalized stream: signal capture (P1) and, on top of it, the ranked
  "For You" feed (P2). Every reaction the user makes is logged here as an
  `Interaction`, which is the training corpus the interest model learns from.
  """

  import Ecto.Query

  alias Librarian.Repo
  alias Librarian.Stream.Interaction

  # Level-2 success: deliberate endorsement. Pulls the interest model hardest.
  @positive ~w(like save more_like)
  # Level-1 success: you engaged but didn't endorse. A gentle positive nudge.
  @weak_positive ~w(open done)
  @negative ~w(dislike less_like mute_source mute_topic)
  # Terminal reactions remove an article from the For You feed. Reading alone
  # (`open`/`dwell`) is NOT terminal — read items stay so you can still act.
  @consumed @positive ++ @negative ++ ~w(done)

  def positive_kinds, do: @positive
  def weak_positive_kinds, do: @weak_positive
  def negative_kinds, do: @negative

  @doc """
  Logs an interaction for an article. `kind` is one of `Interaction.kinds/0`.
  Returns `{:ok, interaction}` or `{:error, changeset}`.
  """
  def record_interaction(article_id, kind, attrs \\ %{}) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    %Interaction{}
    |> Interaction.changeset(
      Map.merge(%{article_id: article_id, kind: to_string(kind), occurred_at: now}, attrs)
    )
    |> Repo.insert()
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

  defp interaction_article_ids(kinds) do
    Repo.all(
      from i in Interaction,
        where: i.kind in ^kinds,
        distinct: true,
        select: i.article_id
    )
  end
end
