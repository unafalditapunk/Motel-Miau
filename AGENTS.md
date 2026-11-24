# Miau Motel — Agent Notes

Godot 4.7 project (GDScript). Isometric 64×32 tiles via `IsometricGrid` resource.

## Running tests headless

Godot binary: `C:\Users\Mauro\Downloads\Godot_v4.7.2-stable_win64.exe\Godot_v4.7.2-stable_win64_console.exe`

Run the whole suite (deterministic order, nonzero exit on failure):

```
.\run_tests.ps1                 # Windows PowerShell; -Godot <path> or $env:GODOT to override
.\run_tests.sh                  # bash; GODOT=/path/to/godot ./run_tests.sh [filter]
```

Or a single test:

```
godot --headless --path <project> -s res://Scripts/Test/<TestName>.gd
```

Smoke tests (SceneTree scripts in `Scripts/Test/`): PrototypeSmokeTest,
PlayerCollisionSmokeTest, CameraSmokeTest, PlayerDirectionSmokeTest,
RoomWorldSmokeTest, RoomTransitionSmokeTest, MainRoomWorldSmokeTest,
RoomLayoutSmokeTest, RoomConnectionSmokeTest, RoomNeighborhoodSmokeTest,
SaveIntegritySmokeTest, TileSmokeTest, CarpetSmokeTest,
BuildingCatalogSmokeTest, BuildingUiSmokeTest, FloorSmokeTest,
FloorPersistenceSmokeTest, FloorPanelSmokeTest,
FloorManagementSmokeTest, CreationModeSmokeTest,
WorldSnapshotSmokeTest, BuildOpsSmokeTest,
StructuralGuardSmokeTest, FloorTransitionSmokeTest,
StructuralOpsSmokeTest, FloorOpsSmokeTest. Each prints
`<NAME>_SMOKE: OK`. Tests that touch the filesystem redirect
`RoomSaveSystem.save_dir` to `user://smoke_saves/<test>` so they never
write to the real `user://saves`.

## World architecture

- `WorldBootstrap` (`Scenes/World/WorldBootstrap.tscn`) is the game world
  root: it owns the catalogs/scenes/`RoomDefinition`, configures its
  `RoomWorld` child, builds the primary room via
  `RoomWorld.create_room_from_definition`, spawns the player into
  `room_world.entity_layer`, wires the placement UI, and is the single
  owner of F5/F6 save/load plus autosave (`save_game`/`load_game`).
- `Main.tscn`/`Main.gd` only instantiate WorldBootstrap, set
  `startup_floor_id = &"motel"`, and enable
  `require_explicit_connections`. The Motel floor (`Resources/Floors/
  Motel.tres`) IS the ring world: a 12x12 `MotelCenter` RoomDefinition
  room (id (0,0), entry, spawn (6,6)) ringed by sixteen 4x4 rooms whose
  ids/origins match the old `RING_LAYOUT`. WorldBootstrap boots
  floor-first via `FloorManager.load_floor(startup_floor_id)` — no
  legacy room registration runs; empty `startup_floor_id` keeps the
  legacy single-room bootstrap used by tests. After spawning the player
  it calls `RoomWorld.apply_saved_player_state()` (floor-scoped via
  `_with_save_dir`) because `load_floor` ran before the player existed.
  `user://floors/` is the authoritative save location; legacy
  `user://saves` files are left untouched (ignored, never deleted).
- `Room` owns a local cell grid (`size`, `cells`) starting at local (0,0).
- `Room.cell_origin` (= `global_origin`) is the room's origin in the shared
  world cell grid; `world_cell = cell_origin + local_cell`.
- `RoomWorld` is the façade: registration, connections, saves, and all
  config exports. Two internal components do the heavy lifting, both
  created lazily per instance (floor-ready, no singletons):
  - `RoomNeighborhood` (RefCounted): spatial-bounds + connection-graph
    BFS, distance caching (signature-checked against primary room and
    depth/padding exports; `invalidate()` on room/connection changes).
  - `RoomVisuals` (Node child): de-emphasis materials/tween, neighborhood
    visibility, slide animations; reads config live from RoomWorld.
