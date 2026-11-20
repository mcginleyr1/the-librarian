# Issues & Improvement Backlog

Audit of The Librarian codebase, grouped by category and priority.

---

## 1. Bugs & Correctness

- [ ] **Crash when starring an unread article in Reader** (`lib/librarian_web/live/reader_live.ex:87-97, 122-127`)
  - `select_article` loads the article *before* calling `Reader.mark_read/1`, leaving `selected_article.read_state` as `nil`. Clicking **Star** then runs `put_in(socket.assigns.selected_article.read_state.starred, starred)` on `nil` and crashes the LiveView (unlike keyboard `toggle_star_current/1` at line 359, which guards with `|| %ReadState{}`).
  - **Fix:** Update `selected_article.read_state` on `select_article` (or guard with `|| %ReadState{}` in `toggle_star` as well).

- [ ] **LiveView stream items don't update visual state on select, read, or star** (`lib/librarian_web/live/reader_live.ex:87-97`, `lib/librarian_web/live/reader_live.html.heex:172-209`, `lib/librarian_web/live/vault_live.ex:390-401`, `lib/librarian_web/live/vault_live.html.heex:178-229`)
  - Updating `@selected_article` or `@selected_note` does not re-render items already in `@streams.articles` / `@streams.notes`, so active selection highlights, dimmed read titles, and star badges don't update in the list.
  - **Fix:** Re-insert the previously and newly selected items (with updated `read_state`) via `stream_insert/3`.

- [ ] **Reader unread count & keyboard interaction inconsistencies** (`lib/librarian_web/live/reader_live.ex:87-97, 328-362`)
  - Selecting an already-read article still decrements `unread_counts` by 1.
  - Keyboard shortcuts (`j`/`k` in `navigate_to_index/2` and `s` in `toggle_star_current/1`) don't call `Stream.record_interaction/2` (`:open` / `:save`) like mouse clicks do, so keyboard-heavy reading doesn't train For You.
  - **Fix:** Only decrement `unread_counts` when `is_nil(article.read_state) or is_nil(article.read_state.read_at)`, and share the select/star logic between click and keyboard handlers.

- [ ] **Dropping or pasting 2+ images on Canvas crashes** (`lib/librarian_web/live/canvas_live.ex:224-244`)
  - `allow_upload(:images, max_entries: 5, ...)` allows up to 5 images, but `handle_progress/3` pattern-matches `[page] = consume_uploaded_entries(...)` and passes the same `socket.assigns.page` to each entry. Multiple images crash with `MatchError` (and would overwrite earlier nodes if not threaded sequentially).
  - **Fix:** Thread the updated `page` across all completed entries (or handle a single entry per `consume_uploaded_entry/3` call when `entry.done?`, offsetting each dropped card slightly).

- [ ] **Vault editor loses unsaved fields on Preview and hides validation errors** (`lib/librarian_web/live/vault_live.ex:165-178, 224-226`, `lib/librarian_web/live/vault_live.html.heex:266-313`)
  - `editor_change` only tracks `draft_body` while Title, Source URL, Notebook, and Tags bind directly to `@selected_note.*`, so switching Write ↔ Preview resets unsaved edits to those fields.
  - `@note_changeset` is assigned on errors but never rendered in the template.
  - Moving a note out of the currently selected notebook calls `stream_insert/3` (`lib/librarian_web/live/vault_live.ex:249`), leaving the moved note visible in the old notebook's list.
  - **Fix:** Drive the editor form via `to_form/1` (preserving all draft fields and rendering validation errors), and call `stream_delete/3` when a note is moved out of `@selected_notebook_id`.

- [ ] **Editing a note doesn't refresh its embedding or graph edges** (`lib/librarian/vault.ex:235-243`)
  - `Vault.update_note/3` (and `sync_note/4` updates) never clear `embedding` or `graph_indexed_at` when `title` or `body` changes, leaving semantic search, interest centroids, and LLM graph edges stuck on the note's original text.
  - **Fix:** In `save_note/2`, when `:title` or `:body` changed on the changeset, set `embedding: nil` and `graph_indexed_at: nil`.

