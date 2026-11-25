extends SceneTree

## Smoke test for floor spawn points: Floor.spawn_points holds global
## world cells (1..Floor.MAX_SPAWN_POINTS, each inside a room
## footprint), spawn_points[0] mirrors entry_room_id/spawn_position,
## placement/removal is validated, layout.json persists the list,
## room deletion is refused when it would drop the floor below
## Floor.MIN_SPAWN_POINTS, and legacy floors derive a spawn point from
## entry/spawn on registration.

const GRID_PATH := "res://Resources/IsometricGrid/TestGrid.tres"
const TILE_CATALOG_PATH := "res://Resources/TileCatalog.tres"
const BLOCK_CATALOG_PATH := "res://Resources/BlockCatalog.tres"
const FURNITURE_CATALOG_PATH := "res://Resources/FurnitureCatalog.tres"
const CARPET_CATALOG_PATH := "res://Resources/CarpetCatalog.tres"
const BLOCK_SCENE_PATH := "res://Scenes/Objects/Block.tscn"
const PLAYER_SCENE_PATH := "res://Scenes/Player/Player.tscn"
const SCRATCH_ROOT := "user://smoke_spawn_saves"

var _floor_manager: FloorManager
var _room_world: RoomWorld
var _player: Player
var _frames := 0
var _failures: Array[String] = []

func _initialize() -> void:
	FloorSaveSystem.save_root = SCRATCH_ROOT
	_remove_dir_contents(SCRATCH_ROOT)
	_floor_manager = FloorManager.new()
	_floor_manager.name = "FloorManager"
	root.add_child(_floor_manager)
	_room_world = _make_room_world()
	_floor_manager.room_world = _room_world

func _setup() -> void:
	_spawn_player()
	_register_test_floors()

func _make_room_world() -> RoomWorld:
	var world := RoomWorld.new()
	world.name = "ScratchRoomWorld"
	world.grid = load(GRID_PATH) as IsometricGrid
	world.room_dimensions = Vector2i(16, 16)
	world.default_tile_id = &"floor_iso"
	world.tile_catalog = load(TILE_CATALOG_PATH) as TileCatalog
	world.block_catalog = load(BLOCK_CATALOG_PATH) as BlockCatalog
	world.furniture_catalog = load(FURNITURE_CATALOG_PATH) as FurnitureCatalog
	world.carpet_catalog = load(CARPET_CATALOG_PATH) as CarpetCatalog
	world.block_scene = load(BLOCK_SCENE_PATH) as PackedScene
	world.player_scene = load(PLAYER_SCENE_PATH) as PackedScene
	world.hide_rooms_outside_neighborhood = false
	world.deemphasize_neighbors = false
	world.emphasis_transition_duration = 0.0
	world.room_slide_duration = 0.0
	root.add_child(world)
	return world

func _spawn_player() -> void:
	var scene := load(PLAYER_SCENE_PATH) as PackedScene
	_player = scene.instantiate() as Player
	_player.grid = _room_world.grid
	_player.move_duration = 0.0
	_room_world.entity_layer.add_child(_player)

func _spec(room_id: Vector2i, origin: Vector2i, size: Vector2i) -> FloorRoomSpec:
	var spec := FloorRoomSpec.new()
	spec.room_id = room_id
	spec.global_origin = origin
	spec.size = size
	return spec

## 2x2 block of 8x8 rooms; entry (0,0) at spawn local (2,2) ->
## derived spawn cell (2,2). auto_connect=false keeps the graph empty.
func _quad_floor(id: StringName) -> Floor:
	var floor_def := Floor.new()
	floor_def.floor_id = id
	floor_def.display_name = String(id)
	floor_def.entry_room_id = Vector2i(0, 0)
	floor_def.spawn_position = Vector2i(2, 2)
	floor_def.auto_connect_adjacent = false
	floor_def.rooms.assign([
		_spec(Vector2i(0, 0), Vector2i(0, 0), Vector2i(8, 8)),
		_spec(Vector2i(1, 0), Vector2i(8, 0), Vector2i(8, 8)),
		_spec(Vector2i(0, 1), Vector2i(0, 8), Vector2i(8, 8)),
		_spec(Vector2i(1, 1), Vector2i(8, 8), Vector2i(8, 8)),
	])
	return floor_def