- `RoomWorld` registers rooms by unique `room_coordinates` ID via
  `register_room_at(room, id, global_origin, furniture_placements)` /
  `create_room_at(...)` / `create_room_from_definition(...)`.
  The legacy `register_room`/`create_room` derive origin as
  `coordinates * room_dimensions` (regular grid only).
- `RoomRegistry` doubles as the layout manager: bounds, containment
  (`get_room_at_global_cell`), overlap (`rooms_overlap`, `find_overlap`,
  `validate_layout`). Overlapping registrations are rejected unless
  `RoomWorld.allow_overlapping_rooms` is set.
- Depth sorting uses global world cells normalized by
  `IsometricGrid.depth_cell_center`, recentred by `RoomWorld` from layout
  bounds to stay inside Godot's ±4096 z_index range.
- Saves: `user://saves/room_<idx>_<idy>_<w>x<h>.json` per room (local
  coordinates only) plus `player_state.json`. Each room save records
  `version`, `room_coordinates`, `size`, and `global_origin`;
  `RoomSaveSystem.check_room_compatibility` rejects saves whose recorded
  identity doesn't match the target room — incompatible files are skipped
  with a warning, never applied, never deleted. Developer tools:
  `RoomWorld.audit_room_saves()` reports compatible/incompatible/orphan/
  unreadable files and `RoomWorld.quarantine_incompatible_saves()` moves
  the bad ones to `user://saves/_quarantine/` (explicit call only).
- Connection exit lookup is deterministic: a single covering connection
  always wins for AUTHORED connections (explicit links may target
  non-adjacent rooms); auto-generated `auto_*` doors are geometric and
  only fire when the step actually enters the destination room's
  footprint — stepping into a shaped room's notch/void bumps instead of
  teleporting. When several connections cover one exit cell, direction
  disambiguates by destination bounds, ties break by connection id with
  a warning, and a direction no destination satisfies refuses the
  transition. The landing cell is the one actually stepped into when it
  is a declared entry (concave corners can border several cells of the
  same room).
- Connection markers: optional ground sprites at connection cells, drawn
  by `RoomVisuals` under each room's `ConnectionMarkers` node. Per
  connection `marker_texture` overrides the RoomWorld per-type exports
  (`door/corridor/stairway/portal_marker_texture`); null everywhere
  means no markers. Marker paths persist in connections.json.
- Connections: `RoomConnection` resources (id, source/destination room ids,
  parallel local `source_cells`/`destination_cells`, type
  DOOR/CORRIDOR/STAIRWAY/PORTAL, `interactive`, `bidirectional`) are managed
  by `RoomConnectionManager` (`RoomWorld.connections`). Non-interactive
  connections trigger when stepping out through a covered edge cell;
  interactive ones trigger when stepping ONTO a covered cell (portals etc.).
  `RoomWorld.require_explicit_connections` blocks edge exits lacking a
  connection; `auto_connect_adjacent_rooms()` generates doors for touching
  rooms. Connections persist in `user://saves/connections.json` and are
  restored by `load_all_rooms()` after rooms register.
- `Floor` (`Scripts/World/Floor.gd`, Resource): pure-data floor definition —
  `floor_id`, `display_name`, `entry_room_id`, `spawn_position`,
  `auto_connect_adjacent`, `rooms` (Array[FloorRoomSpec]), `connections`
  (Array[RoomConnection]), `metadata`. `FloorRoomSpec` holds one room:
  `room_id` (unique within the floor only), `global_origin`, `size`
  (ZERO defers to room_definition/world default), optional
  `RoomDefinition`, `floor_colors`.
- `FloorManager` (`Scripts/World/FloorManager.gd`, Node child of
  WorldBootstrap): owns Floor definitions, auto-loads every `.tres` in
  `res://Resources/Floors/` on _ready, and materializes a floor into the
  bound `room_world` — clears current rooms, creates specs via
  `create_room_at`/`create_room_from_definition`, registers connections,
  runs `auto_connect_adjacent_rooms`, resets hydration, sets primary to
  `entry_room_id`. `activate_floor(id)` swaps the active floor's content.
  Only the active floor is instantiated; inactive floors are data+saves.
  Example floors: Motel (ring world, 17 rooms), Forest/Village (3x3 of
  16x16 rooms) — initial content only, not a hardcoded layout.
