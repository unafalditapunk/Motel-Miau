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
StructuralOpsSmokeTest, FloorOpsSmokeTest, ServerPersistenceSmokeTest,
SpawnPointSmokeTest, PortalSmokeTest, PortalTransitionSmokeTest,
PortalLifecycleSmokeTest, TransitionOverlaySmokeTest.
Each prints `<NAME>_SMOKE: OK`. Tests that touch the filesystem redirect
`RoomSaveSystem.save_dir`/`FloorSaveSystem.save_root` to a
`user://smoke_*` scratch dir so they never write to the real saves.

## Multiplayer quick start

Multiplayer exists only when launch args request it (everything after
`--` is a user arg). Dedicated server:

```
Godot --path <project> -- --server [--port=7777] [--saves=<dir>]
	  [--autosave=60] [--shutdown-after=N]
```

Clients (repeatable, any number):

```
Godot --path <project> -- --client[=IP] [--port=N] [--saves=<dir>]
```

`--saves=<dir>` redirects `FloorSaveSystem.save_root` per instance —
use it to isolate test saves from the real `user://floors`. Useful
debug args: `--autowalk` (headless player pacing), `--dump-world=N`
(WORLD_DUMP after N s — diff server vs client output to verify
replication), `--travel=<floor_id>` (repeatable), `--floor-op=
create:id[:name]|delete:id`, `--build-op=place:x,y:cat:id|remove:x,y`,
`--struct-op=create:rx,ry:ox,oy:w,h|delete:rx,ry|vis:rx,ry:a,b|spawn:x,y:0|1`.
In-game: F7 floor panel (create/delete/enter floors — clients send
requests to the server), F3 debug HUD. Phase status and architecture
details: `MULTIPLAYER_STATUS.md`; deep notes in the multiplayer
bullets below.

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
  it calls `FloorManager.place_player_at_spawn()` (floor-scoped via
  `_with_save_dir`) because `load_floor` ran before the player existed —
  spawn points are the only floor entries; saved `player_state` no
  longer resumes a previous position (still written, still used by the
  legacy non-floor bootstrap).
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
  `spawn_points` (Array[Vector2i] of GLOBAL world cells — the floor's
  natural entries, min `MIN_SPAWN_POINTS`=1 / max `MAX_SPAWN_POINTS`=4,
  each inside a room footprint; `spawn_points[0]` mirrors
  entry_room_id/spawn_position), `auto_connect_adjacent`, `rooms`
  (Array[FloorRoomSpec]), `connections`
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
  player (ALWAYS a RANDOM spawn point via
  `spawn_placement_for` — spawn_points shuffled, entry/spawn fallback;
  saved player_state never wins on floor entries)
  → emit `floor_switched`.
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
  Deleting a room also removes every spawn point inside it — allowed
  only while the floor keeps `Floor.MIN_SPAWN_POINTS` afterwards
  (`can_delete_room` refuses otherwise). Spawn points themselves are
  managed by `FloorManager.place_spawn_point`/`remove_spawn_point`
  (active floor) and the `*_on_floor` variants (multiplayer runtime
  worlds): global world cells, must lie inside a room's footprint
  (cell-exact for shaped rooms), max 4 per floor, min 1 always kept;
  placing/removing resyncs entry_room_id/spawn_position to
  spawn_points[0] and persists layout.json. Floors registered without
  an explicit list derive one point from entry/spawn
  (`_normalize_spawn_points`); `spawn_cell_room(cell)` resolves the
  containing spec. Floor entry uses `FloorManager.spawn_placement_for`:
  a random spawn point's room+local cell (shuffled candidates, legacy
  entry/spawn fallback) — used by `_ensure_player_placement` and the
  multiplayer `_handle_floor_transition` (server picks per player and
  ships it in snapshot["spawn"]). Every floor entry — F7 travel, boot,
  MP join (`_spawn_body` also picks via `spawn_placement_for` and the
  welcome RPC propagates it) — lands on a random spawn point; saved
  player_state never resumes a position on floor paths. The
  panel's Delete is two-step: the first press only arms it (button
  becomes "Confirm", status prompts), the second press deletes; the arm
  resets whenever the panel closes or another room is inspected.
