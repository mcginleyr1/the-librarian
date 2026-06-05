# Prismatic — Build Plan

A Prismatic-inspired evolution of The Librarian. The user never adds or removes a
source again. They react to items; the system grows, vets, and prunes sources to
maximize the rate at which it shows things the user reacts well to.

Built in the `prismatic/` fork. Module namespace stays `Librarian.*`.

## Decisions (locked)

- **Build target:** the `prismatic/` fork (the-librarian stays the stable daily driver).
- **Inference:** in-BEAM embeddings via **Bumblebee** (`all-MiniLM-L6-v2`, 384-dim, EXLA CPU) + Claude judge only on the borderline shortlist. *(Switched from Ollama: the Homebrew Ollama formula ships no `llama-server`, and Bumblebee removes the external-server dependency entirely — embeddings run as a supervised `Nx.Serving`.)*
- **Discovery:** link-graph expansion + aggregator mining (HN/Lobsters/Reddit). No search/author channels yet.
- **Ranking:** hybrid — cheap vector + affinity prefilter over everything, expensive LLM judge on the shortlist.

## The inversion

Today: `Feed → Articles → user reads`, user manages feeds.
New: a learned **interest model** + a self-managing **source pool** + a single ranked
**stream**. Sources are owned by the system. Behavior is owned by the user.

## What already exists (reuse, don't rebuild)

- `Librarian.Reader.FeedDiscoverer` — URL → feed. The discovery engine's vetting step.
- `Librarian.Workers.CurateFeedsWorker` + host agent (`knowledge/scripts/curate-server.py`,
  port 9723, reachable from pods via `host.internal`). Reframed from "summarize" to "tag, judge, discover."
- `knowledge/profiles/*.md` — become the **cold-start prior**, then behavior refines them.
- Vault (450+ BEAM, 161+ AI/ML, 130+ DB notes) + starred/saved `read_states` — a labeled
  positive corpus. **The model is not cold-started; embed the vault and it's strong on day one.**

## Infra prerequisites

- **pgvector**: switch `k8s/postgres.yaml` to a `pgvector/pgvector` image (or install the
  extension); plain postgres won't have it. Migration enables `vector`.
- **Bumblebee/EXLA**: embeddings run in-BEAM as a supervised `Nx.Serving` — no external
  server. `exla` builds the XLA runtime (CPU); model weights download from HuggingFace and
  should be cached on the `/data` PVC in prod so pods don't re-fetch on restart. In the k8s
  container this is CPU inference (no Metal), which is fine for batch embedding at this volume.

## Schema (generate each with `mix ecto.gen.migration`)

```
-- enable pgvector; embeddings for cold-start + ranking
articles.embedding        vector(384)        -- all-MiniLM-L6-v2
notes.embedding           vector(384)        -- vault, for cold-start positives

-- structured item representation (written by the reframed agent)
articles.topics           text[]
articles.entities         jsonb              -- [{type: person|org|tech, name}]
articles.content_type     string             -- paper|tutorial|opinion|release|news
articles.depth_score      float
articles.judge_score      float              -- 0-10 from LLM judge (shortlist only)
articles.tagged_at        utc_datetime

-- the training corpus (append-only)
interactions
  id, article_id, type, value, dwell_ms, occurred_at
  -- type: open|dwell|like|dislike|save|more_like|less_like|mute_source|mute_topic

-- self-managing source pool
feeds.origin              string default "manual"   -- manual|discovered
feeds.trust_score         float default 0.5
feeds.like_rate           float                     -- rolling, drives promote/prune
feeds.discovered_at       utc_datetime

-- discovery queue
candidate_sources
  id, domain, feed_url, channel, discovered_from_article_id,
  status, sample_hit_rate, inserted_at
  -- channel: link_graph|aggregator ; status: pending|vetting|accepted|rejected

-- the learned interest model
interest_centroids        id, label, embedding vector(768), weight, updated_at
affinities                id, kind, key, score, updated_at   -- kind: topic|entity|source

-- materialized ranking
article_scores
  article_id, score, components jsonb, exploration boolean, scored_at
```

## Contexts / modules (new)

- `Librarian.Embeddings` — `embed(text) -> {:ok, vector}` via Req to host Ollama. Thin, swappable.
- `Librarian.Interest` — maintain centroids + affinities from signals; cold-start backfill;
  regenerate a human-readable profile doc (keeps the model inspectable/editable).
- `Librarian.Ranking` — `score(article, model)` blend; pgvector `<=>` prefilter; shortlist selection.
- `Librarian.Discovery` — channels (link_graph, aggregator) → `candidate_sources`; vetting via
  `FeedDiscoverer`; promote/prune by `like_rate`.
- `Librarian.Stream` — user-facing: `list_stream/1`, `record_interaction/3`, `more_like_this/1`,
  `less_like_this/1`, `mute_source/1`, `mute_topic/1`.

## Workers (Oban)