- Floor persistence (Phase 2): `FloorSaveSystem` gives each floor its own
  directory `user://floors/<floor_id>/` (`save_root` is reassignable for
  tests) holding `floor.json` (versioned manifest, written last as the
  commit marker) plus the standard `room_*.json`, `connections.json`,
  `player_state.json`. `RoomWorld.save_directory` scopes all
  RoomSaveSystem calls to that dir (`effective_save_directory()`);
  empty means the legacy `user://saves`. `FloorManager.save_active_floor()`,
  `load_floor(id)`, `has_floor_save(id)`, and `switch_floor(id)` implement
  the fail-safe switch: save outgoing → validate destination (definition
  + manifest; corrupt manifest aborts) → materialize → hydrate → place
  player (saved state, else entry_room_id/spawn) → emit `floor_switched`.
  Failed loads roll back to the previous floor. `is_floor_dirty()` is
  advisory, fed by `RoomWorld.room_content_changed` (room cells_changed +
  BlockLayer.content_changed). WorldBootstrap delegates F5/F6/autosave to
  the active floor and rebinds room refs on `floor_switched`.
- Floor Manager UI (Phase 3): `FloorPanel` (`Scripts/UI/FloorPanel.gd`,
  CanvasLayer created by WorldBootstrap) toggles with F7, lists every
  registered floor dynamically (name, id, room count, grid layout,
  saved/new, ACTIVE badge) with an Enter button per row that calls
  `FloorManager.switch_floor` — no save/load logic in the UI. The
  "New Floor" button reveals a small form (id + optional display name)
  calling `FloorManager.create_floor`; each row also has a Del button
  calling `FloorManager.delete_floor` (disabled on the last floor).
  While open,
  `FloorPanel.any_open(tree)` blocks Player movement
  (`request_move`/`_start_move`/held-key input) and
  BlockPlacementController input; F3/F5/F6/Q keep working. The panel
  tracks live rows in `_floor_rows`/`_enter_buttons` because queue_free'd
  rows linger for a frame. DebugHud shows a `Floor:` line (name, id,
  room count, dirty/saved) resolved via the `world` group.