func _register_test_floors() -> void:
	_floor_manager.register_floor(_quad_floor(&"sp_quad"))
	# Shaped room floor: an L-shaped spec whose bbox has a hole — the
	# derived spawn must snap inside a real section cell.
	var shaped := Floor.new()
	shaped.floor_id = &"sp_shaped"
	shaped.display_name = "sp_shaped"
	shaped.entry_room_id = Vector2i(0, 0)
	shaped.spawn_position = Vector2i(5, 5)  # inside the bbox hole
	shaped.auto_connect_adjacent = false
	var l_spec := FloorRoomSpec.new()
	l_spec.room_id = Vector2i(0, 0)
	l_spec.shape_sections = [Rect2i(0, 0, 8, 4), Rect2i(0, 4, 4, 4)]
	l_spec.global_origin = Vector2i.ZERO
	l_spec.size = Vector2i(8, 8)
	shaped.rooms.assign([l_spec])
	_floor_manager.register_floor(shaped)
	# Two-spawn floor for the random-entry check: spawn_points are
	# GLOBAL cells — (1,1) inside room (0,0), (10,3) inside (1,0).
	# [0] mirrors entry (0,0) + local spawn (1,1) -> global (1,1).
	var rand := _quad_floor(&"sp_rand")
	rand.spawn_position = Vector2i(1, 1)  # mirrors spawn_points[0] (1,1)
	rand.spawn_points = [Vector2i(1, 1), Vector2i(10, 3)]
	_floor_manager.register_floor(rand)

func _process(_delta: float) -> bool:
	_frames += 1
	if _frames == 1:
		_setup()
	if _frames < 6:
		return false
	_run_checks()
	_report()
	quit()
	return true

func _remove_dir_contents(path: String) -> void:
	var dir := DirAccess.open(path)
	if dir == null:
		return
	for file_name in dir.get_files():
		dir.remove(file_name)
	for sub in dir.get_directories():
		_remove_dir_contents(path.path_join(sub))
		DirAccess.remove_absolute(path.path_join(sub))

func _expect(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)

func _active_floor() -> Floor:
	return _floor_manager.active_floor

func _spawns() -> Array[Vector2i]:
	return _floor_manager.floor_spawn_points(_active_floor())

func _test_derive_and_normalize() -> void:
	# sp_quad registered without spawn_points: entry (0,0) + spawn
	# local (2,2) -> global cell (2,2) inside room (0,0).
	var quad := _floor_manager.get_floor(&"sp_quad")
	_expect(quad.spawn_points == [Vector2i(2, 2)],
		"quad spawn_points not derived: %s" % str(quad.spawn_points))
	var shaped := _floor_manager.get_floor(&"sp_shaped")
	_expect(shaped.spawn_points.size() == 1,
		"shaped floor has %d spawn points" % shaped.spawn_points.size())
	var shaped_cell: Vector2i = shaped.spawn_points[0]
	# Local (5,5) is the bbox hole; the point must land inside a
	# section (the vertical bar x<4 or top bar y<4).
	var inside := (shaped_cell.x < 4 and shaped_cell.y < 8) \
		or (shaped_cell.x < 8 and shaped_cell.y < 4)
	_expect(inside, "shaped spawn %s not snapped inside a section" % shaped_cell)
	# Entry mirrors spawn_points[0] after normalization.
	_expect(shaped.entry_room_id == Vector2i(0, 0), "shaped entry drifted")

