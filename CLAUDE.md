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

## Library / Web Boundary

The repo is being prepared to split into a sync **library** (`ReplicantServer.*`: Documents, Accounts, Auth, OT, `ReplicantServer.Sync.Channel`/`Socket`) and a separate **web app** (`ReplicantServerWeb.*`: LiveViews, layouts, assets, deployment). Web modules must only call public context APIs; library modules must never reference `ReplicantServerWeb` (the sole exception is `application.ex`, the composition root, until the split). See issue #4.

## Channel Topics

- `sync:user:{user_id}` — per-user document sync (private docs)
- `sync:public` — public document sync
- `documents:*` — Phoenix PubSub topics for LiveView (separate from channel topics)

`broadcast_from!` (in `ReplicantServer.Sync.Channel`) excludes the sender socket. `Documents` broadcasts via `Phoenix.PubSub` (`%Phoenix.Socket.Broadcast{}` structs on `sync:*` topics) and reaches all channel subscribers. Both are needed: the sync channel handles client-initiated changes, the Documents context handles web UI changes.