- Creation Mode (Phase 1): `FloorEditor` (`Scripts/World/FloorEditor.gd`,
  Node2D child of RoomWorld, group `floor_editor`) is the third mode —
  PLAY / BUILD (`construction_mode`) / CREATION. F enters from Build
  Mode and returns to it; Q (catalog toggle in Build Mode) and Escape
  also return to Build Mode. Leaving Build Mode exits.
  While active: player movement and BlockPlacementController input are
  blocked via `FloorEditor.any_active()`, neighborhood hiding/de-emphasis
  are suspended so every room shows, and a blueprint pass hides room
  content layers (FloorRenderer/TileLayer/CarpetLayer/BlockLayer/
  HoverHighlight/ConnectionMarkers/RoomLabel), the player, and
  PlacementGhost — GRID view only; ROOMS view keeps normal visuals.
  Prior visibility is restored on view switch or exit. FloorPanel
  ignores F7, and a floor
  switch exits the editor. The editor draws the infinite global
  world-cell grid (visible cell range from the camera, capped) with
  occupied room bounds shaded; V toggles GRID/ROOMS view, B recenters
  on the floor bounds. WorldCamera gains `set_editor_mode()` (detaches
  follow, keeps the normal gameplay zoom ladder), WASD/arrow +
  middle-drag pan, and `focus_on()`. Cursor cell = `grid.screen_to_grid(mouse world pos)` via
  `cursor_cell_for_world_position()` (injectable for headless tests).
  DebugHud adds a `Mode: CREATION` line with view + cursor cell.
  Creation Mode (Phase 2): the Create Room tool (C toggles, GRID view
  only) drags LMB rectangles on the global grid — each drag adds one
  section to the pending shape (`_pending_sections`); releasing keeps
  it, Backspace undoes the last section, and X opens a PixelUi
  confirmation panel (auto "x,y" room id, read-only, section/cell/bounds
  info, Create/Cancel). Sections must be sized (2..1024 cells per axis,
  `Floor.MIN_ROOM_DIMENSION`), non-overlapping, edge-connected to the
  pending union, cell-clear of existing rooms, and the finished shape
  must share an edge with an existing room (`_edges_touch` — corner
  contact doesn't count); an empty floor accepts its first room.
  Preview colors: green valid / orange overlap / yellow isolated or
  disconnected / red invalid. Rooms may be non-rectangular: a spec's
  `shape_sections` (global rects, `FloorRoomSpec`) become the Room's
  LOCAL `shape_sections` relative to the footprint bounding box, and
  `Room.cells` only contains footprint cells — every per-cell system
  (movement, building, saves, queries) is cell-exact automatically.
  `global_origin`/`size` normalize to the union bbox; bbox "holes" are
  not room cells and may be filled by other rooms. Sections persist in
  layout.json (`"sections"` per entry); room saves stay compatible via
  the bbox size/origin. The panel has
  two visibility checkboxes (both default on): `show_from_outside=false`
  hides the room until the player enters it, `show_outside=false` fades
  out adjacent rooms' whole Room.modulate (floors, tiles, carpets,
  blocks, markers — edge AND corner contact) while it is primary —
  RoomVisuals animates both (slide for rooms, alpha fade for rooms).
  Flags live on
  FloorRoomSpec/Room and persist in layout.json. Esc/RMB/V/B
  cancel drags and panels safely. Confirming calls
  `FloorManager.add_room_to_active_floor(spec)`, which re-validates
  everything server-side, creates just that room via the normal
  `_create_room` path (world default floor/tile — no RoomDefinition
  required), appends the spec, sets entry/spawn when the floor was
  empty, runs idempotent `auto_connect_adjacent_rooms`, marks dirty,
  and writes `layout.json`. Requires an active floor.
- Room inspector/delete: an LMB click (press+release, no drag) on a
  room in GRID view opens a panel with id/origin/size/contents.
  `FloorManager.can_delete_room` allows deletion only when the room has
  no placed contents (`Room.placed_content_counts` — blocks/furniture,
  anchored carpets, non-default tile overrides), the player is not
  inside, it is not the last room, it has no explicit floor
  connections, and every edge-adjacent room keeps another neighbor.
  `remove_room_from_active_floor` unregisters runtime connections,
  rewrites `connections.json` immediately, reassigns entry/spawn when
  the entry room is deleted, drops the spec, and persists layout.json.
  The panel's Delete is two-step: the first press only arms it (button
  becomes "Confirm", status prompts), the second press deletes; the arm
  resets whenever the panel closes or another room is inspected.
- Floor layout persistence: `FloorSaveSystem.save_layout/load_layout`
  store room SPECS (id/origin/size/definition path/colors) plus
  `entry_room_id`/`spawn_position` as `user://floors/<id>/layout.json`
  — res:// .tres files are never modified at runtime.
  `FloorManager._apply_layout_override()` runs at the top of
  `load_floor`/`activate_floor`, replacing `floor_def.rooms` (and
  entry/spawn) in memory; `add_room_to_active_floor()` writes it on
  creation and `save_active_floor()` rewrites it on every F5/switch
  save. `load_floor` snapshots specs+entry+spawn before the override
  and restores them when validation refuses the load, so invalid
  layouts never poison the in-memory Floor. Corrupt/missing layout =
  ignored with a warning, never fatal.