func _test_validate() -> void:
	var bad := _quad_floor(&"sp_bad")
	bad.spawn_points = [Vector2i(100, 100)]
	var problems := _floor_manager.validate_floor(bad)
	var flagged := false
	for problem in problems:
		if "spawn point" in problem:
			flagged = true
	_expect(flagged, "validate_floor did not flag out-of-room spawn: %s" % problems)
	var empty := _quad_floor(&"sp_empty")
	empty.spawn_points = []
	# validate_floor sees the raw (empty) list — normalization happens
	# at registration, so the empty-list problem must surface.
	problems = _floor_manager.validate_floor(empty)
	flagged = false
	for problem in problems:
		if "no spawn points" in problem:
			flagged = true
	_expect(flagged, "validate_floor did not flag missing spawn points: %s" % problems)
	var over := _quad_floor(&"sp_over")
	over.spawn_points = [Vector2i(1, 1), Vector2i(2, 2), Vector2i(3, 3),
		Vector2i(4, 4), Vector2i(5, 5)]
	problems = _floor_manager.validate_floor(over)
	flagged = false
	for problem in problems:
		if "max" in problem:
			flagged = true
	_expect(flagged, "validate_floor did not flag >4 spawn points: %s" % problems)

func _test_place_remove() -> void:
	_expect(_floor_manager.switch_floor(&"sp_quad"), "switch to sp_quad failed")
	var quad := _active_floor()
	_expect(_spawns() == [Vector2i(2, 2)], "quad spawn list wrong: %s" % str(_spawns()))

	# Refusals: outside any room, duplicate cell, then fill to max.
	_expect(not bool(_floor_manager.can_place_spawn_point(Vector2i(100, 100)).get("allowed", false)),
		"spawn outside rooms allowed")
	_expect(not bool(_floor_manager.can_place_spawn_point(Vector2i(2, 2)).get("allowed", false)),
		"duplicate spawn cell allowed")
	# Room (1,0) spans global x 8..15, y 0..7 — pick interior cells.
	_expect(_floor_manager.place_spawn_point(Vector2i(10, 3)), "place spawn (10,3) failed")
	_expect(_floor_manager.place_spawn_point(Vector2i(3, 10)), "place spawn (3,10) failed")
	_expect(_floor_manager.place_spawn_point(Vector2i(12, 12)), "place spawn (12,12) failed")
	_expect(_spawns().size() == Floor.MAX_SPAWN_POINTS,
		"expected %d spawns, got %s" % [Floor.MAX_SPAWN_POINTS, _spawns()])
	_expect(not bool(_floor_manager.can_place_spawn_point(Vector2i(9, 9)).get("allowed", false)),
		"5th spawn point allowed")

	# First point still mirrors entry/spawn.
	_expect(quad.spawn_points[0] == Vector2i(2, 2), "spawn_points[0] drifted")
	_expect(quad.entry_room_id == Vector2i(0, 0), "entry drifted after places")
	_expect(quad.spawn_position == Vector2i(2, 2), "spawn_position drifted")

	# Remove back down to the minimum; the last one refuses.
	_expect(_floor_manager.remove_spawn_point(Vector2i(12, 12)), "remove (12,12) failed")
	_expect(_floor_manager.remove_spawn_point(Vector2i(3, 10)), "remove (3,10) failed")
	_expect(_floor_manager.remove_spawn_point(Vector2i(10, 3)), "remove (10,3) failed")
	_expect(_spawns() == [Vector2i(2, 2)], "spawns not back to minimum: %s" % str(_spawns()))
	_expect(not bool(_floor_manager.can_remove_spawn_point(Vector2i(2, 2)).get("allowed", false)),
		"removing the last spawn point allowed")
	_expect(not _floor_manager.remove_spawn_point(Vector2i(2, 2)), "last spawn removal succeeded")
	_expect(not bool(_floor_manager.can_remove_spawn_point(Vector2i(50, 50)).get("allowed", false)),
		"removing a non-existent spawn allowed")

