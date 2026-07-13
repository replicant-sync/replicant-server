# Replicant Server — Coding Guidelines

This repo is the document-synchronization **library** (`ReplicantServer.*`). It has no
web UI and no deployment: host applications (e.g. the entonal web app) depend on it,
mount `ReplicantServer.Sync.Socket` in their endpoint, get `ReplicantServer.Repo` and
the `ReplicantServer.PubSub` from this app's supervision tree, and run the migrations
from this repo's `priv/repo/migrations`.

## Build & Test

- `mix deps.get` to install dependencies
- `mix test` to run the full test suite (requires local Postgres)

## JSON Patch Serialization

**Never pass `Jsonpatch.diff` output directly into broadcast payloads, database fields, or any context that requires JSON serialization.**

`Jsonpatch.diff` returns `Jsonpatch.Operation.*` structs that:
- Have no `op` field (the operation type is only in the struct module name)
- Don't implement `Jason.Encoder`

Always use the `json_diff/2` helper in `Documents` which wraps `Jsonpatch.diff` and converts to plain RFC 6902 maps (`%{op: "replace", path: "/foo", value: "bar"}`).

`Jsonpatch.apply_patch` accepts both struct and map formats, so `json_diff` output works everywhere.

## Library / Web Boundary

The web app lives in its own repository and consumes this library through public
context APIs (Documents, Accounts, Auth, OT) and the sync transport
(`ReplicantServer.Sync.Channel`/`Socket`). No module here may reference
`ReplicantServerWeb` — enforced by `test/replicant_server/boundary_test.exs`.

## Channel Topics

- `sync:user:{user_id}` — per-user document sync (private docs)
- `sync:public` — public document sync
- `documents:*` — Phoenix PubSub topics for host-app UIs (separate from channel topics)

`broadcast_from!` (in `ReplicantServer.Sync.Channel`) excludes the sender socket. `Documents` broadcasts via `Phoenix.PubSub` (`%Phoenix.Socket.Broadcast{}` structs on `sync:*` topics) and reaches all channel subscribers. Both are needed: the sync channel handles client-initiated changes, the Documents context handles host-app changes.
