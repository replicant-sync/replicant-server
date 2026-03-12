# Replicant Server — Coding Guidelines

## Build & Test

- `mix deps.get` to install dependencies
- `mix test` to run the full test suite (100 tests)
- `mix phx.server` to start the dev server

## JSON Patch Serialization

**Never pass `Jsonpatch.diff` output directly into broadcast payloads, database fields, or any context that requires JSON serialization.**

`Jsonpatch.diff` returns `Jsonpatch.Operation.*` structs that:
- Have no `op` field (the operation type is only in the struct module name)
- Don't implement `Jason.Encoder`

Always use the `json_diff/2` helper in `Documents` which wraps `Jsonpatch.diff` and converts to plain RFC 6902 maps (`%{op: "replace", path: "/foo", value: "bar"}`).

`Jsonpatch.apply_patch` accepts both struct and map formats, so `json_diff` output works everywhere.

## Channel Topics

- `sync:user:{user_id}` — per-user document sync (private docs)
- `sync:public` — public document sync
- `documents:*` — Phoenix PubSub topics for LiveView (separate from channel topics)

`broadcast_from!` (in SyncChannel) excludes the sender socket. `Endpoint.broadcast` (in Documents context) reaches all channel subscribers. Both are needed: SyncChannel handles client-initiated changes, Documents context handles web UI changes.