- Floor management (create/delete): `FloorManager.create_floor(id,
  name, specs, auto_connect)` builds a Floor in memory, validates it,
  registers it, and persists the full definition to
  `user://floors/<id>/floor_def.json` via
  `FloorSaveSystem.save_floor_definition` — self-contained (specs,
  entry/spawn, connections, metadata) since res:// is never written.
  Empty spec lists get a default 8x8 room. `_ready` also calls
  `_load_saved_floor_definitions()`, which rebuilds Floors from every
  floor_def.json under `FloorSaveSystem.save_root` (duplicate ids
  lose to shipped res:// floors via register_floor). Connections
  round-trip through `FloorSaveSystem.connection_to_dict/from_dict`.
  `can_delete_floor`/`delete_floor` refuse unknown ids and the last
  remaining floor; deleting the ACTIVE floor first `switch_floor`s to
  a fallback (saving outgoing state, rebuilding the world) so no stale
  references remain, then `unregister_floor` +
  `FloorSaveSystem.delete_floor_save` (recursive dir removal) drops
  all its data.
- Structural mutation guard (Phase C1): `MultiplayerManager.is_client
  (tree)` is the single role check (group "multiplayer_manager",
  mode==CLIENT — single-player has no node, server reports SERVER).
  `FloorManager.structural_edits_readonly()` delegates to it and every
  public structural mutator refuses while true: register/unregister_
  floor, create/delete_floor, switch/load/activate_floor,
  add/remove_room_to_active_floor. Internal replica paths are
  deliberately unguarded — `load_floor_without_save` (client boot),
  `materialize_floor`, `apply_layout_data`, `WorldSnapshot.apply`.
  FloorPanel renders read-only on clients for STRUCTURAL edits (list/
  ACTIVE badge intact; New Floor and Del disabled + handler guards)
  but Enter stays enabled — it sends a travel REQUEST (Phase C2);
  FloorEditor keeps inspection but refuses the create-room
  tool, room delete, visibility checkboxes, and panel-create, with a
  HUD read-only line. StructuralGuardSmokeTest covers all of it with
  a bare mode=CLIENT manager node.
- Per-player floor transitions (Phase C2): players may stand on
  different floors simultaneously. The server keeps one RoomWorld per
  OCCUPIED floor — the bound `room_world` serves the FloorManager's
  active (boot) floor; `FloorManager.runtime_worlds` maps other floor
  ids to `WorldBootstrap.create_floor_world(id)` instances (fully
  configured clones: catalogs, grid, scenes). `materialize_runtime_
  floor(id, world)` materializes + hydrates via `load_room_states`/
  `save_room_states` (room contents + connections only — NO
  player_state.json, since bodies are not world state). Peer→floor
  lives in `MultiplayerManager._peer_floor`; `_world_for_peer`/
  `_world_for_floor` resolve the right RoomWorld for build ops and
  `_player_world_cells` (occupancy is per-world). Room ids are only
  unique per floor, so spawn/state/build-result payloads all carry
  `floor_id` and clients filter against `_my_floor_id`.
  CRITICAL: `Player.room_world` must be set at every bind site
  (spawn, body/avatar spawn, floor transition both directions,
  `_ensure_player_placement`, `_apply_saved_player_state`,
  `_reconcile_local`) — `Player._room_world()` falls back to the
  "room_worlds" group only when unset, which is ambiguous once the
  server hosts several floor worlds (bodies on forest/village were
  resolving transitions against the motel world → reconcile jumps).
  Transition flow: client `request_floor_transition(floor_id)` (F7
  Enter or `--travel=<id>`) -> `_rpc_floor_transition_request` ->
  server `_handle_floor_transition` validates (body exists =
  world-synced, floor registered, not already there), materializes
  the destination world on first visit, saves the outgoing world's
  room states, reparents the body into `dest_world.entity_layer` at
  the floor's entry/spawn (footprint-snapped), then sends THAT peer a
  private snapshot (`WorldSnapshot.build(fm, dest_world, floor_def)`
  with snapshot purpose "travel" — applies + `_apply_transition_spawn`,
  no world_ready) plus rpc_id `_rpc_spawn_player` for occupants of the
  new floor and `_rpc_despawn_player` for the leaver. Rejections go
  through `_rpc_floor_transition_rejected` and unlock input;
  `transition_result` signal reports the outcome. Snapshots now carry
  `floor_def` (floor_def.json format) so clients register floors the
  server created at runtime via `FloorManager.register_floor_replica`
  (unguarded — replica state, not a local edit). `_transition_pending`
  locks input/build requests until the destination snapshot lands.
  Known limits: runtime worlds are never
  freed on travel (reused per floor), server has no permissions model — any
  registered floor is travelable. FloorTransitionSmokeTest covers
  rejections, per-peer isolation, runtime-world materialization, and
  the replica apply path.
- Authoritative room structural ops (Phase C3): clients create/delete
  rooms and toggle `show_from_outside`/`show_outside` through
  `MultiplayerManager.request_struct_create/delete/visibility` ->
  `_rpc_struct_op` -> `_handle_struct_op`. Requests carry op kind,
  floor_id, room spec (FloorSaveSystem.spec_to_layout_entry shape) or
  room_id, both visibility flags, and share the build-op id dedup
  (`_build_op_max`/`_claim_build_op` — one monotonic serial per client
  for ALL op kinds). The server derives the peer's floor from
  `_peer_floor` and rejects `wrong_floor`/`not_ready`/`duplicate`/
  `unknown_op`; validation reuses the FloorManager cores which were
  refactored floor-scoped: `_add_room_to_floor`/`_remove_room_from_
  floor`/`_can_delete_room`/`_set_room_visibility` take
  (floor_def, world[, occupied, persist]) — public wrappers
  (`add_room_to_floor`, `remove_room_from_floor`,
  `can_delete_room_on_floor`, `set_room_visibility_on_floor`) resolve
  via `world_for_floor` and persist (layout.json + connections.json on
  delete); `persist=false` + the `replica_*` ops are the client path.
  Delete occupancy is multiplayer-aware: `_occupied_room_ids(world)`
  maps every authoritative body (all `_bodies` on that floor's world
  plus the server's own avatar) to its room_id — the local "player"
  group alone is insufficient. Accepted ops broadcast
  `_rpc_struct_result.rpc` to everyone with floor_id + requester;
  clients drop other floors' ops, QUEUE ops arriving before the
  snapshot finishes (`_pending_struct_ops`, flushed by
  `_flush_pending_struct_ops` on join/travel/rejected-transition —
  reliable ordering puts the snapshot ahead, and `_apply_struct_
  payload` is idempotent so snapshot-carried changes count as
  consistent). `struct_result` signal feeds FloorEditor, which sends
  requests instead of mutating on clients (`_struct_manager`,
  `_struct_pending` HUD count, `_on_struct_result` refreshes panels;
  `payload.requester` distinguishes own ops from observers').
  `--struct-op=create:rx,ry:ox,oy:w,h|delete:rx,ry|vis:rx,ry:a,b`
  fires requests headless after sync. StructuralOpsSmokeTest covers
  the C3 matrix.
- Authoritative floor ops (Phase C4): floor create/delete are
  catalog-global (not floor-scoped), so they use their own RPC pair
  `request_floor_create/delete` -> `_rpc_floor_op` ->
  `_handle_floor_op`, sharing the `_build_op_max` dedup serial.
  Requests carry only `floor_id`/`display_name`; the server derives
  the canonical definition itself via `FloorManager.create_floor`
  (validates id via `FloorSaveSystem.floor_dir`, rejects duplicates,
  persists `floor_def.json`) and broadcasts
  `_rpc_floor_result.rpc` to ALL clients with the
  `floor_definition_data` payload — clients register via
  `register_floor_replica`/`_floor_from_saved_data` (no disk). Delete
  reuses `can_delete_floor` (protected/last-floor rules) plus a
  multiplayer occupancy sweep over `_floor_id_for_peer` for every
  body — occupied floors reject with `occupied`, no evacuation.
  Active-floor delete first `switch_floor`s to a fallback, then
  `_migrate_runtime_bodies_to_bound` rebinds any bodies parked in the
  fallback's runtime_worlds entry into the bound world before
  `release_runtime_world` + `unregister_floor` +
  `delete_floor_save`. Ordering/sync: every WorldSnapshot now carries
  a `"floors"` catalog (all `floor_definition_data` entries) and
  `apply` reconciles replicas — self-healing for joins and missed
  broadcasts; reliable ordered RPCs keep broadcasts behind the
  snapshot that contains them. Client-side
  `unregister_floor_replica` refuses the ACTIVE floor (divergence
  surface, resolved by next snapshot). FloorPanel create/delete
  buttons stay enabled on clients and send requests; `floor_result`
  signal refreshes the list/status. `--floor-op=create:id[:name]` /
  `delete:id` (repeatable) and repeatable `--travel=` fire headless
  after sync. FloorOpsSmokeTest covers the C4 matrix.
- Neighborhood: the visible set is the primary room plus rooms within
  `spatial_neighborhood_depth` BFS hops of bounds adjacency (a room's
  `global_bounds()` grown by `neighborhood_padding` world cells must
  intersect — size- and position-aware) UNION rooms within
  `connection_neighborhood_depth` hops of the connection graph.
  `get_visible_room_coordinates()`, `get_spatial_neighbors()`,
  `spatial_distance_from_primary()`, `get_connected_room_ids()`, and
  `connection_distance_from_primary()` expose it; F3 shows counts.
- Multiplayer prototype: `MultiplayerManager` (`Scripts/Net/`, Node
  child of WorldBootstrap named "MultiplayerManager" — the stable RPC
  path) exists ONLY when launch args request it; no args = pure
  single-player. `-- --server` runs a dedicated ENet server (peer 1,
  headless-friendly, skips save-on-exit), `-- --client[=IP] --port=N`
  connects (default 127.0.0.1:7777), `--autowalk` paces the local
  player for headless tests. The server owns one authoritative Player
  body per peer (`network_remote=true`: no "player" group membership,
  no local input — remote avatars join "net_avatar" instead so camera
  follow and blueprint hiding keep working). Clients send move
  REQUESTS (directions via `move_requested` signal -> `_rpc_move_request`),
  never positions; the server re-validates with real Player rules and
  broadcasts `authoritative_state_changed`-driven `_rpc_player_state`
  (room id + local cell + elevation + facing). Clients predict locally
  and reconcile on divergence (`_reconcile_local`). Spawn flow:
  `peer_connected` -> `_rpc_welcome` (spawn + existing players) to the
  joiner + `_rpc_spawn_player` broadcast; `_rpc_despawn_player` on
  disconnect.
- World snapshot sync (Phase A): `WorldSnapshot` (`Scripts/Net/`,
  RefCounted) is the authoritative world transfer — `build()` on the
  server serializes `{version, floor_id, floor_def, layout, connections,
  room_states}` reusing `FloorSaveSystem.layout_data`,
  `FloorSaveSystem.floor_definition_data`,
  `RoomConnectionManager.serialize_all`, and
  `RoomSaveSystem.collect_room_state` per room (player position is
  deliberately excluded — avatars come from the spawn handshake).
  `floor_def` (floor_def.json format) lets a client register floors
  unknown to it via `FloorManager.register_floor_replica`;
  `build`'s optional third arg overrides `active_floor` for
  non-active runtime worlds, and `apply` honors a `"spawn"` dict for
  floor transitions.
  `apply()` on the client runs `FloorManager.apply_layout_data`
  (in-memory spec override sharing `_apply_layout_entries` with the
  layout.json path — never writes disk), `validate_floor`,
  `materialize_floor`, `deserialize_all`, then
  `RoomSaveSystem.apply_room_state` per room, and finally
  `_ensure_player_placement` + `floor_switched` so room-scoped refs
  rebind. Clients boot via `FloorManager.load_floor_without_save`
  (definition only — no layout.json override, no manifest check, no
  room hydration) and skip `apply_saved_player_state`; `WorldBootstrap`
  blocks all local world saves on clients (`_net_client_readonly`).
  Transport: reliable JSON chunked (`_rpc_snapshot_begin/chunk/end`,
  48 KiB chunks, snap_id + index/total, missing-chunk = abort);
  client replies `_rpc_world_ready`, and ONLY then does the server
  spawn bodies/avatars (`_pending_peers` + 15 s timeout kicks
  unacknowledged peers). Readiness gate: `MultiplayerManager.
  world_synced` gates `request_move` RPC forwarding AND the client's
  `Player.local_input_locked` (checked inside `_world_ui_blocked`, so
  no local prediction either) until the snapshot applies; server
  disconnect re-locks. `--saves=<dir>` redirects `FloorSaveSystem.
  save_root` for isolated test saves; `--dump-world` prints every
  room's blocks/contents once (server at boot, client post-sync) —
  diff the WORLD_DUMP lines to verify replication. `SeedFloorSave.gd`
  (`-s` script) writes a real motel save with chosen blocks/carpets
  into a `--root` dir for live tests.
- Build ops (Phase B1+B2): block, furniture, carpet and tile
  place/remove are all server-authoritative. `BuildOps`
  (`Scripts/Net/`, static) holds the shared rules: B1's
  `validate_place`/`validate_remove`/`apply_place`/`apply_remove` for
  plain blocks, plus the category-dispatching
  `validate_place_any`/`validate_remove_any`/`apply_place_any`/
  `apply_remove_any`/`topmost_at` used for every category. Validation
  mirrors the single-player rules per category: furniture uses
  `can_place_furniture` + rotated footprint + player occupancy;
  carpets use `Room.can_place_carpet` (no player check, like SP);
  tiles need only an existing cell; elevations are always recomputed
  server-side via `get_top_z_at`. Removal picks the topmost occupant
  by z-then-priority (block-layer 0 < tile 1 < carpet 2, same rule as
  `remove_at`) and verifies the request's category + identity
  (block/furniture: id+pos+elev[+rotation]; carpet: id+anchor+rotation
  +flip; tile: id+elev) — mismatches reject as `target_changed`.
  Player occupancy: block/furniture place checks every footprint
  cell; all removes check occupied cells (blocks) or the clicked
  cell (carpet/tile), across ALL player bodies.
  Clients route `BlockPlacementController.place_at`/`remove_at`
  through `MultiplayerManager.request_build_place/remove` (gated on
  `can_request_build()` = CLIENT + connected + world_synced).
  Wire: `_rpc_build_place/remove` (any_peer, reliable) carry op_id +
  a request Dictionary (room_id, cell, category, object_id, rotation,
  flip, and remove-identity fields pos/elev/anchor); server dedups
  per-peer op ids (`_claim_build_op` keeps the highest id seen per
  peer — client ids are monotonic, so replays are rejected forever,
  not just within a window), rejects to sender only via
  `_rpc_build_result(false, reason)`, applies once, then broadcasts
  `_rpc_build_result(true, payload)` to all clients — clients
  reproduce via `BuildOps.apply_*_any` with no re-request (a failed
  local apply pushes a divergence warning). All build traffic is
  floor-scoped: requests validate against the SENDER's floor world
  (`_world_for_peer`), results carry `floor_id`, and clients drop ops
  for floors they are not visiting (room ids collide across floors).
  `can_request_build()` also requires no pending floor transition. Request fields are
  coerced via `BuildOps.req_int/req_float/req_bool` — raw
  int()/float()/bool() on Variant RPC data can abort a handler.
  `build_result` signal is the UI feedback hook. Debug args:
  `--build-op=place:x,y:category:id[:rot[:flip]]` (repeatable) and
  `--build-op=remove:x,y` (auto-detects topmost) fire 2 s + 1.5 s·i
  after sync; legacy `--build-place/--build-remove` still parse;
  `--dump-world=N` delays the WORLD_DUMP by N seconds (server dumps
  every materialized floor world plus a `peer_floors` map; it now
  lists explicit tile overrides and carpet anchors per room) and
  `--travel=<floor_id>` (repeatable, in order) requests client floor
  transitions once synced. Known limits:
  server
  persistence/autosave deferred (Phase D) — the dedicated server
  still skips save-on-exit; movement has no interpolation; no
  auth/encryption.
