# Dev-only generator. Embeds sample content locally (Bumblebee) and bakes a JSON
# file the app seeds from at boot — so the container needs no model to demo the
# personalized stream. Run once after changing the samples:
#
#     mix run priv/repo/gen_demo_seed.exs
#
alias Librarian.Embeddings

feeds = [
  %{
    title: "Fly.io Blog",
    site_url: "https://fly.io",
    feed_url: "https://fly.io/blog/feed.xml",
    category: "Infrastructure"
  },
  %{
    title: "Erlang Solutions",
    site_url: "https://erlang-solutions.com",
    feed_url: "https://erlang-solutions.com/rss.xml",
    category: "BEAM"
  },
  %{
    title: "arXiv cs.CL",
    site_url: "https://arxiv.org",
    feed_url: "https://arxiv.org/rss/cs.CL",
    category: "AI/ML"
  },
  %{
    title: "Planet PostgreSQL",
    site_url: "https://planet.postgresql.org",
    feed_url: "https://planet.postgresql.org/rss20.xml",
    category: "Databases"
  },
  %{
    title: "Hacker News",
    site_url: "https://news.ycombinator.com",
    feed_url: "https://news.ycombinator.com/rss",
    category: "aggregators"
  }
]

# signal: like | save | dislike | nil. topics drive lenses; outbound links drive discovery.
articles = [
  %{
    feed: "Erlang Solutions",
    topics: ["beam"],
    content_type: "article",
    signal: "save",
    title: "Designing supervision trees that actually recover",
    url: "https://erlang-solutions.com/blog/supervision-trees",
    content:
      ~s(<p>OTP supervisors and GenServer restart strategies in practice. See also <a href="https://ferd.ca/the-zen-of-erlang.html">The Zen of Erlang</a> and <a href="https://learnyousomeerlang.com">LYSE</a>.</p>)
  },
  %{
    feed: "Erlang Solutions",
    topics: ["beam"],
    content_type: "tutorial",
    signal: "like",
    title: "Phoenix LiveView streams without memory ballooning",
    url: "https://erlang-solutions.com/blog/liveview-streams",
    content:
      ~s(<p>Using stream/3 and phx-update for large collections. Related: <a href="https://fly.io/blog/liveview-streams">Fly.io on streams</a>.</p>)
  },
  %{
    feed: "arXiv cs.CL",
    topics: ["ai-ml"],
    content_type: "paper",
    signal: "like",
    title: "Retrieval-augmented generation with knowledge-graph grounding",
    url: "https://arxiv.org/abs/2401.00001",
    content:
      ~s(<p>We present a RAG architecture that grounds an LLM in a property graph, improving factuality. Builds on <a href="https://arxiv.org/abs/2005.11401">the original RAG paper</a>.</p>)
  },
  %{
    feed: "arXiv cs.CL",
    topics: ["ai-ml"],
    content_type: "paper",
    signal: "save",
    title: "Context engineering: structured output and tool use at scale",
    url: "https://arxiv.org/abs/2401.00002",
    content: ~s(<p>Prompt and context strategies for reliable structured output from LLMs.</p>)
  },
  %{
    feed: "Planet PostgreSQL",
    topics: ["databases"],
    content_type: "article",
    signal: "like",
    title: "Vector search in Postgres with pgvector and HNSW indexes",
    url: "https://planet.postgresql.org/pgvector-hnsw",
    content:
      ~s(<p>Tuning HNSW for approximate nearest-neighbour search. See <a href="https://jepsen.io/analyses/postgresql">Jepsen on Postgres</a>.</p>)
  },
  %{
    feed: "Planet PostgreSQL",
    topics: ["databases"],
    content_type: "article",
    signal: nil,
    title: "Understanding the Postgres query planner's cost model",
    url: "https://planet.postgresql.org/query-planner",
    content: ~s(<p>How the planner estimates row counts and chooses join strategies.</p>)
  },
  %{
    feed: "Fly.io Blog",
    topics: ["distributed-systems"],
    content_type: "article",
    signal: nil,
    title: "Running a globally distributed Postgres without tears",
    url: "https://fly.io/blog/distributed-postgres",
    content: ~s(<p>Replication topology and consensus for multi-region writes.</p>)
  },
  %{
    feed: "Fly.io Blog",
    topics: ["systems-programming"],
    content_type: "article",
    signal: nil,
    title: "Writing a fast TCP proxy in Rust",
    url: "https://fly.io/blog/rust-tcp-proxy",
    content: ~s(<p>Zero-copy buffers and async IO with Tokio.</p>)
  },
  %{
    feed: "Hacker News",
    topics: [],
    content_type: "article",
    signal: "dislike",
    title: "10 productivity hacks that will change your life",
    url: "https://news.ycombinator.com/item?id=1",
    content:
      ~s(<p>A listicle. <a href="https://danluu.com/productivity">A more thoughtful take.</a></p>)
  },
  %{
    feed: "Hacker News",
    topics: [],
    content_type: "article",
    signal: "dislike",
    title: "Why I switched from framework X to framework Y",
    url: "https://news.ycombinator.com/item?id=2",
    content: ~s(<p>Hot take with little technical depth.</p>)
  },
  %{
    feed: "Hacker News",
    topics: ["ai-ml"],
    content_type: "article",
    signal: nil,
    title: "Show HN: local LLM inference on Apple Silicon with MLX",
    url: "https://news.ycombinator.com/item?id=3",
    content:
      ~s(<p>On-device inference benchmarks. Links to <a href="https://github.com/ml-explore/mlx">MLX</a>.</p>)
  },
  %{
    feed: "Hacker News",
    topics: ["beam"],
    content_type: "article",
    signal: nil,
    title: "Ask HN: how do you structure large Elixir umbrella apps?",
    url: "https://news.ycombinator.com/item?id=4",
    content: ~s(<p>Discussion of contexts and boundaries in Elixir.</p>)
  }
]

