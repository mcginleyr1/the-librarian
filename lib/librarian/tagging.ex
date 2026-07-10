defmodule Librarian.Tagging do
  @moduledoc """
  Structured tagging of articles (P3). Locally this uses fast keyword + content
  heuristics so topic-lens chips and "why" explanations work without an LLM.

  `judge/1` is the seam for an LLM judge: when wired up it returns a richer
  judgement (topics, entities, a 0-10 judge score). Until then it returns
  `nil` and the heuristic tags stand alone.
  """

  import Ecto.Query

  alias Librarian.Repo
  alias Librarian.Reader.Article

  @topic_keywords %{
    "beam" => ~w(erlang elixir otp beam phoenix liveview genserver nerves rustler),
    "ai-ml" => ~w(llm rag embedding transformer inference fine-tune lora agent neural prompt),
    "databases" => ~w(postgres postgresql sql query planner index vacuum pgvector ecto),
    "distributed-systems" => ~w(distributed consensus raft paxos replication cluster partition),
    "systems-programming" => ~w(rust kernel memory compiler syscall concurrency zig assembly),
    "functional-programming" => ~w(monad functional immutable haskell lambda category combinator)
  }

  @doc "Tags all untagged articles, returning the number tagged."
  def tag_untagged(limit \\ 500) do
    Repo.all(from a in Article, where: is_nil(a.tagged_at), limit: ^limit)
    |> Enum.map(&tag_article/1)
    |> length()
  end

  @doc "Derives and persists structured tags for one article."
  def tag_article(%Article{} = article) do
    text = String.downcase("#{article.title} #{article.summary} #{article.content}")
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    judge = judge(article)

    article
    |> Ecto.Changeset.change(
      topics: derive_topics(text),
      content_type: derive_content_type(text),
      depth_score: derive_depth(article),
      judge_score: judge[:score],
      tagged_at: now
    )
    |> Repo.update!()
  end

  @doc """
  Seam for the host LLM judge. Returns a map like `%{score: 8.0, topics: [...]}`
  or `nil` locally.
  """
  def judge(%Article{}), do: %{score: nil}

  defp derive_topics(text) do
    @topic_keywords
    |> Enum.map(fn {topic, words} -> {topic, Enum.count(words, &String.contains?(text, &1))} end)
    |> Enum.filter(fn {_topic, hits} -> hits > 0 end)
    |> Enum.sort_by(fn {_topic, hits} -> -hits end)
    |> Enum.take(3)
    |> Enum.map(&elem(&1, 0))
  end

  defp derive_content_type(text) do
    cond do
      String.contains?(text, "arxiv") or String.contains?(text, "we present") -> "paper"
      String.contains?(text, "release") or String.contains?(text, "changelog") -> "release"
      String.contains?(text, "tutorial") or String.contains?(text, "how to") -> "tutorial"
      true -> "article"
    end
  end

  defp derive_depth(%Article{content: nil}), do: 0.0

  defp derive_depth(%Article{content: content}) do
    len = String.length(content)

    code =
      if String.contains?(content, "<code") or String.contains?(content, "```"),
        do: 0.3,
        else: 0.0

    min(1.0, len / 8_000 + code)
  end
end
