# Miau Motel — Agent Notes

Godot 4.7 project (GDScript). Isometric 64×32 tiles via `IsometricGrid` resource.

## Running tests headless

Godot binary: `C:\Users\Mauro\Downloads\Godot_v4.7.2-stable_win64.exe\Godot_v4.7.2-stable_win64_console.exe`

```
godot --headless --path <project> -s res://Scripts/Test/<TestName>.gd
```

Smoke tests (SceneTree scripts in `Scripts/Test/`): PrototypeSmokeTest,
PlayerCollisionSmokeTest, CameraSmokeTest, PlayerDirectionSmokeTest,
RoomWorldSmokeTest, RoomTransitionSmokeTest, MainRoomWorldSmokeTest,
TileSmokeTest, CarpetSmokeTest, BuildingCatalogSmokeTest,
BuildingUiSmokeTest, RoomLayoutSmokeTest, RoomConnectionSmokeTest,
RoomNeighborhoodSmokeTest. Each prints `<NAME>_SMOKE: OK`.

## World architecture

- `Room` owns a local cell grid (`size`, `cells`) starting at local (0,0).
- `Room.cell_origin` (= `global_origin`) is the room's origin in the shared
  world cell grid; `world_cell = cell_origin + local_cell`.
- `RoomWorld` registers rooms by unique `room_coordinates` ID via
  `register_room_at(room, id, global_origin)` / `create_room_at(...)`.
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
  coordinates only) plus `player_state.json`. `global_origin` is stored in
  each room save for reference; layout position is owned by registration.
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
- Neighborhood: the visible set is the primary room plus rooms within
  `spatial_neighborhood_depth` BFS hops of bounds adjacency (a room's
  `global_bounds()` grown by `neighborhood_padding` world cells must
  intersect — size- and position-aware) UNION rooms within
  `connection_neighborhood_depth` hops of the connection graph.
  `get_visible_room_coordinates()`, `get_spatial_neighbors()`,
  `spatial_distance_from_primary()`, `get_connected_room_ids()`, and
  `connection_distance_from_primary()` expose it; F3 shows counts.
