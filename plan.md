# The Librarian — Build Plan

Personal replacement for Feedly (RSS reader) + Evernote (note/clip vault).
Runs on Mac mini in k8s. Safari extension for web clipping.

## What It Is

Two subsystems in one Phoenix app:
- **The Reader** — RSS/Atom aggregator + reader (replaces Feedly)
- **The Vault** — Note and clip storage with full-text search (replaces Evernote)

## Tech Stack

- **Elixir / Phoenix** — web app + LiveView UI
- **PostgreSQL** — all data + full-text search via tsvector
- **Oban CE** — background job queue (feed polling, no paid license needed)
- **Local PVC** — file/binary storage (PDFs, HTML snapshots, images, attachments)
  - Mounted at `/data/librarian` in container
  - Mac mini backs this path up to Backblaze B2 automatically
  - No MinIO needed
- **Safari Web Extension** — web clipper (Xcode project, unsigned for personal use)

## Repository Layout

```
the-librarian/
├── lib/                          # Phoenix app
│   ├── librarian/                # Core: feeds, articles, vault, storage
│   └── librarian_web/            # LiveView UI, controllers, router
├── priv/
│   ├── repo/migrations/
│   └── static/
├── safari-extension/             # Xcode project — Safari Web Extension
│   └── TheLibrarian.xcodeproj
│       ├── App/                  # Required macOS wrapper (minimal SwiftUI)
│       └── Extension/
│           ├── manifest.json
│           ├── popup.html/.js    # Clip dialog UI
│           ├── content.js        # DOM access + Readability.js
│           ├── background.js     # Service worker → POSTs to Phoenix
│           └── Readability.js    # Mozilla article extractor
├── k8s/
│   ├── namespace.yaml
│   ├── postgres/                 # StatefulSet, PVC, Secret
│   ├── app/                      # Deployment, Service, ConfigMap, Secret, PVC
│   └── ingress/                  # nginx IngressClass + Ingress
├── feedly.opml                   # Source of truth for initial feed subscriptions
└── Justfile
```

## Database Schema

### Reader

```sql
feeds
  id, title, site_url, feed_url, category,
  etag, last_modified, last_fetched_at, fetch_error,
  inserted_at, updated_at

articles
  id, feed_id, guid, title, url, content, summary,
  author, published_at, fetched_at,
  search_vector tsvector,
  inserted_at

read_states
  article_id, read_at, starred, saved_at
```

### Vault

```sql
notes
  id, title, body, source_url, clip_mode,
  storage_key (pointer to /data file, nullable),
  search_vector tsvector,
  created_at, updated_at

tags
  id, name

note_tags
  note_id, tag_id

notebooks
  id, name

note_notebooks
  note_id, notebook_id
```

## Storage Module

Thin wrapper over local filesystem. Swap to S3/B2 later by changing one module.

```elixir
defmodule Librarian.Storage do
  @base_path Application.compile_env!(:librarian, :storage_path)

  def put(key, data), do: File.write(path(key), data, [:binary])
  def get(key),       do: File.read(path(key))
  def delete(key),    do: File.rm(path(key))
  def url(key),       do: "/vault/files/#{key}"  # served via Phoenix static

  defp path(key), do: Path.join(@base_path, key)
end
```

## Oban Workers

```
FetchFeedWorker       — fetch one feed, parse, upsert articles
ScheduleFeedsWorker   — cron: enqueue FetchFeedWorker for all due feeds
```

Oban CE plugins used:
- `Oban.Plugins.Cron` — drives ScheduleFeedsWorker
- `Oban.Plugins.Lifeline` — rescues orphaned jobs
- `Oban.Plugins.Pruner` — keeps jobs table clean

Feed fetching respects `ETag` / `Last-Modified` headers to avoid redundant downloads.
Handles RSS 2.0, Atom, RSS 1.0 (arxiv uses it).

## Safari Extension — Clip Modes

| Mode | Mechanism |
|------|-----------|
| Selection | `window.getSelection()` in content.js |
| Full Article | Readability.js runs in content.js → clean text |
| Full Page | Serialize DOM to HTML string → store in MinIO |
| PDF | Detect PDF mime/URL → fetch binary → store in /data |
| Screenshot | `canvas` capture of viewport → PNG → store in /data |

All modes capture: `source_url`, `title`, `clipped_at`, `clip_mode`.
Popup UI: mode dropdown, notebook picker, tag input, title field, Save button.

For personal use on own Mac: build in Xcode, enable Safari > Develop > Allow Unsigned Extensions. No paid Apple Developer account needed.

## Evernote Migration

`mix librarian.import_evernote path/to/export.enex`