- [ ] **`ForYouLive` "Save" doesn't star/save and preview card skips `:open`** (`lib/librarian_web/live/for_you_live.ex:31-41`, `lib/librarian_web/live/for_you_live.html.heex:202-208`)
  - Clicking **Save** logs `:save` and removes the card from For You, but doesn't call `Reader.mark_starred(article_id, true)` or `Reader.mark_read(article_id)`, so the article vanishes from For You without appearing in Reader → Starred.
  - Clicking the link-preview card opens the URL without firing the `open` event that clicking the article title fires.
  - **Fix:** Star (and mark read) on `"save"` feedback, and attach the same `phx-click` `open` handler to the preview card link.

- [ ] **Search note links go to `/vault` instead of the note, and show raw HTML** (`lib/librarian_web/live/search_live.html.heex:48`, `lib/librarian_web/live/search_live.ex:63`)
  - Clicking any note result links to `/vault` instead of `/vault/note/#{result.id}`.
  - `preview: String.slice(n.body || "", 0, 200)` doesn't strip HTML tags for clipped notes.
  - **Fix:** Link notes to `/vault/note/#{result.id}` and strip HTML tags (`HtmlSanitizeEx.strip_tags/1`) before slicing non-markdown note previews.

- [ ] **Topic tagging substring false positives** (`lib/librarian/tagging.ex:16-23, 55-62`)
  - `String.contains?/2` matches without word boundaries: `"rag"` matches *"paragraph"*, *"average"*, *"strategy"*, *"storage"*; `"ecto"` matches *"vector"*, *"sector"*, *"architecture"*; `"beam"` matches *"sunbeam"*, etc.
  - **Fix:** Compile word-boundary regexes (`~r/\b(...)\b/`) per topic as module attributes.

- [ ] **OPML import silently drops top-level uncategorized feeds** (`lib/librarian/release.ex:248-263`)
  - `<outline xmlUrl="..."/>` elements directly under `<body>` hit `_ -> []` in `extract_opml_feeds/1` instead of being imported as uncategorized feeds.
  - **Fix:** Handle top-level `<outline>` entries that have `xmlUrl` by emitting them with `category: nil`.