- Spawn point tool: G toggles it in GRID view (like C for Create
  Room). LMB press+release on a cell places a spawn point there when
  the cell is inside a room and the floor is below
  `Floor.MAX_SPAWN_POINTS`; clicking an existing spawn cell removes it
  while more than `Floor.MIN_SPAWN_POINTS` remain. Spawn cells draw
  `spawn_cell_iso.png` markers plus a tinted cursor ghost (green =
  place allowed, dimmed = would remove, red = refused; neutral on
  multiplayer clients since the verdict is server-side). On clients
  the click sends a `spawn` structural op
  (`request_struct_spawn` -> `_handle_struct_spawn` -> broadcast ->
  `replica_apply_spawn`) instead of mutating locally. HUD shows the
  tool hint and `n/4` count.
- Floor portals (Phase P1): `FloorPortal` resources on
  `Floor.portals` link one GLOBAL world cell to another floor —
  independent from `RoomConnection` (which stays intra-floor).
  Fields: `portal_id` (deterministic `portal_x_y` from the cell),
  `room_id`, `world_cell`, `destination_floor_id`, and optional
  `destination_world_cell` (arrival override — `NO_DESTINATION_CELL`
  sentinel = normal random spawn). The arrival cell must sit inside
  a room footprint of the DESTINATION floor (`_can_place_portal`
  refuses bad cells at authoring time); pointing it at another
  portal's cell creates portal-to-portal chains. A stale arrival
  (e.g. its room was later deleted) only warns in `validate_floor`
  and falls back to spawn placement at travel time via
  `arrival_placement_for_cell` — it never blocks floor loading.
  `FloorManager.switch_floor_at(id, cell)` / `_arrival_override_cell`
  carry the override through single-player switches (consumed by
  `_ensure_player_placement` even with no player bound); multiplayer
  resolves it server-side in `_handle_floor_transition` — the client
  never sends it. Managed by
  `FloorManager.place_portal`/`remove_portal`/
  `update_portal_destination` (active floor) and the `*_on_floor`
  variants (runtime worlds): cell must be inside a room footprint,
  free of other portals, and NOT covered by an interactive
  RoomConnection (`portal_cell_status`/`can_place_portal` verdicts);
  destination must be another registered floor — same-floor and
  unknown destinations refused. Portals persist inside layout.json
  (and floor_def.json/snapshots via `layout_data`) — one
  authoritative representation, malformed entries skipped with a
  warning, missing key = untouched. `delete_floor` prunes portals on
  other floors targeting it (persisting each affected layout);
  room delete drops portals inside the room; `load_floor`/
  `materialize_runtime_floor` snapshot+restore portals on refused
  loads like specs/spawns. Trigger: after a successful in-room step,
  `Player._trigger_floor_portal` looks up `portal_at(world_cell)` on
  the bound world only (skips readonly/MP-replica worlds and stale
  destinations), arms `_floor_portal_pending`, and
  `floor_portal_delay` (0.18s, effectively max(delay, move_duration)
  so the step tween always finishes first — otherwise place_at cuts
  it short and the sprite snaps) later calls `switch_floor(destination)`
  or `switch_floor_at` when the portal has an arrival cell — save
  outgoing, materialize, spawn/arrival placement, rollback on failure.
  Portal cells and interactive
  connection cells are mutually exclusive by placement rule, so the
  two trigger paths never compete. Creation Mode H tool (GRID view):
  LMB opens a panel — place mode on free cells (destination picker
  lists floors by name, current floor excluded, Place disabled with
  reason on invalid cells), edit mode on existing portals (retarget
  or Delete); purple diamond markers + destination labels draw in
  GRID view. The portal panel's "Arrive at" picker offers Random
  spawn or any portal on the destination floor (portal chains).
  Multiplayer (Phase P2): portal DEFINITIONS reach clients
  free via WorldSnapshot (`layout_data` -> `apply_layout_data`), but
  ACTIVATION is server-authoritative — a client steps on a portal
  cell, `Player._on_floor_portal_delay_elapsed` calls
  `MultiplayerManager.request_portal_transition(world_cell)` (only the
  CELL is sent), and `_handle_portal_transition` validates against
  `_peer_floor` + `portal_at_on_floor` + the body's authoritative
  `room.world_cell_coordinates(grid_position)` (movement is
  server-validated via `_rpc_move_request` -> `body.request_move`),
  derives the destination AND the optional arrival cell from the
  portal itself (server data — clients cannot pick a landing cell),
  then delegates to the shared `_handle_floor_transition` C2
  pipeline, which resolves `arrival_placement_for_cell` before
  falling back to `spawn_placement_for`. Dedicated-server
  bodies never self-trigger. Server in-flight guard (P2.1):
  `_transition_inflight[peer_id] = {id, msec}` is acquired at the
  commit point and held until the client acks the travel snapshot via
  `_rpc_transition_done` (id-matched through `_release_transition_guard`),
  the `TRANSITION_INFLIGHT_TIMEOUT_MS` (20s) safety window expires
  (lost-ack recovery), or the peer disconnects — requests while held
  reject `busy`; snapshot prep now runs BEFORE any mutation so
  `snapshot_failed` rejects leave no guard/body/floor changes. Client
  `transition_timeout` (12s) watchdog releases input + emits
  `transition_result(false, &"timeout")` via a serial-checked
  `_on_transition_timeout`; transition_id = the client request serial,
  echoed in the snapshot's `"transition_id"` — `_complete_travel_snapshot`
  always applies world+spawn (server committed) but only a matching id
  completes the pending request, unlocks input and emits success; stale
  or late snapshots apply silently and still send the done-ack.
  Visual transitions (Phase P3): `TransitionOverlay`
  (`Scripts/UI/TransitionOverlay.gd`, CanvasLayer group
  `transition_overlay`, built by WorldBootstrap) is pure presentation —
  it never decides transition success. The visual language reuses the
  room slide animation: `RoomVisuals.slide_all_out()` slides every
  visible room down/off, `slide_all_in()` slides the destination
  floor's rooms in from above, `slide_all_home()` snaps bulk-exited
  rooms back on failure (tracked in `_bulk_exit_rooms`). Rooms mid
  EXIT slide at slide_all_in time are the should-be-hidden set —
  slide_all_in snaps them hidden instead of sliding them in, or they
  would stay visible forever (exit slides keep room.visible true and
  nothing re-evaluates visibility after the transition). Entities are
  NEVER hidden — the player stays visible through the whole
  transition (input unlocks the instant the destination world is
  ready; they can walk during slide-in). Single-player `play_transition(callable)` is
  DEFERRED: slide-out plays, then the callable runs once the screen
  has cleared, then slide-in — the result arrives via the
  `transition_completed(success)` signal (play_transition returns
  true = started; with `room_slide_duration == 0` or no visible rooms
  it falls back to a fully synchronous call returning the real
  result). The MP client path is signal-driven:
  `MultiplayerManager.transition_requested` slides out and parks in
  WAITING (the server round-trip IS the loading wait); the snapshot
  applies the new world, then `transition_result(accepted, reason)`
  (id-matched per P2.1) slides in, or slide_all_home restores the old
  floor on rejection/timeout. `play_transition` refuses while any
  transition is in progress; the pre-transition `local_input_locked`
  state is captured once so re-entry can't wedge the lock. Per-player
  isolation is structural — each client owns one overlay fed only by
  its local lifecycle signals; nothing is broadcast.
  Portal lifecycle hardening (Phase P4): client `_pending_avatar_spawns`
  queues the latest spawn/state per peer when the floor matches but the
  room is not materialized yet — retried per frame, deduplicated,
  cleared on despawn/floor-change/disconnect; wrong-floor states are
  discarded. `_rpc_floor_transition_rejected` echoes the request
  `transition_id` and the client honors only a match to its live
  pending serial (`_handle_transition_rejected`; id 0 = unversioned
  legacy). `_rpc_move_request` drops requests while the sender's
  transition is unresolved. Occupied-floor delete is intentionally
  rejected `occupied` BEFORE any mutation (no evacuation); a pending
  join snapshot (`_pending_peers`) also blocks primary-floor delete
  (`busy`). Floor-op rejection reasons map to friendly FloorPanel
  text. Listen-server host travel is deferred — no host-player mode
  exists (see MULTIPLAYER_STATUS.md).
  `TransitionOverlay.any_active(tree)` lets building UI
  (BlockPlacementController) refuse input mid-transition;
  `find_overlay` locates it. `WorldBootstrap.switch_floor`,
  `FloorPanel` Enter (which also surfaces async failures via
  `transition_completed`), and the Player portal delay callback all
  route through it; bare `FloorManager.switch_floor` bypasses the
  transition (used by tests).
