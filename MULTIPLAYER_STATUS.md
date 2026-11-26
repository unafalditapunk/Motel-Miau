# Miau Motel — Multiplayer Status

Milestone status: **Phases A–D complete and verified.** Multiplayer
infrastructure development is paused; core gameplay development
resumes. Future gameplay mechanics must preserve compatibility with
the architecture below but must not expand multiplayer functionality
unless explicitly requested.

## Completed phases

- **Phase A — world snapshot sync**: `WorldSnapshot` serializes the
  authoritative world (floor def, layout, connections, per-room
  states) into chunked reliable RPCs; clients boot floor-definition-
  only and hydrate from the snapshot. Join/spawn handshake gates world
  mutation until `world_synced`.
- **Phase B1/B2 — build ops**: block, furniture, carpet and tile
  place/remove are server-authoritative with per-peer op-id dedup,
  server-side revalidation mirroring single-player rules, and
  broadcast results clients reproduce locally.
- **Phase C1–C4 — structural & floor ops**: room create/delete,
  visibility changes, per-player floor travel, and floor
  create/delete are all server-authoritative. Clients hold replicas
  only — every public structural mutator refuses while
  `structural_edits_readonly()`.
- **Phase D — authoritative persistence**: floor-scoped dirty
  tracking, per-floor runtime-world saves through the existing save
  format, configurable server autosave, and reliable shutdown save.
  The dedicated server is the sole persistence owner.

All phases verified by smoke tests (`run_tests.sh`/`run_tests.ps1`,
27 tests) and live server+client runs including a full restart
recovery check.

## Architecture and server responsibilities

`MultiplayerManager` (`Scripts/Net/`, child of `WorldBootstrap` named
"MultiplayerManager") exists only when launch args request it — no
args means pure single-player. It owns:

- ENet transport (default `127.0.0.1:7777`), peer spawn/despawn,
  welcome handshake.
- One authoritative `Player` body per peer (`network_remote=true`);
  clients send move *requests*, never positions, and reconcile
  prediction against server state.
- All world mutations: build ops, structural ops, floor ops, floor
  transitions — validated, deduplicated (`_build_op_max` serial shared
  across op types), applied once, broadcast to all clients.
- World snapshots for joiners and floor transitions; the `"floors"`
  catalog in every snapshot keeps client floor lists self-healing.
- Persistence: dirty tracking, autosave, shutdown save (Phase D).

Role check: `MultiplayerManager.is_client(tree)` (group
`multiplayer_manager`, mode==CLIENT) is the single source of truth.
Clients never write `user://floors` — replica paths
(`register_floor_replica`, `replica_*`, `apply_layout_data`,
`load_floor_without_save`) are deliberately unguarded and
persistence-free.

## Floors and runtime worlds

- `FloorManager` owns the floor catalog (`Floor` resources) and
  materializes floors into `RoomWorld`s. The **bound** `room_world`
  hosts the boot/active floor; each additional occupied floor gets a
  lazily materialized **runtime world** in `runtime_worlds`, configured
  identically and hydrated from that floor's own save directory.
- Per-player travel: clients request `request_floor_transition`; the
  server resolves/creates the destination world, migrates the body,
  and sends a targeted snapshot. Multiple players can occupy different
  floors simultaneously.
- Room ids collide across floors — every replication payload is
  floor-scoped and clients drop ops for floors they aren't visiting.
- Floor create/delete are catalog-global ops (own RPC pair sharing
  the dedup serial). Deletes reject `occupied` (no evacuation) and
  protected/last-floor rules; active-floor delete migrates bodies and
  releases the runtime world safely.

## Build and structural synchronization

- Build ops (`BuildOps`, static): category dispatch for
  block/furniture/carpet/tile; validation mirrors SP rules per
  category; elevation recomputed server-side; removal picks topmost
  occupant and verifies request identity (`target_changed` on
  mismatch). Floor-scoped via the sender's tracked floor.
- Structural ops: room create/delete, visibility changes, and spawn
  point place/remove (`spawn` op — global world cell, min 1 / max 4
  per floor, must sit inside a room footprint) validate against the
  peer's current floor world; layout.json/connections.json are
  rewritten eagerly server-side; clients apply via unguarded
  `replica_*` paths (`replica_apply_spawn` for spawn ops).
- Floor ops: create broadcasts the canonical `floor_def.json`-format
  dict (clients rebuild in memory, zero disk writes); delete removes
  the floor's entire save directory after occupancy checks.

## Persistence and autosave

- Save layout per floor: `user://floors/<id>/` with `floor_def.json`
  (definition), `layout.json` (room specs/entry/spawn/spawn_points/
  visibility),
  `room_*.json`, `connections.json`, and `floor.json` manifest written
  last as commit marker. No `player_state.json` in floor saves —
  bodies are transient session state.
- Dirty tracking is floor-scoped (`_dirty_floors`): content changes
  are attributed per world via `_world_floor`; struct/visibility/room
  ops mark their target floor; `_persist_paused` suppresses marking
  during hydration; replica applies never dirty.