notes = [
  %{
    title: "GenStage back-pressure notes",
    body: "Broadway and GenStage for bounded concurrency on the BEAM. Demand-driven pipelines."
  },
  %{
    title: "LoRA fine-tuning cheatsheet",
    body: "Low-rank adapters, rank/alpha tradeoffs, when GRPO beats SFT for small models."
  },
  %{
    title: "Ecto composable queries",
    body: "Building queries with dynamic/2 and composing where clauses in Elixir contexts."
  },
  %{
    title: "Knowledge graphs + LLMs",
    body:
      "Constructing property graphs from text with an LLM, then grounding RAG retrieval on them."
  },
  %{
    title: "Postgres tsvector search",
    body: "Full-text search with tsvector, GIN indexes, and ranking with ts_rank."
  },
  %{
    title: "Distributed Erlang clustering",
    body: "libcluster strategies, node discovery, and partition handling on the BEAM."
  }
]

embed = fn text ->
  {:ok, v} = Embeddings.embed(text)
  Pgvector.to_list(v)
end

IO.puts("Embedding #{length(articles)} articles and #{length(notes)} notes...")

articles =
  Enum.map(articles, fn a ->
    Map.put(a, :embedding, embed.("#{a.title}\n\n#{a.content}"))
  end)

notes = Enum.map(notes, fn n -> Map.put(n, :embedding, embed.("#{n.title}\n\n#{n.body}")) end)

# Build labeled centroids: mean embedding of positive items grouped by primary topic.
positives =
  articles
  |> Enum.filter(&(&1.signal in ["like", "save"]))
  |> Enum.map(&{List.first(&1.topics) || "general", &1.embedding})

note_topic = fn n ->
  cond do
    String.contains?(n.title, ["GenStage", "Ecto", "Erlang"]) -> "beam"
    String.contains?(n.title, ["LoRA", "LLM", "graph"]) -> "ai-ml"
    String.contains?(n.title, ["Postgres"]) -> "databases"
    true -> "general"
  end
end

grouped =
  (positives ++ Enum.map(notes, &{note_topic.(&1), &1.embedding}))
  |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))

l2 = fn v ->
  norm = :math.sqrt(Enum.reduce(v, 0.0, &(&2 + &1 * &1)))
  if norm == 0.0, do: v, else: Enum.map(v, &(&1 / norm))
end

mean = fn vectors ->
  n = length(vectors)

  vectors
  |> Enum.reduce(List.duplicate(0.0, 384), fn v, acc -> Enum.zip_with(acc, v, &(&1 + &2)) end)
  |> Enum.map(&(&1 / n))
  |> l2.()
end

centroids =
  Enum.map(grouped, fn {label, vectors} ->
    %{label: label, member_count: length(vectors), embedding: mean.(vectors)}
  end)

data = %{feeds: feeds, articles: articles, notes: notes, centroids: centroids}
path = Path.join(:code.priv_dir(:librarian), "repo/demo_seed_data.json")
File.write!(path, Jason.encode!(data))
IO.puts("Wrote #{path} (#{length(centroids)} centroids)")
