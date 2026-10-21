# The Librarian

A free and open-source, self-hosted personal knowledge base combining an RSS feed reader with web clipping and note-taking. Built with Phoenix/Elixir on PostgreSQL.

![The Librarian reader: categorized feeds, unread article list, and reading pane](docs/images/reader.jpg)

> **Private networks only.** The Librarian is built for a home lab or other
> closed network, not the open internet. Reach it over
> [Tailscale](https://tailscale.com) (recommended: the `k8s/` manifests expose
> it only on your tailnet through a Tailscale ingress with Funnel off) or
> another VPN. Don't port-forward it or put it behind a public proxy. Google
> sign-in and the email allowlist are a second layer of protection, not a
> replacement for keeping it off the internet.

## Features

- **Google Sign-In** — Ueberauth-based OAuth restricted to an email allowlist; each allowlisted person gets their own isolated vault and feeds
- **RSS Reader** — Subscribe to feeds, organize by category, track read/starred state, keyboard navigation
- **Note Vault** — Capture web clips, create markdown notes, organize into notebooks with tags
- **Wiki-Links & Knowledge Graph** — `[[Note Title]]` links with editor autocomplete, AI-typed connections between related notes, unlinked-mention detection, and a mind-map graph view
- **Canvas Pages** — OneNote-style infinite pages: click anywhere to type, drop vault notes on as cards, embed clipped PDFs and web pages, and draw arrows between cards that become knowledge-graph edges (stored as [JSON Canvas](https://jsoncanvas.org))
- **Quick Switcher** — `⌘K` jump-to-note by title from anywhere in the vault
- **Full-Text Search** — PostgreSQL-backed search across all articles and notes
- **Browser Extension** — One-click clipping in five modes (selection, full article, full page, screenshot, PDF); works in Safari, Chrome, and Orion
- **Import** — Migrate from Evernote (ENEX) and import OPML feed subscriptions

## Tech Stack

- [Phoenix](https://www.phoenixframework.org/) 1.8 + LiveView
- PostgreSQL 16 (with full-text search via `tsvector`)
- [Oban](https://github.com/sorentwo/oban) for background feed fetching
- Tailwind CSS v4
- Kubernetes + Docker for deployment

## Local Development

**Prerequisites:** Elixir 1.20+, PostgreSQL 16 with pgvector, Node.js

```bash
# Start PostgreSQL
just db-up

# Install deps, create DB, run migrations, build assets
mix setup

# Who may sign in (comma-separated)
export ALLOWED_EMAILS=you@example.com

# Start dev server
just dev
```

Visit [http://localhost:4000](http://localhost:4000).

### Authentication

All browser routes require signing in with Google (the `/api` endpoints
authenticate with per-user bearer tokens instead — see [API](#api)). Only
emails on the `ALLOWED_EMAILS` allowlist may sign in, and only when Google
reports the address as verified. There is no built-in allowlist: with it unset
nobody can sign in, and production refuses to boot without it. Allowlisted
users are also admins (the Oban dashboard at `/oban`).

Every allowlisted person gets their own vault, feeds and settings; the feed
catalog itself is shared, so a feed two people follow is fetched once. API
requests act as the user whose bearer token they carry, and background workers
run as one job per user. Only the CLI and release tasks — imports
(`mix librarian.import_*`, `just import-*`, `just k-import-*`),
`just k-dedupe-notes`, and `Librarian.Release.prepare_for_stream/1` — act on
the deployment owner's vault: the first user to sign in.

Creating the OAuth client is a one-time manual step — Google exposes no API or
gcloud command for standard OAuth 2.0 web clients. `just oauth-setup` walks it:
it prints the exact consent-screen/client values (including both redirect URIs)
and opens the console. Then:

```bash
export GOOGLE_CLIENT_ID=...
export GOOGLE_CLIENT_SECRET=...
just dev
```

**Useful commands:**

```bash
mix test              # Run tests (seeds an owner@example.com user in the test DB)
mix precommit         # Compile, format, credo, and test (run before committing)
just import-opml FILE.opml
just import-evernote FILE.enex [NOTEBOOK_NAME]
just import-evernote-dir DIR/
```

## API

JSON endpoints under `/api` authenticate with the per-user bearer token from
Settings → API Access (`Authorization: Bearer <token>`) and act as that
token's user: every read and write is scoped to their vault, so another user's
note looks exactly like a missing one. A missing or unknown token gets `401
{"error":"unauthorized"}`.

| Endpoint | Purpose |
|---|---|
| `POST /api/clips` | Clip a page into the vault (browser extension) |
| `GET /api/notebooks` | List notebooks: `[{"id", "name"}]` |
| `GET /api/notes?q=&limit=` | Search or list notes (editor clients) |
| `GET /api/notes/:id` | Read one note with its body and connections |
| `PUT /api/notes/external/:external_id` | Upsert a note by the client's stable id |

### Notes API (editor sync)

Lets an editor client — e.g. an Emacs org-roam package — search, read, and
two-way sync vault notes. Errors are `404 {"error":"not_found"}`,
`409 {"error":"external_id_conflict"}`, and
`422 {"status":"error","errors":{"<field>":["<message>"]}}` (also for a
non-list `tags` or a `notebook_id` that isn't one of your notebooks).

Notes are listed as summaries:

```json
{"id": 42, "title": "Raft", "external_id": "5b9e…", "notebook": {"id": 3, "name": "Roam"},
 "tags": ["distsys"], "clip_mode": "markdown", "source_url": null,
 "updated_at": "2026-10-02T12:00:00Z"}
```

`external_id` is `null` for notes never synced, and `notebook` is `null` for
unfiled notes.

**`GET /api/notes?q=<text>&limit=<n>`** → `{"notes": [summary]}`. With a
non-blank `q`, title-substring matches come first, then full-text matches,
de-duplicated; without one, the most recently updated notes. `limit` defaults
to 50, max 200.

```bash
curl -H "Authorization: Bearer $TOKEN" "https://$HOST/api/notes?q=raft&limit=20"
```

**`GET /api/notes/:id`** → `{"note": summary + {"body", "body_format",
"related"}}`. `body_format` is `"markdown"` for markdown notes and `"html"` for
clips; `related` lists connected notes as `{"id", "title", "kind",
"direction"}` with `direction` `"outgoing"` or `"incoming"`.

```bash
curl -H "Authorization: Bearer $TOKEN" "https://$HOST/api/notes/42"
```

**`PUT /api/notes/external/:external_id`** upserts a markdown note keyed by
the client's stable id (e.g. an org-roam node UUID). Body: `title`
(required), `body`, `tags` (when present, replaces the note's tags),
`notebook_id` (must be one of the user's notebooks), `source_url`, and `id`.
A note already synced under `external_id` is updated; otherwise `id` adopts
an existing, never-synced note (`409` if it is synced under a different id,
`404` if unknown); otherwise a new note is created. Saves rebuild the note's
`[[wiki-link]]` edges just like editing in the app. Returns
`{"status":"ok","id":42,"created":true}`.

```bash
curl -X PUT -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"title":"Raft","body":"See [[Paxos]]","tags":["distsys"]}' \
  "https://$HOST/api/notes/external/5b9e1c7a-0d1f-4c33-9a57-2f0f3e1b8d11"
```

## AI Features

Knowledge-graph edge typing and source discovery call the Anthropic API. Each
user can add their own key in Settings → AI, with their own monthly budget.
Alternatively the operator can set `ANTHROPIC_API_KEY` to serve users who
haven't added one; that shared usage is hard-capped per user per month by
`PLATFORM_LLM_BUDGET_CENTS` (default `500` = $5).

| Variable | Description |
|---|---|
| `ANTHROPIC_API_KEY` | Shared key for users without their own (optional) |
| `PLATFORM_LLM_BUDGET_CENTS` | Per-user monthly cap on the shared key, default `500` |

## Security

- **Third-party HTML is sanitized on render.** Feed articles and clipped or
  imported notes pass through `HtmlSanitizeEx`'s HTML5 scrubber, links to
  articles/sources only render as `http(s)`, and every page carries a
  Content-Security-Policy (scripts only from this origin or with a per-request
  nonce) as a backstop.
- **Stored files are sandboxed.** Files under `/vault/files` are served only to
  the owner of a note that references them, under `Content-Security-Policy:
  sandbox` (PDFs excepted, which browsers won't render sandboxed). Storage keys
  are random and per user; keys resolving outside `STORAGE_PATH` are refused.
- **Outbound fetches can't reach internal networks.** Feed fetching, feed
  discovery and backup endpoints refuse non-`http(s)` URLs and hosts resolving
  to loopback, private, link-local or CGNAT/Tailscale addresses (re-checked on
  every redirect), cap response size and time, and never auto-decode bodies.
  Pair it with an egress NetworkPolicy (see `k8s/`) to also cover DNS rebinding.
- **Tenancy is enforced in the Repo.** Queries on user-owned tables are scoped
  to the current user automatically; references to another user's notes,
  notebooks or articles are rejected.

## Docker (Full Stack)

```bash
export SECRET_KEY_BASE=$(mix phx.gen.secret) ALLOWED_EMAILS=you@example.com
just up   # Builds app + starts postgres, serves on http://localhost:4100
just db-down
```

Nothing secret is committed: `just up` refuses to start until `SECRET_KEY_BASE`
and `ALLOWED_EMAILS` are exported. The compose Postgres listens on
`127.0.0.1:5433` only.

The image runs as `nobody` with the release files root-owned and read-only; the
app writes only to `/data` (`STORAGE_PATH` and the Bumblebee model cache,
`BUMBLEBEE_CACHE_DIR=/data/bumblebee`) and `/tmp` (`RELEASE_TMP`, crash dumps).

## Deployment (Kubernetes)

The app is designed to run on Kubernetes behind Tailscale for TLS termination.
The Justfile defaults point at the author's cluster; override them with
`LIBRARIAN_REGISTRY` (image registry) and `LIBRARIAN_KUBE_CONTEXT`.

**First deploy:**

```bash
just k-namespace
just k-create-secrets   # reads LIBRARIAN_DB_PASSWORD, GOOGLE_CLIENT_ID, GOOGLE_CLIENT_SECRET (prompts for any unset)
just docker-push
just k-apply            # applies manifests with the image pinned to a tag
```

Secrets never go on the command line. Re-running `k-create-secrets` keeps the
existing `secret-key-base`, so sessions survive.

The production Google OAuth client needs
`https://<PHX_HOST>/auth/google/callback` as an authorized redirect URI
(`just oauth-setup` walks the console steps). To rotate or add the Google
credentials on an existing cluster without touching the other secrets:

```bash
just k-set-google-oauth   # same env vars or prompts, then restarts the app
```

**Deploy:**

```bash
just deploy [TAG]    # Build, push, set the image on the app + migrate containers, wait for rollout
```

The tag defaults to the jj commit id (else git HEAD on a clean tree, else a UTC
timestamp); `:latest` is never pushed. `deploy` doesn't apply manifests — after
changing anything in `k8s/`, run `just k-apply`, which keeps the running tag.
Don't `kubectl apply -k k8s/` directly: the manifests carry no tag. Migrations
run in the init container.

The manifests run both pods non-root with dropped capabilities (the app with a
read-only root filesystem), use a `Recreate` strategy (single replica, RWO
volume, Oban cron), and ship a default-deny `NetworkPolicy`: Tailscale → app,
app → Postgres, DNS, and app → public internet on 80/443 only. NetworkPolicy is
enforced only if the cluster's CNI supports it.

**Other useful commands:**

```bash
just k-logs
just k-status
just k-shell                              # Remote IEx in the running pod
just k-restart                            # Restart on the current image
just k-teardown                           # Deletes the namespace and its volumes (asks first)
just k-import-opml FILE.opml
just k-import-evernote FILE.enex [NAME]
just k-import-evernote-dir DIR/
```

**Required environment variables in production:**

| Variable | Description |
|---|---|
| `DATABASE_URL` | `ecto://user:pass@host/db` |
| `SECRET_KEY_BASE` | Generate with `mix phx.gen.secret` |
| `STORAGE_PATH` | Filesystem path for attachments/clips |
| `PHX_HOST` | Required. Hostname the app is reached at (e.g. its tailnet name) |
| `PHX_SERVER` | Set to `true` |
| `PORT` | Default `4000` |
| `GOOGLE_CLIENT_ID` | Google OAuth 2.0 client ID |
| `GOOGLE_CLIENT_SECRET` | Google OAuth 2.0 client secret |
| `ALLOWED_EMAILS` | Required. Comma-separated sign-in allowlist (allowlisted users are admins) |

`PHX_HOST` and `ALLOWED_EMAILS` are required: the release refuses to boot
without them. TLS is expected to terminate at a proxy (Tailscale here) that
sets `X-Forwarded-Proto`; `force_ssl` is compiled in and redirects anything
that arrives as plain HTTP. Optional AI variables are listed under
[AI Features](#ai-features).

## Importing Data

### OPML (Feed Subscriptions)

Standard OPML export from any RSS reader (Feedly, NewsBlur, etc.). Categories are preserved. Idempotent — safe to re-run.

```bash
mix librarian.import_opml path/to/feeds.opml
```

### Evernote (ENEX)

Full fidelity import: notes, tags, timestamps, source URLs, and attachments. Uses a streaming parser for large exports. Idempotent via `evernote_guid`.

```bash
mix librarian.import_evernote path/to/export.enex "Notebook Name"
```

## Canvas Pages

`/canvas` holds OneNote-style pages for composing ideas out of vault notes.

- **Compose** on any vault note starts a page rooted at that note; **New page** starts blank.
- Click anywhere to type. Blank cards disappear on blur; **Save as note** turns a text card into a markdown note in the vault. `[[` autocompletes wiki-links inside a card.
- Drag a card's top edge to move it, the right edge to resize it, and a side dot onto another card to draw an arrow. Double-click an arrow to give it a kind (`extends`, `contradicts`, ...) or a free label. Arrows between two note cards land in `note_edges` with origin `canvas`, so they show up under a note's connections and on the knowledge map.
- The drawer (document icon, top right) searches the vault; click a result to drop it at the centre or drag it onto the page. Pasting or dropping an image stores it as an `image` note; pasting a `/vault/note/:id` URL adds that note; any other URL becomes a link card. PDF and full-page clips render inline in a (sandboxed) iframe.
- Pages are stored as [JSON Canvas](https://jsoncanvas.org) documents and backed up to B2 as `vault/canvas/<id>-<slug>.canvas`, with note cards pointing at the notes' markdown in the same backup, so a backup opens directly in Obsidian.

## Browser Extension

The extension is a standard Manifest V3 WebExtension in `safari-extension/extension/`. It reads the configured API endpoint and lets you clip the current page into a notebook. The API URL must be `https://` (plain `http://` only for `localhost`/`127.0.0.1`); the extension refuses to send your API token anywhere else. Clipped HTML is sanitized when displayed, and full-page snapshots are served sandboxed. Supports five clip modes:

- **Selection** — highlighted text
- **Full Article** — main content via Readability.js
- **Full Page** — full HTML snapshot
- **Screenshot** — PNG of visible area
- **PDF** — captured PDF

The same folder loads in all three browsers:

- **Safari** — build the Xcode wrapper in `safari-extension/TheLibrarian/` (it references the shared folder), then enable via Safari → Develop → Allow Unsigned Extensions
- **Chrome** — `chrome://extensions` → enable Developer mode → Load unpacked → select `safari-extension/extension/`
- **Orion** — Orion → Settings → Advanced → enable "Allow installation of 3rd party Chrome extensions", then Tools → Extensions → Manage Extensions → Add Extension and pick the same folder (if Orion asks for a packaged file, `chrome --pack-extension=safari-extension/extension` produces a `.crx`)

## Contributing

PRs are welcome: bug fixes, features, docs. Run `mix precommit` before
opening one. This is a personal project maintained in spare time, so reviews
may be slow and not every feature will be merged.

## License

[MIT](LICENSE). Use at your own risk: the software is provided as is, without
warranty of any kind, and the authors aren't liable for anything that happens
from using it, including lost notes or an instance exposed to the internet.
Back up your data (Settings → Backup).
