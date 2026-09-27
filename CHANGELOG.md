# Changelog

## 0.5.0

Sync protocol v2 (DEV-1151). Hard cut: v1 clients are refused at socket connect.

### Added

- `sync:v2` channel with a protocol version check at join (`update_required`).
- Per-scope change feed: `get_changes_since`, `get_snapshot`, `change` pushes with `seq`/`prev_seq`. Scopes are `own` and `collection:<name>`.
- `upload` (create/update/delete), deduplicated on `(upload_id, base_hash)`.
- `get_document`; a deleted document replies `deleted` with `current_seq`.
- Publications (read-only, changed only by `publish`, `publish_update`, `unpublish`) and collections. `collection:curated` is replicated to every user.
- 90-day retention of change events and stored upload replies; older cursors get `cursor_too_old`.

### Changed

- Creating a document never deduplicates by content hash.
- The sender now receives its own changes.
- Canonical hashing escapes control characters as lowercase `\u00xx` (serde_json). Shared fixture: `test/fixtures/content_hash_fixture.json`.
- `create_public_document` creates an authorless publication in curated; `delete_public_document` unpublishes it. `create_document/2`, `update_document/4` and `delete_document/2` no longer take options.

### Removed

- v1 channel events (`create_document`, `update_document`, `delete_document`, `request_full_sync`, v1 `get_changes_since`, `transform_operations`), the `sync:user:*` and `sync:public` topics, and the OT modules.

### Protocol summary

Protocol version is checked at socket connect (wrong or missing version → HTTP 426, `update_required`). HMAC auth happens at the `sync:v2` join. Change events and stored upload replies retain for 90 days; a cursor older than the `trim_watermark` gets `cursor_too_old`.

### Host (entonal-web-app) follow-ups

- Mount the websocket error handler so old/wrong-version clients get HTTP 426 with a JSON `update_required` body instead of a raw socket failure:

  ```elixir
  socket "/socket", ReplicantServer.Sync.Socket,
    websocket: [error_handler: {ReplicantServer.Sync.Socket, :handle_error, []}]
  ```

- Set `config :replicant_server, :retention, enabled: false` in the host's `config/test.exs` (F9).
- Public-document views must read `author_id`, not `user_id`.
- `create_public_document` now creates a curated publication: it no longer dedups by content hash, and returns `{:error, :insert_failed}` on failure.
- `delete_public_document` returns `{:error, :not_found}` for a document that is not published.
- Owners' lists no longer show public documents — the migration makes no private copies, so a published document leaves the owner's list.

### Deploy

Migrations run on host boot. They convert every public document into a publication in place: an owned document keeps its id, its owner becomes `author_id`, and no private source copy is made (it leaves the owner's list). All publications are seeded into curated, and every document gets a seq and a recomputed hash. The migrations cannot be rolled back. Release with the v2 client and Entonal build. The host app must read `author_id` for publications.

#### Release checklist (hard cut — ships with the v2 Rust client and Entonal build)

1. Take a DB backup. The migrations cannot be rolled back.
2. Dry-run both migrations against a `pg_dump` of production. Compare document counts, publications, curated membership, and hashes against the pre-migration data. Also report `SELECT count(*) FROM documents WHERE jsonb_typeof(content) <> 'object'` — these rows will be quarantined by the migration.
3. Stop v1 writers before migrating. Use a maintenance window, not a rolling boot: a v1 write that lands after the seq assignment step keeps that row's seq at 0 forever.
4. Tag `v0.5.0`, bump the web app's dependency tag and `mix.lock`, deploy.

## 0.4.5

Sync-base verification (DEV-1037).

### Added

- `get_document` channel op, so a client that detects a revision gap can resync
  one document instead of requesting a full sync. It falls back to public
  documents when the requested id is not owned by the caller.

### Fixed

- `update_document` rejects a nil `content_hash` rather than accepting an
  unverifiable write.
- `compute_hash` canonicalizes float formatting and key ordering for maps with
  more than 32 keys, so server and client hashes agree.

### Note

`mix.exs` previously carried `0.1.0` and was never bumped; releases were tracked
by git tag alone. It now matches the release version.

### Deploy

This version must not reach production until the client 0.5.0 pin ships in an
Entonal release. Its nil-hash rejection breaks updates from 0.4.x clients,
which still send a nil `content_hash`.

Any `content_hash` stored before this release for a document with more than
32 keys in a map, or a float `v` where `|v| >= 1e16` or `|v| < 1e-5`, is
stale by format (computed with the old, non-canonical formatting). No
migration or rehash is needed — the hash self-heals on that document's next
successful update.