func _test_entry_resync() -> void:
	# Two spawns: entry's (2,2) and one in room (1,1) at global
	# (10,10) -> local (2,2) of that room. Removing the FIRST point
	# must re-point entry_room_id/spawn_position at the survivor.
	_expect(_floor_manager.place_spawn_point(Vector2i(10, 10)), "place (10,10) failed")
	_expect(_floor_manager.remove_spawn_point(Vector2i(2, 2)), "remove entry spawn failed")
	var quad := _active_floor()
	_expect(_spawns() == [Vector2i(10, 10)], "surviving spawn wrong: %s" % str(_spawns()))
	_expect(quad.entry_room_id == Vector2i(1, 1),
		"entry did not resync to spawn room: %s" % quad.entry_room_id)
	_expect(quad.spawn_position == Vector2i(2, 2),
		"spawn_position did not resync: %s" % quad.spawn_position)
	# Restore the original entry spawn for the persistence test: place
	# (2,2) alongside (10,10), then remove (10,10) — removing the last
	# spawn outright is refused by the minimum rule.
	_expect(_floor_manager.place_spawn_point(Vector2i(2, 2)), "re-place (2,2) failed")
	_expect(_floor_manager.remove_spawn_point(Vector2i(10, 10)), "remove (10,10) failed")
	var restored := _active_floor()
	_expect(restored.entry_room_id == Vector2i(0, 0) and restored.spawn_position == Vector2i(2, 2),
		"entry/spawn not restored: %s @ %s" % [restored.entry_room_id, restored.spawn_position])

func _test_persistence() -> void:
	# Add a second spawn so the saved list is non-trivial, then save
	# and reload the floor — layout.json must carry spawn_points and
	# the reload must restore them with entry synced to [0].
	_expect(_floor_manager.place_spawn_point(Vector2i(10, 3)), "place for save failed")
	_expect(_floor_manager.save_active_floor(), "save_active_floor failed")
	var layout := FloorSaveSystem.load_layout(&"sp_quad")
	var saved_cells: Array = layout.get("spawn_points", [])
	_expect(saved_cells.size() == 2, "layout.json spawn_points size %d" % saved_cells.size())
	_expect(FileAccess.file_exists(FloorSaveSystem.layout_path(&"sp_quad")), "layout.json missing")

	var quad := _active_floor()
	quad.spawn_points = [Vector2i(2, 2)]  # simulate stale in-memory state
	_expect(_floor_manager.load_floor(&"sp_quad"), "reload sp_quad failed")
	var reloaded := _active_floor()
	_expect(reloaded.spawn_points.size() == 2,
		"reloaded spawn_points size %d" % reloaded.spawn_points.size())
	_expect(reloaded.spawn_points.has(Vector2i(10, 3)),
		"reloaded spawn_points missing (10,3): %s" % str(reloaded.spawn_points))
	_expect(reloaded.entry_room_id == Vector2i(0, 0), "reloaded entry wrong")

func _test_delete_guard() -> void:
	# quad is active with spawns [(2,2)@(0,0), (10,3)@(1,0)]. Move the
	# player out of room (0,0) so occupancy doesn't mask the spawn rule.
	_player.room = _room_world.get_room(Vector2i(1, 0))
	# Room (0,0) holds spawn (2,2); deleting it leaves only (10,3) —
	# allowed (>= MIN remains). Entry falls back + resyncs.
	var verdict := _floor_manager.can_delete_room(Vector2i(0, 0))
	_expect(bool(verdict.get("allowed", false)),
		"delete of spawn room refused with 2 spawns: %s" % verdict.get("reason"))
	# Remove the (1,0) spawn first: now (0,0)'s spawn is the only one —
	# deleting its room must be refused by the spawn rule specifically.
	_expect(_floor_manager.remove_spawn_point(Vector2i(10, 3)), "remove (10,3) failed")
	verdict = _floor_manager.can_delete_room(Vector2i(0, 0))
	_expect(not bool(verdict.get("allowed", false)),
		"delete of sole-spawn room allowed")
	_expect("spawn" in str(verdict.get("reason", "")),
		"refusal reason is not the spawn rule: %s" % verdict.get("reason"))
	# Restore: put the second spawn back and delete (0,0) for real —
	# the floor must keep >=1 spawn and re-point entry at the survivor.
	_expect(_floor_manager.place_spawn_point(Vector2i(10, 3)), "re-place (10,3) failed")
	_expect(_floor_manager.remove_room_from_active_floor(Vector2i(0, 0)),
		"delete of spawn room with 2 spawns failed")
	var quad := _active_floor()
	_expect(quad.spawn_points == [Vector2i(10, 3)],
		"spawn_points not pruned on room delete: %s" % str(quad.spawn_points))
	_expect(quad.find_room_spec(Vector2i(0, 0)) == null, "room (0,0) spec survived")
	_expect(quad.entry_room_id == Vector2i(1, 0),
		"entry not resynced after spawn-room delete: %s" % quad.entry_room_id)
	_expect(quad.spawn_position == Vector2i(2, 3),
		"spawn_position not resynced: %s" % quad.spawn_position)
	# layout.json reflects the pruned list.
	var layout := FloorSaveSystem.load_layout(&"sp_quad")
	_expect((layout.get("spawn_points", []) as Array).size() == 1,
		"layout.json spawn_points not pruned")

