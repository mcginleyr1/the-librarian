# The Librarian

A self-hosted personal knowledge base combining an RSS feed reader with web clipping and note-taking. Built with Phoenix/Elixir on PostgreSQL.

## Features

- **Google Sign-In** — Ueberauth-based OAuth; email allowlist (self-hosted) or open sign-up with Stripe subscriptions (hosted)
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

**Prerequisites:** Elixir 1.15+, PostgreSQL 16, Node.js

```bash
# Start PostgreSQL
just db-up

# Install deps, create DB, run migrations, build assets
mix setup

# Start dev server
just dev
```

Visit [http://localhost:4000](http://localhost:4000).

### Authentication

All browser routes require signing in with Google (the `/api` clip endpoints used
by the Safari extension authenticate with per-user bearer tokens). Who may sign
in depends on the mode:

- **Self-hosted (default):** only emails on the allowlist may sign in — it
  defaults to `owner@example.com` and is overridden with the comma-separated
  `ALLOWED_EMAILS` env var.
- **Hosted (billing enabled):** anyone may sign in; using the app requires an
  active subscription (see Billing below). Allowlisted emails are the operator
  accounts: comped (no subscription) and admin (Oban dashboard).

Data created by background workers and the clip API is bound to the deployment
owner (the first user).

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
mix test              # Run tests
mix precommit         # Compile, format check, and test (run before committing)
just import-opml FILE.opml
just import-evernote FILE.enex [NOTEBOOK_NAME]
just import-evernote-dir DIR/
```

## Billing (hosted, multi-user mode)

Billing is off by default and everything above describes the self-hosted
experience. Setting `STRIPE_SECRET_KEY` and `STRIPE_PRICE_ID_MONTHLY` switches
the deployment into hosted mode:

- `/` becomes a public landing page with pricing and a Google sign-in CTA
- sign-up is open; unsubscribed users land on `/subscribe` (Stripe Checkout,
  14-day trial) and manage their plan through the Stripe billing portal from
  Settings → Billing
- Stripe webhooks (`POST /webhooks/stripe`) keep subscription state in sync —
  point a webhook endpoint at it with the `checkout.session.completed` and
  `customer.subscription.*` events, and set `STRIPE_WEBHOOK_SECRET`

**Pricing rationale:** the default display prices are $12/month / $96/year.
The two tools this replaces cost more individually (Feedly Pro+ $12.99/mo,
Evernote from $14.99/mo — ~$28/mo combined). The actual amounts charged live
on the Stripe prices; keep `BILLING_MONTHLY_PRICE_USD`/`BILLING_YEARLY_PRICE_USD`
in sync if you change them.

**LLM cost protection:** set `ANTHROPIC_API_KEY` to serve AI features to
subscribers who haven't added their own key. Platform-keyed usage is hard-capped
per user per month by `PLATFORM_LLM_BUDGET_CENTS` (default `500` = $5), so
worst-case LLM spend per subscriber stays well under the fee. Users can add
their own key in Settings → AI to raise their cap at their own expense.

| Variable | Description |
|---|---|
| `STRIPE_SECRET_KEY` | Enables billing (with the monthly price id) |
| `STRIPE_WEBHOOK_SECRET` | Webhook signing secret (`whsec_...`) |
| `STRIPE_PRICE_ID_MONTHLY` | Stripe price id for the monthly plan |
| `STRIPE_PRICE_ID_YEARLY` | Stripe price id for the yearly plan (optional) |
| `BILLING_MONTHLY_PRICE_USD` | Display price, default `12` |
| `BILLING_YEARLY_PRICE_USD` | Display price, default `96` |
| `ANTHROPIC_API_KEY` | Platform LLM key for subscribers without their own |
| `PLATFORM_LLM_BUDGET_CENTS` | Included AI allowance per user/month, default `500` |

## Docker (Full Stack)

```bash
just up   # Builds app + starts postgres, serves on :4000
just db-down
```

The docker-compose `SECRET_KEY_BASE` is for local development only. Generate a real one with `mix phx.gen.secret` for any internet-facing deployment.

## Deployment (Kubernetes)

The app is designed to run on Kubernetes behind Tailscale for TLS termination.

**One-time setup:**

```bash
just k-namespace
just k-create-secrets <db-password> <google-client-id> <google-client-secret>
```

The production Google OAuth client needs
`https://<PHX_HOST>/auth/google/callback` as an authorized redirect URI
(`just oauth-setup` walks the console steps). To rotate or add the Google
credentials on an existing cluster without touching the other secrets:

```bash
just k-set-google-oauth <client-id> <client-secret>
```

**Deploy:**

```bash
just deploy          # Build image, push, apply k8s manifests, run migrations
```

**Other useful commands:**

```bash
just k-logs
just k-status
just k-shell                              # Remote IEx in the running pod
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
| `PHX_HOST` | Public hostname |
| `PHX_SERVER` | Set to `true` |
| `PORT` | Default `4000` |
| `GOOGLE_CLIENT_ID` | Google OAuth 2.0 client ID |
| `GOOGLE_CLIENT_SECRET` | Google OAuth 2.0 client secret |
| `ALLOWED_EMAILS` | Comma-separated allowlist: sign-in gate (self-hosted) or comped admins (hosted) |

Hosted-mode variables (Stripe, platform LLM key) are listed under Billing above.

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

## Browser Extension

The extension is a standard Manifest V3 WebExtension in `safari-extension/extension/`. It reads the configured API endpoint and lets you clip the current page into a notebook. Supports five clip modes:

- **Selection** — highlighted text
- **Full Article** — main content via Readability.js
- **Full Page** — full HTML snapshot
- **Screenshot** — PNG of visible area
- **PDF** — captured PDF

The same folder loads in all three browsers:

- **Safari** — build the Xcode wrapper in `safari-extension/TheLibrarian/` (it references the shared folder), then enable via Safari → Develop → Allow Unsigned Extensions
- **Chrome** — `chrome://extensions` → enable Developer mode → Load unpacked → select `safari-extension/extension/`
- **Orion** — Orion → Settings → Advanced → enable "Allow installation of 3rd party Chrome extensions", then Tools → Extensions → Manage Extensions → Add Extension and pick the same folder (if Orion asks for a packaged file, `chrome --pack-extension=safari-extension/extension` produces a `.crx`)