- [ ] **Backup YAML escaping and non-ASCII slugs** (`lib/librarian/backup.ex:131-141`)
  - `yaml_value/1` only escapes `"`, breaking YAML frontmatter on backslashes (`\`) or newlines (`\n`/`\r`).
  - `slugify/1` returns `""` for purely non-ASCII titles/notebook names, producing keys like `vault//42-/index.md`.
  - **Fix:** Use `Jason.encode!/1` for YAML double-quoted strings, and fall back to `"untitled"` when `slugify/1` trims to `""`.

---

## 2. Multi-Tenancy & Security Tightening

- [ ] **Cross-tenant bug in `Discovery.prune_sources/0`** (`lib/librarian/discovery.ex:256-268`)
  - The correlated SQL `fragment` counts `'open'` interactions for `a.feed_id` without `AND i.user_id = s.user_id`. Because `Repo.prepare_query` cannot inspect SQL fragments, one user's reads count toward pruning another user's discovered subscription.
  - **Fix:** Add `AND i.user_id = ?` passing `s.user_id` inside the fragment.

- [ ] **Single-user Settings actions enqueue jobs for ALL tenants** (`lib/librarian_web/live/settings_live.ex:370-391, 448-454`)
  - `run_backup`, `dedupe_notes`, and `build_graph_now` enqueue `BackupWorker` and `BuildGraphWorker` with empty args `%{}` instead of `%{"user_id" => Repo.user_id!()}`, triggering `Accounts.enqueue_per_user/1` for every user (running other users' backups and LLM graph builds).
  - **Fix:** Pass `%{"user_id" => Repo.user_id!()}` to `BackupWorker.new/1` and `BuildGraphWorker.new/1`.

- [ ] **Unscoped queries on the shared article catalog** (`lib/librarian/reader.ex:376-389`, `lib/librarian/interest.ex:67-72`)
  - `Reader.mark_all_read_for_feed/1` queries `Article` instead of `visible_articles()`, allowing a user to write `read_states` for feeds they aren't subscribed to.
  - `Interest.topic_frequencies/0` aggregates topics across all articles in the shared catalog rather than the user's visible/subscribed articles.
  - **Fix:** Scope `mark_all_read_for_feed/1` through `visible_articles()` (or verify subscription), and scope `topic_frequencies/0` to the user's active subscriptions (using `unnest(topics)` + `GROUP BY` in Postgres).

- [ ] **Allowlist removal doesn't revoke active sessions or API tokens** (`lib/librarian_web/user_auth.ex:32-58, 91-105`)
  - `require_admin` re-checks `Accounts.allowed_email?/1`, but `fetch_current_user`, `on_mount(:ensure_authenticated)`, and `require_api_token` do not. Removing an email from `ALLOWED_EMAILS` leaves existing sessions and bearer tokens active.
  - **Fix:** Decide whether allowlist revocation should be immediate; if so, check `Accounts.allowed_email?(user.email)` in `fetch_current_user`, `on_mount`, and `require_api_token`.

- [ ] **Plaintext secrets at rest in Postgres** (`lib/librarian/accounts/user.ex:11`, `lib/librarian/accounts.ex:35-47`, `lib/librarian/settings.ex:9, 15`)
  - `users.api_token`, `settings.b2_application_key`, and `settings.anthropic_api_key` are stored in plaintext, exposing active tokens/keys in DB dumps or backups.
  - **Fix:** Store a SHA-256 hash of `api_token` (show raw token only on creation/regeneration) and encrypt `b2_application_key` / `anthropic_api_key` at rest (e.g., AES-GCM via `Plug.Crypto` or Cloak with an env key).

- [ ] **Follow-up defense-in-depth hardening**
  - `lib/librarian/backup.ex:202`: pass `redirect: false` to `Req.put/2` so a custom `b2_endpoint` cannot redirect to an internal address after `SafeHTTP.check_url/1`.
  - `lib/librarian_web/live/settings_live.ex:79`, `lib/librarian_web/live/reader_live.ex:182`, `lib/librarian_web/live/search_live.ex:25`: replace `String.to_existing_atom/1` on user/URL params with an explicit whitelist map so invalid params don't crash LiveViews.
  - `lib/librarian_web/live/settings_live.ex:354-368`: filter `save_backup` params with `Map.take/2` (just the B2 fields) instead of passing raw params to `Settings.save_settings/1`.
  - `lib/librarian_web/controllers/clip_controller.ex:43-52`: return `422` when a binary `clip_mode` receives invalid base64 instead of silently storing the raw string in `body`.
  - `lib/librarian_web/mcp_tools.ex:350-358`: reject whitespace-only `category` strings in `follow_sites`.
  - `lib/librarian/link_preview.ex:71-77`: reject non-`http(s)` schemes (e.g. `javascript:`) in `resolve/2` when `URI.parse(url).scheme` is non-nil.

---

## 3. Storage & Background Worker Reliability

- [ ] **Deleted notes leak stored files on disk** (`lib/librarian/vault.ex:223, 250-269`, `lib/librarian/canvas.ex:277-290`)
  - `Vault.delete_note/1`, `Vault.delete_notes/1`, and `Vault.dedupe_notes/0` delete DB rows without removing `storage_key` files from `STORAGE_PATH`.
  - `Canvas.attach_image/3` writes to `Storage` before `Vault.create_note/1` and never cleans up the file if `create_note/1` or `save_doc/2` fails.
  - **Fix:** Delete associated `storage_key` files after DB deletion (and on failure in `attach_image/3`), or add an orphan-file sweep to `CleanupWorker`.

- [ ] **`CleanupWorker` is never scheduled in Oban cron** (`config/config.exs:83-92`, `lib/librarian/workers/cleanup_worker.ex`)
  - `CleanupWorker` is implemented and tested but omitted from `Oban.Plugins.Cron`, so stale read articles are never garbage-collected.
  - **Fix:** Add a daily/weekly entry for `Librarian.Workers.CleanupWorker` to `crontab`.

- [ ] **Unsupervised `Task.start` in `SettingsLive` can leak `/tmp` files and freeze UI** (`lib/librarian_web/live/settings_live.ex:130-136, 158-162`)
  - If an ENEX import (up to 500 MB) crashes, `File.rm(path)` is never executed and `importing_enex: true` stays stuck forever. Same stuck-spinner issue for `discover_feed`.
  - **Fix:** Use `start_async`/`handle_async` and wrap `File.rm(path)` in `try ... after`.

- [ ] **Oban worker reliability gaps**
  - `lib/librarian/workers/embed_articles_worker.ex:65-67`: `{:error, _reason}` is swallowed and `:ok` is returned silently instead of logging and returning `{:error, reason}` to retry when the embedding serving is down.
  - `lib/librarian/workers/extract_edges_worker.ex:80`: `Vault.upsert_edges(entries)` uses default conflict replacement, which can overwrite `origin` on existing `"user"`, `"wikilink"`, or `"canvas"` edges. Pass `on_conflict: :nothing` (or only update when `origin = 'llm'`).
  - `lib/librarian/reader.ex:588-591` & `fetch_feed_worker.ex`: `Repo.get!(Feed, feed_id)` raises `Ecto.NoResultsError` and retries 3 times if a feed is deleted while queued. Return `{:cancel, :feed_deleted}` when `Repo.get/2` is `nil`.
  - `lib/librarian/workers/vet_candidate_source_worker.ex:3`: add `unique: [keys: [:id], period: 3600]` and guard on `candidate.status == "pending"` to prevent duplicate concurrent vetting jobs.
  - `lib/librarian/llm.ex:104-108`: pass `retry: false` (or `max_retries: 1`) to `Req.post/2` so 5-minute timeouts don't multiply with Req's default 3 retries on top of Oban retries.
  - `lib/librarian/reader.ex:165-175`: `upsert_catalog_feed/1` has a check-then-insert race on `feeds.feed_url` when two subscribers or vet jobs add the same feed simultaneously.

---

## 4. Performance & Database Scaling

- [ ] **Batch embeddings to fill EXLA `batch_size: 16`** (`lib/librarian/workers/embed_articles_worker.ex:51-69`, `lib/librarian/embeddings.ex:35`)
  - `Nx.Serving` is compiled for `batch_size: 16`, but `EmbedArticlesWorker` embeds rows sequentially one by one, paying full 16-item padding cost on every single item.
  - **Fix:** Pass chunks of 16 to `Nx.Serving.batched_run/2` (or run concurrent `Task.async_stream/3` with `max_concurrency: 16`).

- [ ] **Avoid detoasting multi-MB bodies in `neighbor_candidates/2` and `prepare_for_stream/1`** (`lib/librarian/vault.ex:591-598`, `lib/librarian/release.ex:96-110`)
  - Both fetch full `Note`/`Article` structs (including multi-MB TOASTed bodies) just to slice the first 500 or 8,000 characters.
  - **Fix:** Truncate in SQL with `fragment("left(?, ?)", n.body, ^limit)` like `EmbedArticlesWorker` already does.

- [ ] **Canvas re-renders and queries every card on every interaction** (`lib/librarian_web/live/canvas_live.ex:269-273`, `lib/librarian_web/live/canvas_live.html.heex:208, 260`, `assets/js/canvas.js:157`)
  - Calling `text_html/1` and `note_html/1` inside the template runs `Vault.wikilink_targets/1` DB queries + MDEx/HTML sanitization for *every* card on every move, resize, or keystroke.
  - `assets/js/canvas.js:157` writes `localStorage.setItem` on every single trackpad `wheel` tick.
  - **Fix:** Cache rendered HTML per node/note in assigns (updating only changed nodes), and debounce `saveView()` in `canvas.js`.

- [ ] **Missing database indexes** (`priv/repo/migrations/`)
  - **pgvector HNSW index on `notes(embedding)`** (`USING hnsw (embedding vector_cosine_ops)`) — without it, hourly `Vault.generate_similarity_edges/1` and `neighbor_candidates/2` do $O(N^2)$ sequential vector scans.
  - `notes([:user_id, :storage_key])` — queried on every `/vault/files/*` request.
  - `notes([:user_id, :updated_at])` and `notes([:user_id, :inserted_at])` — used by `list_notes`, `Backup.backup_notes`, `Interest.note_embeddings`, and `BuildGraphWorker`.
  - `interactions([:user_id, :article_id, :kind])` and `interactions([:user_id, :occurred_at])` — used by `Ranking.@scored_sql`, `Stream.recent_reading`, and `Discovery.prune_sources`.

- [ ] **N+1 queries & unnecessary DB writes**
  - `lib/librarian/vault.ex:692-707`: `find_or_create_tags/1` runs 2N queries per note save/import. Replace with one `Repo.insert_all/3` (`on_conflict: :nothing`) + one `Repo.all/1`.
  - `lib/librarian/discovery.ex:241-249`: `recompute_like_rates/0` runs N `feed_signal_stats` queries + N updates. Fetch all stats in one `GROUP BY a.feed_id, i.kind` query.
  - `lib/librarian/reader/feed_fetcher.ex:96-112`: `upsert_articles/3` individually rewrites every existing article row on every fetch for feeds without ETag. Batch inserts or skip unchanged rows.
  - `lib/librarian/reader/feed_parser.ex:38-39`: RSS `<description>` has HTML stripped even when `<content:encoded>` is absent, so description-only RSS feeds lose links, images, and formatting.
  - `lib/librarian_web/live/settings_live.ex:23-44`: `Settings.get_settings/0` is called 5 times during a single mount.
  - `lib/librarian_web/live/dashboard_live.ex:17-27`: `Interest.topic_frequencies/0` is run twice per mount (and both `ForYouLive` and `DashboardLive` execute heavy ranking/parsing queries on both dead and connected renders).

- [ ] **Stream stored files instead of loading into BEAM memory** (`lib/librarian_web/controllers/vault_files_controller.ex:17-24`, `lib/librarian_web/controllers/note_api_controller.ex:58-62`)
  - Both controllers read entire files via `File.read/1` into binary heap memory before calling `send_resp/3`.
  - `VaultFilesController` also omits the 3rd `nil` argument to `put_resp_content_type/3`, appending `; charset=utf-8` to PDFs and images, and `NoteApiController.file/2` doesn't set `x-content-type-options: nosniff`.
  - **Fix:** Expose a validated `Storage.path!/1` and stream with `Plug.Conn.send_file(conn, 200, path)`.

- [ ] **`SafeHTTP` binary accumulation & per-hop deadline** (`lib/librarian/safe_http.ex:24-59`)
  - `resp.body <> data` inside a map update can degrade to $O(n^2)$ copying on multi-MB responses; accumulating an iolist + byte counter is guaranteed $O(n)$.
  - `deadline` is computed inside `request/2` (per redirect hop) rather than once in `get/2` across the full redirect chain.

- [ ] **Cap negative/weak-positive history in Ranking & Interest** (`lib/librarian/ranking.ex:45-50`, `lib/librarian/interest.ex:115-119`)
  - `Ranking.@scored_sql`'s `neg` CTE cross-joins `pool` against *every* disliked article ever, and `Interest.positive_embeddings/0` loads *all* `open`/`done` article embeddings with no cap (unlike `@vault_cap 300`). Adding a recency cap (e.g. most recent 200–500) keeps both bounded over years of use.

---

## 5. UI Polish, Ops & Housekeeping

- [ ] **Remove leftover Phoenix generator chrome**
  - `lib/librarian_web/components/layouts.ex:36-73`: `Layouts.app/1` still renders the Phoenix logo, version, and `phoenixframework.org` links — used by **Settings** (`settings_live.html.heex:1`) and **Search** (`search_live.html.heex:1`), and forces `max-w-2xl` around Settings' `max-w-4xl`.
  - `lib/librarian_web/components/layouts/root.html.heex:7`: still has `suffix=" · Phoenix Framework"`.
  - `lib/librarian_web/components/layouts.ex:149-168`: `Layouts.reader/1` and `Layouts.vault/1` are identical duplicates.
  - Several internal links in `reader_live.html.heex:104-112`, `vault_live.html.heex:97`, `settings_live.html.heex:5-10`, and `search_live.html.heex:4` use `<a href="...">` instead of `<.link navigate="...">`, causing full page reloads.

- [ ] **Dedicated `/health` endpoint for Kubernetes probes** (`k8s/app.yaml:132-147`, `config/prod.exs:16-20`)
  - Probes currently hit `/` (which runs `:browser` / `force_ssl` and redirects). Add a lightweight `/health` route excluded from `force_ssl` (with a `SELECT 1` DB check for readiness).

- [ ] **Review clip payload limit for PDFs and `/tmp` sizeLimit** (`lib/librarian_web/endpoint.ex:42-45`, `k8s/app.yaml:154-155`)
  - Default `Plug.Parsers` `length` is 8 MB, capping base64-encoded PDF/full-page clips from the browser extension at ~5.8 MB raw.
  - Add a `sizeLimit` (e.g. `1Gi`) to the `tmp` `emptyDir` volume in `k8s/app.yaml`.

- [ ] **Clean up unused files**
  - Delete unused `assets/vendor/d3-force.js` (only `d3-hierarchy.js` is imported).
  - Remove the leftover 7.8 MB `erl_crash.dump` in the repository root (and ensure `erl_crash.dump` is in `.gitignore`).
