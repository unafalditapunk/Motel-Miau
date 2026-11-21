# Miau Motel — Integration Review

Date: 2026-11-20. Scope: full prototype review (no new gameplay features).

## Systems reviewed

1. **Isometric coordinate conversion** — `IsoMath.gd` (static, 64×32) and `IsometricGrid.gd` (resource, configurable + elevation + origin/offset). Round-trip verified for all cells; math is correct and consistent.
2. **Room and grid generation** — `Room.gd`/`RoomCell.gd`/`RoomFloorRenderer.gd` build cells and draw the floor. `BlockLayer.gd` owns block occupancy.
3. **Floor rendering** — `RoomFloorRenderer` draws one diamond per cell centered on `grid_to_screen` (cell center). Consistent with tiles/furniture/player anchoring.
4. **Block placement and stacking** — `BlockLayer.can_place`/`place_block` enforce bounds, solid overlap via z-intervals, and support (`requires_support`). Verified by tests.
5. **Depth sorting** — `depth_for_cell = (x+y)*128 + y*16 + round(elevation)`; blocks and player share the same formula through `BlockLayer`. Painter's order is correct for the prototype.
6. **Player positioning** — origin at cell center; sprite bottom-anchored via `sprite_bottom_offset` (export, default 8.0).
7. **Grid-based movement** — cardinal steps, input buffering, smooth lerp, facing animations.
8. **Collision detection** — grid-based (`can_actor_stand`/`can_actor_occupy`); physics shapes exist but movement never uses `move_and_slide`.
9. **Elevation** — `height_pixels_per_unit = 32`; blocks raise surface elevation; player `stand_elevation_at` reads block tops.
10. **Camera** — `WorldCamera.gd` follows the player group, zoom levels 1×/2×/3× via wheel/+/-.

## Fixes applied

- **`World.gd::_spawn_player`** — player was spawned with `grid = null` and default `room_size = 10`, so grid functions were dead and bounds didn't match the 8×8 room. Now assigns a default `IsometricGrid` (matches `IsoMath` constants), `room_size`, `grid_position`, and `elevation` before `add_child`.
- **`Player.gd::_configure_collision`** — collision diamond was shifted 16px up (spanned y `-32..0` relative to cell center, missing the front half of the cell). Now matches the cell footprint diamond (±16px vertically).
- **`Player.gd::next_move_target()`** — new public getter exposing the buffered move destination (used by the debug overlay).

## Known limitations (documented, not changed)

- **Elevation climbing is step-limited** — `movement_elevation_for` returns the cell's surface elevation and `can_move_to` rejects targets more than `max_step_height` (default 1.0 = one block) above/below the player's current elevation. Standing on a raised surface additionally requires `BlockLayer.is_standable_surface`, i.e. the blocks forming that surface must have `walkable = true` (standard blocks and crates do; furniture does not).
- **Two coordinate systems** — `IsoMath` (static, no offset/elevation) vs `IsometricGrid` (resource). `World.gd`/`Furniture.gd` use `IsoMath`; `Player`/`BlockLayer`/`Room` use `IsometricGrid`. They agree only because `TestGrid.tres` uses the same 64×32 constants and zero origin. If a grid with different tile size/offset is introduced, World-space objects must migrate to `IsometricGrid`.
- **`Room` occupancy API is unused by gameplay** — `RoomCell.walkable/occupied` are never synced with `BlockLayer`. Room currently only renders the floor (and optional coordinate labels via `debug_coordinates`).
- **Furniture does not block movement** — furniture is visual only; no occupancy registration.
- **Player physics collision is decorative** — movement is grid-based; `CollisionShape2D` exists for future physics use.
- **`BlockLayer._ready` forces `y_sort_enabled = false`** — scene-level `y_sort_enabled = true` settings (e.g. CollisionTest) are overridden; z_index is the single depth mechanism.

## Debug mode

`Scripts/Debug/DebugOverlay.gd` — added to `VisualStyleTest.tscn` as `DebugOverlay`.

- **Toggle**: `F3` (configurable via `toggle_key` export).
- **Shows**: per-cell grid coordinates, occupied cells (orange), block id/position/z-range labels, player cell highlight (green), buffered move destination (magenta "dest"), and a HUD with player cell, elevation, facing, move state, block/occupancy counts.
- Renders at `z_index = 4096` (max allowed) with `z_as_relative = false` so it draws above all blocks.

## Automated tests

`Scripts/Test/PrototypeSmokeTest.gd` (SceneTree script) — loads `VisualStyleTest.tscn` and checks:

- Grid round-trip conversions, known `grid_to_screen` values, elevation offset, bounds.
- Block placement: occupancy registration, overlap/bounds/support rejection, stack-top placement, remove.
- Player movement: bounds, block blocking, `move_to` success/failure, surface elevation.
- Depth ordering monotonicity (x, y, elevation).

Run all tests headless:

```
godot --headless --path <project> -s res://Scripts/Test/PrototypeSmokeTest.gd
godot --headless --path <project> -s res://Scripts/Test/PlayerCollisionSmokeTest.gd
godot --headless --path <project> -s res://Scripts/Test/CameraSmokeTest.gd
godot --headless --path <project> -s res://Scripts/Test/PlayerDirectionSmokeTest.gd
```

## Verification

- `PROTOTYPE_SMOKE: OK`
- `PLAYER_COLLISION_SMOKE: OK`
- `CAMERA_SMOKE: OK`
- `PLAYER_DIRECTION_SMOKE: OK`
- Main scene (`Main.tscn` → `VisualStyleTest.tscn`) runs 60 frames headless with no errors.
- `World.tscn` runs 60 frames headless with no errors.