func _test_random_spawn() -> void:
	# First visit (no saved player state): the player must land on ONE
	# of the floor's spawn points — never outside them.
	_expect(_floor_manager.load_floor(&"sp_rand"), "load sp_rand failed")
	var room_id := _player.room.room_coordinates if _player.room != null else Vector2i(-999, -999)
	var pos := _player.grid_position
	var on_first := room_id == Vector2i(0, 0) and pos == Vector2i(1, 1)
	var on_second := room_id == Vector2i(1, 0) and pos == Vector2i(2, 3)
	_expect(on_first or on_second,
		"player spawned outside spawn points: room %s @ %s" % [room_id, pos])
	# The floor's spawn list itself is untouched by placement.
	var rand := _floor_manager.get_floor(&"sp_rand")
	_expect(rand.spawn_points == [Vector2i(1, 1), Vector2i(10, 3)],
		"spawn_points mutated by placement: %s" % str(rand.spawn_points))

func _test_replica_apply() -> void:
	# Clients apply accepted spawn ops through replica_apply_spawn —
	# unguarded, no persistence, deterministic append/erase.
	var quad := _floor_manager.get_floor(&"sp_quad")
	var before: Array[Vector2i] = quad.spawn_points.duplicate()
	_expect(_floor_manager.replica_apply_spawn(&"sp_quad", Vector2i(11, 11), true),
		"replica place failed")
	_expect(quad.spawn_points.size() == before.size() + 1, "replica place did not append")
	_expect(_floor_manager.replica_apply_spawn(&"sp_quad", Vector2i(11, 11), false),
		"replica remove failed")
	_expect(quad.spawn_points == before, "replica remove did not restore: %s" % str(quad.spawn_points))
	_expect(not _floor_manager.replica_apply_spawn(&"sp_nope", Vector2i(1, 1), true),
		"replica apply on unknown floor succeeded")
	# Replica apply must not mark the floor dirty or write layout.json.
	var layout := FloorSaveSystem.load_layout(&"sp_quad")
	_expect((layout.get("spawn_points", []) as Array).size() == 1,
		"replica apply leaked into layout.json")

func _run_checks() -> void:
	if not _floor_manager.switch_floor(&"sp_shaped"):
		_failures.append("switch to sp_shaped failed")
	_test_derive_and_normalize()
	_test_validate()
	_test_place_remove()
	_test_entry_resync()
	_test_persistence()
	_test_delete_guard()
	_test_random_spawn()
	_test_replica_apply()

func _report() -> void:
	if _failures.is_empty():
		print("SPAWN_POINT_SMOKE: OK")
	else:
		for failure in _failures:
			printerr("SPAWN_POINT_SMOKE FAIL: " + failure)
		printerr("SPAWN_POINT_SMOKE: %d failure(s)" % _failures.size())
