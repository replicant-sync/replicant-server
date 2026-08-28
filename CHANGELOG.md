# Changelog

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
