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
BuildingCatalogSmokeTest, BuildingUiSmokeTest. Each prints
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
  always wins (explicit links may target non-adjacent rooms); when
  several connections cover one exit cell, direction disambiguates by
  destination bounds, ties break by connection id with a warning, and a
  direction no destination satisfies refuses the transition.
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
  `FloorManager.switch_floor` — no save/load logic in the UI. While open,
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
  follow, wider `editor_zoom_levels`), WASD/arrow + middle-drag pan, and
  `focus_on()`. Cursor cell = `grid.screen_to_grid(mouse world pos)` via
  `cursor_cell_for_world_position()` (injectable for headless tests).
  DebugHud adds a `Mode: CREATION` line with view + cursor cell.
  Creation Mode (Phase 2): the Create Room tool (C toggles, GRID view
  only) drags an LMB rectangle on the global grid — anchor + live cursor
  cell give an inclusive-cell Rect2i in any drag direction. Releasing
  keeps the selection; X opens a PixelUi confirmation panel (auto
  "x,y" room id, read-only, size/origin info, Create/Cancel). Preview
  colors: green valid / orange overlap / yellow isolated / red invalid
  (2..1024 cells per axis, `Floor.MIN_ROOM_DIMENSION`). New rooms must
  share an edge with an existing room (`_edges_touch` — corner contact
  doesn't count); an empty floor accepts its first room. The panel has
  two visibility checkboxes (both default on): `show_from_outside=false`
  hides the room until the player enters it, `show_outside=false` fades
  out edge-adjacent rooms' BlockLayers while it is primary — RoomVisuals
  animates both (slide for rooms, alpha fade for blocks). Flags live on
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
- Neighborhood: the visible set is the primary room plus rooms within
  `spatial_neighborhood_depth` BFS hops of bounds adjacency (a room's
  `global_bounds()` grown by `neighborhood_padding` world cells must
  intersect — size- and position-aware) UNION rooms within
  `connection_neighborhood_depth` hops of the connection graph.
  `get_visible_room_coordinates()`, `get_spatial_neighbors()`,
  `spatial_distance_from_primary()`, `get_connected_room_ids()`, and
  `connection_distance_from_primary()` expose it; F3 shows counts.