- Floor layout persistence: `FloorSaveSystem.save_layout/load_layout`
  store room SPECS (id/origin/size/definition path/colors) plus
  `entry_room_id`/`spawn_position`/`spawn_points`/`portals` as
  `user://floors/<id>/layout.json`
  — res:// .tres files are never modified at runtime.
  `FloorManager._apply_layout_override()` runs at the top of
  `load_floor`/`activate_floor`, replacing `floor_def.rooms` (and
  entry/spawn) in memory; `add_room_to_active_floor()` writes it on
  creation and `save_active_floor()` rewrites it on every F5/switch
  save. `load_floor` snapshots specs+entry+spawn+spawn_points+portals
  before the override and restores them when validation refuses the
  load,
  so invalid layouts never poison the in-memory Floor. Corrupt/missing
  layout = ignored with a warning, never fatal.
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
  `--struct-op=create:rx,ry:ox,oy:w,h|delete:rx,ry|vis:rx,ry:a,b|
  spawn:x,y:0|1` (x,y is a world CELL, 0 removes / 1 places) fires
  requests headless after sync. StructuralOpsSmokeTest covers
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
- Authoritative persistence (Phase D): the dedicated server is the
  only persistence owner — clients never write floor saves. Dirty
  tracking is floor-scoped: `FloorManager._dirty_floors` maps
  floor_id -> true, fed by `mark_floor_dirty(floor_id)` called from
  every mutation core (content changes via `_on_world_content_changed`
  attributed through the `_world_floor` world->floor map, struct ops,
  visibility, room create/delete, floor create). `_persist_paused`
  suppresses marking during materialize/hydrate so loading never
  dirties; `mark_floor_dirty` no-ops when `structural_edits_readonly`
  so replica applies stay clean. `save_floor_state(id)` persists ONE
  floor through the existing format — `world_for_floor` resolves the
  bound world OR the `runtime_worlds` entry, `save_room_states`
  (rooms+connections, never player_state.json) then layout.json then
  the manifest as commit marker; floors with no materialized world
  still get layout+manifest (created-but-unvisited floors). Failed
  saves keep the floor dirty. `save_all_dirty()` returns
  {saved, failed} and prunes unregistered ids. Autosave:
  `MultiplayerManager._run_autosave` fires every `_autosave_interval`
  s (`--autosave=`, default 60, 0 disables) on the dedicated server —
  synchronous, dirty-only, mid-save mutations simply re-dirty.
  Shutdown: `WorldBootstrap._exit_tree`/`WM_CLOSE_REQUEST` call
  `_net_manager.shutdown_save()` for dedicated servers (sets
  `_shutting_down`, which makes `_handle_floor_op`,
  `_handle_struct_op`, `_handle_floor_transition`, `_rpc_build_place`
  and `_rpc_build_remove` reject/ignore new mutations); single-player
  keeps `save_game()`. `save_game()` on a dedicated server delegates
  to `save_all_dirty`. Debug: `--autosave=N`, `--shutdown-after=N`
  (quits after N s so shutdown-save is testable headless).
  ServerPersistenceSmokeTest covers the D matrix.