- `save_floor_state(id)` resolves the correct world (bound or
  runtime) and writes rooms+connections+layout+manifest; floors with
  no materialized world still get layout+manifest. Failed saves keep
  the floor dirty.
- Autosave: dedicated server saves all dirty floors every
  `--autosave=N` seconds (default 60, 0 disables) — synchronous,
  dirty-only.
- Shutdown: normal exit/close runs `shutdown_save()` (all dirty
  floors) then sets `_shutting_down`, which rejects new mutations.
- Recovery: server startup loads `floor_def.json` files, materializes
  lazily, hydrates each world from its own directory; deleted floors
  cannot reappear (their directories are removed).

## Launch and testing

See AGENTS.md "Multiplayer quick start" for commands. Headless
debug args: `--autowalk`, `--dump-world=N`, `--travel=`,
`--floor-op=`, `--build-op=`, `--struct-op=`, `--autosave=N`,
`--shutdown-after=N`, `--saves=<dir>` (per-instance save isolation).

## Phase P4 — portal lifecycle & reliability hardening

- **Deferred avatar spawning (P4.1)**: client `_pending_avatar_spawns`
  queues the latest spawn/state per peer when the matching floor is
  known but the room is not materialized yet (mid-rebuild, late
  replica op). Retried every frame; one entry per peer so states can
  never duplicate an avatar; cleared on despawn, floor change
  (`_apply_transition_spawn`), and server disconnect. Wrong-floor
  states are discarded, never queued — room ids collide across floors.
- **Occupied-floor deletion (P4.2)**: intentionally rejected, not
  evacuated. `_handle_floor_delete` checks `_bodies` occupancy BEFORE
  any mutation (unregister, runtime-world release, save deletion) and
  rejects `occupied`; the floor, its world, and all peer floors stay
  untouched and the floor remains fully usable. A peer still inside
  its join handshake (`_pending_peers`) blocks deletion of the
  PRIMARY floor (`busy`) since its snapshot targets it. Clients surface
  the reason via `floor_result` → FloorPanel status text.
- **Transition recovery (P4.3)**: `_rpc_floor_transition_rejected`
  now echoes the request `transition_id`; the client honors only a
  rejection matching its live pending serial (unversioned id 0 still
  applies — backwards compatible), so a late reject cannot clear a
  newer pending transition. `_rpc_move_request` ignores move requests
  while the sender has an unresolved in-flight transition, so packets
  sent before the commit cannot drag the reparented body. Already
  covered by P2.1 and re-verified: disconnect cleanup
  (`_on_peer_disconnected` releases guard/body/peer_floor), snapshot
  chunk/JSON/apply failure (`_abort_pending_transition`), destination
  materialization failure (`load_failed` before any mutation), missing
  spawn (`no_entry_room` before commit), duplicate requests (`busy`
  guard + `TRANSITION_INFLIGHT_TIMEOUT_MS` expiry), client timeout
  (`transition_timeout` + serial-matched watchdog).
- **Listen-server host travel (P4.4)**: DEFERRED — see limitations.
- **Authorization boundary (P4.5)**: documented below; no auth exists.

## Known limitations and deferred work

- **No listen-server mode**: only dedicated `--server` and `--client`
  exist. A host that is also a player would need a new mode: the host
  would be peer 1 with an authoritative body AND a predicted local
  avatar, self-applying snapshots, and input routing — none of which
  exists today (the server's `_world.player` is a decorative node used
  only for occupancy checks and spawn fallback). Deferred as an
  architectural change, not a portal-lifecycle fix.
- **No auth/encryption** — ENet is plaintext; anyone who can reach the
  port can connect. Authorization boundary audit (P4.5): every
  client-supplied value is revalidated server-side — transition
  requests carry only a floor_id (must be a registered floor, not the
  peer's current one) or a portal cell (destination AND the optional
  arrival cell are derived from the portal definition on the peer's
  authoritative floor, never from the packet — clients cannot pick a
  landing cell); floor ops derive canonical definitions server-side and
  validate ids/occupancy; structural/build ops validate against the
  peer's tracked floor world. What is NOT protected: any connected
  peer can create/delete floors and mutate any reachable floor — there
  is no per-peer permission model. Before a public release: transport
  encryption (DTLS), peer authentication, and per-floor or global
  permission checks on floor/structural ops.
- **No ownership/permissions** — every connected peer can mutate
  anything on floors they can reach (Phase E candidate).
- **No evacuation on occupied-floor delete** — deletes reject while
  bodies remain; a crashed client's body lingers until ENet timeout.
- **Synchronous saves** on the main thread — small JSON writes today;
  revisit if floors grow large.
- **No atomic save writes** — a crash mid-save can leave mixed room
  files under a valid manifest (manifest is written last, which
  bounds but does not eliminate the window).
- **Abrupt kill loses progress since last autosave** — shutdown save
  only runs on normal exit.
- **No movement interpolation** — remote avatars step at server tick
  rate.
- **No persistence of transient session state** — player positions,
  inventories (nonexistent), and peer bookkeeping are intentionally
  not saved.
- Deferred scope (explicitly out of bounds for now): player inventory,
  resource gathering, enemies, combat, party systems, instance
  lifecycle management.
