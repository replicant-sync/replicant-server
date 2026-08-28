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