- Stream-parse `.enex` XML (don't load whole file — can be large)
- Convert ENML → HTML
- Extract base64 attachments → write to `/data/librarian/attachments/`
- Preserve original `created` / `updated` timestamps
- Map notebooks → notebooks, tags → tags
- Report: N notes, M attachments, K errors

## K8s Manifests (Mac Mini)

```
k8s/namespace.yaml              namespace: librarian

k8s/postgres/
  secret.yaml                   POSTGRES_PASSWORD etc.
  statefulset.yaml              postgres:16, PVC 20Gi
  service.yaml                  ClusterIP

k8s/app/
  secret.yaml                   DATABASE_URL, SECRET_KEY_BASE, STORAGE_PATH
  configmap.yaml                PHX_HOST, etc.
  pvc.yaml                      10Gi, ReadWriteOnce (file storage)
  deployment.yaml               the-librarian image, mounts PVC at /data
  service.yaml                  ClusterIP port 4000

k8s/ingress/
  ingress.yaml                  librarian.local (or real domain)
```

Multi-stage Dockerfile:
- Stage 1: `elixir:1.17-otp-27` — mix deps, assets, release
- Stage 2: `debian:bookworm-slim` — copy release binary only

## Justfile

```
# Dev
dev                 iex -S mix phx.server
test                mix test
check               mix compile --warnings-as-errors && mix credo

# Build
build               mix assets.deploy && mix release
docker-build        docker build -t the-librarian:latest .
docker-push         docker tag + push to registry

# K8s
k-apply             kubectl apply -f k8s/
k-migrate           kubectl exec deploy/librarian -- bin/librarian eval "Librarian.Release.migrate()"
k-logs              kubectl logs -f deploy/librarian
k-status            kubectl get pods,pvc,ingress -n librarian
k-restart           kubectl rollout restart deploy/librarian
k-shell             kubectl exec -it deploy/librarian -- bin/librarian remote

# Data
import-opml         mix librarian.import_opml feedly.opml
import-evernote     mix librarian.import_evernote path/to/export.enex
```

## Build Phases

### Phase 1 — Foundation
- `mix phx.new` scaffold
- All schemas + migrations
- `Librarian.Storage` module
- Dockerfile (multi-stage)
- All k8s manifests
- Justfile
- **Done when:** deploys to Mac mini, migrations run, storage path mounts

### Phase 2 — Feed Engine
- OPML parser + `mix librarian.import_opml`
- `FetchFeedWorker` + `ScheduleFeedsWorker` (Oban)
- RSS 2.0 / Atom / RSS 1.0 parser
- ETag / Last-Modified support
- **Done when:** all 80 feeds polled, articles in DB

### Phase 3 — Reader UI
- LiveView: feed list with unread counts, article list, article reader
- Mark read/unread, star, save to vault
- Keyboard shortcuts: j/k navigate, r read, s star, o open original
- Per-feed and per-category "mark all read"
- **Done when:** usable as daily Feedly replacement

### Phase 4 — Vault Core
- Note CRUD LiveView
- Notebook + tag management
- PostgreSQL FTS on notes
- File serving route for `/vault/files/:key`
- **Done when:** can create, tag, search notes manually

### Phase 5 — Safari Extension
- Xcode project scaffold
- Popup UI (mode, notebook, tags, title, save)
- content.js: all 5 clip modes + Readability.js
- background.js: POST to Phoenix `/api/clips`
- Phoenix `ClipController` → creates note + stores file
- **Done when:** clips from Safari like Evernote

### Phase 6 — Evernote Import
- `mix librarian.import_evernote`
- ENML → HTML conversion
- Attachment extraction to /data
- Notebook/tag mapping
- **Done when:** existing Evernote notes all in system

### Phase 7 — Unified Search
- Single search across articles + vault notes
- tsvector indexes on both tables
- Ranked results, filterable by type
- **Done when:** one search box finds everything

### Phase 8 — Polish
- Feed health indicators (last fetch, error count)
- OPML export
- Mobile-friendly layout
- Oban job status view in LiveView
- **Done when:** ready to cancel Feedly + Evernote subscriptions

## Feed Subscriptions (from feedly.opml)

14 categories, ~80 feeds including:
- arxiv CS feeds (PL, AI, DB, DC, CL, IR, DS, etc.)
- Lambda the Ultimate, Papers We Love, Martin Fowler
- Schneier on Security, Krebs on Security
- Planet PostgreSQL, Planet Python
- Lobsters, Hacker News, Slashdot
- Jane Street Blog, Coding Horror, Joel on Software
- Elixir, Erlang, Ruby, Python subreddits
- Google Cloud, Fly.io, Vertex AI release notes
