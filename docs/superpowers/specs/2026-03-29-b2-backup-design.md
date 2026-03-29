# B2 Backup Design

**Date:** 2026-03-29
**Status:** Approved

## Summary

Daily incremental backup of all vault notes (as Markdown) and their binary attachments (PDFs, screenshots, HTML snapshots) to Backblaze B2 via its S3-compatible API. Credentials are stored in the database and configurable through a new Backup tab in the Settings UI.

---

## Architecture

Four new components, following existing project patterns:

| Component | Purpose |
|---|---|
| `Librarian.Settings` | Ecto schema + context — singleton DB row for B2 credentials |
| `Librarian.Backup` | Core logic: render markdown, HEAD-check B2, upload missing files |
| `Librarian.Workers.BackupWorker` | Oban worker, scheduled via cron at 2am daily |
| New "Backup" tab in `SettingsLive` | Credential form + manual "Back up now" trigger button |

### New dependencies

- `{:ex_aws, "~> 2.5"}` — AWS Signature V4 signing and request execution
- `{:ex_aws_s3, "~> 2.5"}` — S3 API operations (put_object, head_object)
- `{:sweet_xml, "~> 0.7"}` — Required by ex_aws to parse S3 XML responses

Credentials are passed per-request via `ExAws.request(config: ...)` so nothing is stored in `config.exs`.

---

## Data Model

### Migration: `settings` table

Singleton row (always upserted at `id = 1`):

| Column | Type | Notes |
|---|---|---|
| `b2_key_id` | string | Backblaze application key ID |
| `b2_application_key` | string | Backblaze application key secret |
| `b2_bucket_name` | string | Target bucket name |
| `b2_endpoint` | string | Host only, e.g. `s3.us-west-004.backblazeb2.com` |

### `Librarian.Settings` context

- `get_settings/0` — returns the singleton row or `nil`
- `save_settings/1` — upserts `id = 1` with given attrs
- `configured?/0` — true if a row exists with non-nil key fields

---

## Backup Format

### B2 Key Structure

```
vault/
  {Notebook Name}/
    {note-id}-{slugified-title}/
      index.md
      attachment.{ext}    ← only present if the note has a storage_key
```

The note ID prefix ensures uniqueness even if two notes share a title. The notebook name and slugified title are URL-safe (spaces → hyphens, lowercase, non-alphanumeric stripped).

### `index.md` Format

```markdown
---
title: My Note
notebook: Research
tags: [elixir, phoenix]
source_url: https://example.com
clip_mode: full_article
created_at: 2026-01-15T10:30:00Z
---

Note body content here...
```

All frontmatter fields are optional — omitted if nil. The body is the raw `note.body` field (HTML or plain text as stored).

---

## Incremental Logic

For each note returned by `Vault.list_all_notes/0` (called with no limit — a dedicated `Backup.stream_all_notes/0` using `Repo.stream/1` inside a transaction to avoid loading all notes into memory at once):

1. Compute `index_key = "vault/{notebook}/{slug}/index.md"`
2. `HEAD` the key in B2
   - `200` → skip (already backed up)
   - `404` → upload `index.md`
3. If `note.storage_key` is set and the local file exists (`Storage.exists?/1`):
   - Derive extension via `Path.extname(note.storage_key)` (e.g. `".pdf"`, `".png"`)
   - Compute `attachment_key = "vault/{notebook}/{slug}/attachment.{ext}"`
   - `HEAD` the key in B2
     - `200` → skip
     - `404` → read via `Storage.get/1`, upload to B2

Per-note failures (upload errors, missing local files) are logged and skipped — the backup continues. The Oban worker has `max_attempts: 3` for transient failures.

---

## Scheduling

Oban cron added to `config/config.exs`:

```elixir
cron: [{"0 2 * * *", Librarian.Workers.BackupWorker}]
```

Runs at 2am daily. The worker calls `Settings.configured?/0` first — if credentials are not set up, it exits cleanly with `:ok`.

---

## Settings UI

New "Backup" tab added to the existing `SettingsLive` tab bar. Contains:

- Form with four fields: Key ID, Application Key (masked input), Bucket Name, B2 Endpoint
- Save button — upserts credentials via `Settings.save_settings/1`
- "Back up now" button — enqueues `BackupWorker` immediately via `Oban.insert/1`
- Feedback via flash messages (saved, backup queued, errors)

---

## Error Handling

| Scenario | Behavior |
|---|---|
| Credentials not configured | Worker exits `:ok`, no-op |
| B2 auth failure | Worker returns `{:error, reason}`, Oban retries up to 3x |
| Individual note upload fails | Log warning, continue to next note |
| Local attachment file missing | Log warning, skip attachment upload |
| Note body is nil | Render markdown with empty body, still upload |