- `EmbedArticlesWorker` — after fetch, embed new articles locally → pgvector.
- `TagAndJudgeWorker` — the reframed `CurateFeedsWorker`: send the shortlist to the host agent,
  get structured tags + judge_score + outbound-link discovery candidates.
- `ScoreStreamWorker` — recompute `article_scores` on model update or new articles.
- `UpdateInterestModelWorker` — fold new signals into centroids/affinities (batched / nightly).
- `DiscoverSourcesWorker` — nightly: link-graph + aggregator → `candidate_sources`.
- `VetCandidateSourceWorker` — per candidate: discover feed, sample recent items, embed, score;
  accept (`origin: discovered, trust: low`) or reject.
- `PruneSourcesWorker` — demote/disable discovered feeds with low `like_rate`.

## Hybrid ranking flow

1. `FetchFeedWorker` (exists) pulls articles.
2. `EmbedArticlesWorker` embeds locally.
3. `ScoreStreamWorker` cheap score per unread candidate:
   `w1·max_cosine(centroids) + w2·affinity(topics,entities) + w3·source_trust + w4·recency − w5·max_cosine(disliked)`.
4. Borderline shortlist (uncertain band / top-N) → `TagAndJudgeWorker` → host Claude agent
   returns tags + `judge_score` + discovery candidates. Cache on the article.
5. Final stream = cheap-confident accepts + judge accepts, **deduped by embedding similarity**
   (kills arXiv cross-posts), plus an **exploration budget** (~15-20% slots) of high-novelty /
   probationary-source items so new interests can surface and the model doesn't collapse into a bubble.

## Signal → model update

- 👍 / save: add embedding to positives; nudge nearest centroid toward it; bump topic/entity/source affinities.
- 👎 / less: add to negatives (powers the disliked-similarity penalty); decay affinities.
- Nightly: recompute centroids (k-means over positives, seeded from the profile docs); recompute `like_rate` per source.

## Cold start (one-off backfill)

Embed all vault notes + starred/saved articles as positives. Embed each profile `.md` as a
seed vector → initial centroids. Assign positives to nearest seed. Working model immediately.

## Phasing (each phase independently useful)

- **P0** ✅ *(done & verified)* — pgvector + Bumblebee wiring; backfill-embed vault & articles → semantic search + "more like this."
  - Added: `pgvector` + `bumblebee`/`nx`/`exla` deps, `Librarian.PostgrexTypes`, `Librarian.Embeddings` (in-BEAM `Nx.Serving`, `all-MiniLM-L6-v2`, 384-dim), `mix librarian.embed_backfill`, `embedding vector(384)` on articles + notes, migration enabling the extension. Serving added to the supervision tree (disabled in test via `:start_embedding_serving`).
  - Dev/test DB moved to host port **5433** (5432 is held by an unrelated `trace-db` container). `docker compose up -d postgres` runs it.
  - **Verified end-to-end:** real MiniLM embeddings stored + read back at 384-dim; cosine query "supervising BEAM processes that crash" correctly ranked an OTP article above a Postgres one. Tests 96/97 (the 1 failure — `cleanup_worker_test` — is a pre-existing 60d-vs-365d cutoff mismatch, unrelated).
  - **Backfill** runs against whatever DB the app points at; the real vault lives in prod, so `mix librarian.embed_backfill` is run there (not via `just deploy`).
- **P1** ✅ — `interactions` event log + 👍/👎 reader UI; `Librarian.Stream` signal capture.
- **P2** ✅ — `Interest` model (k-means clusters from signals + vault embeddings) + `Ranking` (affinity/penalty/recency + exploration) + `ForYouLive` at `/foryou`.
- **P3** ✅ — `Librarian.Tagging` (heuristic topics/content-type; `judge/1` seam for the host agent); topic-lens chips; topic-aware "why". `TagArticlesWorker`.
- **P4** ✅ — `Librarian.Discovery`: link-graph harvest, vetting via `FeedDiscoverer`, like-rate/prune. candidate_sources + feeds.origin/trust_score/like_rate. Discover/Vet/Prune workers.
- **P5** ✅ — aggregator-mining channel (`harvest_aggregators`, HN/Lobsters/Reddit/Slashdot).
- **P6** ✅ — `DashboardLive` at `/dashboard`: signal stats, clusters, source pool, top topics, candidates, regenerated profile (MDEx). `Interest.regenerate_profile_doc`.
- **Demo/review** — `priv/repo/gen_demo_seed.exs` bakes embeddings+centroids into JSON; `Librarian.DemoSeed` seeds on boot (`DEMO_SEED=true`); `docker compose up --build` serves on host **:4100** (serving off + Nx binary backend so no model/EXLA needed at runtime).
- **P6** — refinement, feedback dashboard, profile-doc regeneration.

## Open risks

- pgvector image swap in k8s before anything else.
- Discovery pollution → high vetting threshold + probation + one-tap mute.
- Embedding cost is ~zero locally; LLM judge cost bounded by shortlist size, not feed volume.
- Filter bubble → the exploration budget is not optional.