- Neighborhood: the visible set is the primary room plus rooms within
  `spatial_neighborhood_depth` BFS hops of bounds adjacency (a room's
  `global_bounds()` grown by `neighborhood_padding` world cells must
  intersect — size- and position-aware) UNION rooms within
  `connection_neighborhood_depth` hops of the connection graph.
  `get_visible_room_coordinates()`, `get_spatial_neighbors()`,
  `spatial_distance_from_primary()`, `get_connected_room_ids()`, and
  `connection_distance_from_primary()` expose it; F3 shows counts.
- Multiplayer (Phases A–D complete — see MULTIPLAYER_STATUS.md):
  `MultiplayerManager` (`Scripts/Net/`, Node
  child of WorldBootstrap named "MultiplayerManager" — the stable RPC
  path) exists ONLY when launch args request it; no args = pure
  single-player. `-- --server` runs a dedicated ENet server (peer 1,
  headless-friendly; on a normal exit it saves every dirty floor —
  Phase D below), `-- --client[=IP] --port=N`
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
  local apply pushes a divergence warning AND still emits
  build_result(true) — the server did accept; only the replica
  drifted). Accepted results arriving while `world_synced` is false
  or a floor transition is pending QUEUE in `_pending_build_ops`
  (same pattern as `_pending_struct_ops`) and flush via
  `_flush_pending_build_ops` on join/travel/rejected-transition/
  aborted-snapshot — without this, destination-floor ops arriving
  mid-transition were dropped by the floor filter and lost forever,
  leaving the replica without supporting blocks (later stacked
  placements then fail `can_place`). `_handle_build_result` is the
  RPC-split testable entry point. All build traffic is
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
  transitions once synced; `--autosave=N` / `--shutdown-after=N`
  drive the Phase D server persistence paths headless. Known limits:
  an abrupt kill/power loss bypasses the shutdown save — autosave
  bounds the loss; saves are synchronous on the main thread; no
  movement interpolation; no auth/encryption.
