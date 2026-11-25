extends SceneTree

## Smoke test for floor management: creating floors (unique id, display
## name, initial layout, independent user:// definition + save data),
## rejecting duplicate/invalid ids, deleting floors (never the last
## one, safely while active), switching between created floors with
## independent contents, and retaining the floor list across a
## simulated restart. All saves redirect to a scratch root.

const GRID_PATH := "res://Resources/IsometricGrid/TestGrid.tres"
const TILE_CATALOG_PATH := "res://Resources/TileCatalog.tres"
const BLOCK_CATALOG_PATH := "res://Resources/BlockCatalog.tres"
const FURNITURE_CATALOG_PATH := "res://Resources/FurnitureCatalog.tres"
const CARPET_CATALOG_PATH := "res://Resources/CarpetCatalog.tres"
const BLOCK_SCENE_PATH := "res://Scenes/Objects/Block.tscn"
const PLAYER_SCENE_PATH := "res://Scenes/Player/Player.tscn"
const SCRATCH_ROOT := "user://smoke_floor_mgmt"

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
	# _ready is deferred until the first frame in SceneTree scripts, so
	# the player spawn and floor creation happen in _process.

func _setup() -> void:
	_spawn_player()
	_run_checks()

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

func _process(_delta: float) -> bool:
	_frames += 1
	if _frames == 1:
		_setup()
	if _frames < 6:
		return false
	_report()
	quit()
	return true

func _active_room_count() -> int:
	return _room_world.registry.get_rooms().size()

func _place_block(room: Room, cell: Vector2i) -> void:
	var def: BlockDefinition = _room_world.block_catalog.get_definition(&"standard_block")
	if def == null or room == null or room.block_layer == null:
		_failures.append("cannot place test block")
		return
	room.block_layer.place_block(def, cell, 0.0)

func _run_checks() -> void:
	_test_create_floor()
	_test_switch_and_independence()
	_test_delete_floors()
	_test_restart_retention()
	_test_last_floor_protection()

func _test_create_floor() -> void:
	# Two-room floor with an explicit entry/spawn derived from spec 0.
	var specs: Array[FloorRoomSpec] = [
		_spec(Vector2i(0, 0), Vector2i(0, 0), Vector2i(8, 8)),
		_spec(Vector2i(1, 0), Vector2i(8, 0), Vector2i(8, 8)),
	]
	var floor_a := _floor_manager.create_floor(&"mgmt_a", "Floor A", specs)
	_expect(floor_a != null, "create_floor mgmt_a returned null")
	if floor_a == null:
		return
	_expect(_floor_manager.has_floor(&"mgmt_a"), "mgmt_a not registered")
	_expect(floor_a.display_name == "Floor A", "display name not stored")
	_expect(floor_a.rooms.size() == 2, "mgmt_a spec count = %d, expected 2" % floor_a.rooms.size())
	_expect(floor_a.entry_room_id == Vector2i(0, 0), "entry room not derived from first spec")
	_expect(floor_a.spawn_position == Vector2i(4, 4), "spawn %s != center (4,4)" % floor_a.spawn_position)
	_expect(FileAccess.file_exists(FloorSaveSystem.floor_def_path(&"mgmt_a")), "floor_def.json missing")

	# A single-room floor for delete/independence checks.
	var specs_b: Array[FloorRoomSpec] = [_spec(Vector2i(5, 5), Vector2i(40, 40), Vector2i(6, 6))]
	_expect(_floor_manager.create_floor(&"mgmt_b", "", specs_b) != null, "create_floor mgmt_b failed")
	var floor_b := _floor_manager.get_floor(&"mgmt_b")
	_expect(floor_b != null and floor_b.display_name == "mgmt_b", "empty display name should fall back to id")

	# Empty spec list -> default 8x8 room, still enterable.
	_expect(_floor_manager.create_floor(&"mgmt_c", "Floor C") != null, "create_floor mgmt_c failed")
	var floor_c := _floor_manager.get_floor(&"mgmt_c")
	_expect(floor_c != null and floor_c.rooms.size() == 1, "mgmt_c should get a default room")

	# Rejections: duplicate id, path-unsafe id, empty id.
	_expect(_floor_manager.create_floor(&"mgmt_a", "dup") == null, "duplicate floor id accepted")
	_expect(_floor_manager.create_floor(&"bad/id", "bad") == null, "path-unsafe floor id accepted")
	_expect(_floor_manager.create_floor(&"", "bad") == null, "empty floor id accepted")
	_expect(_floor_manager.create_floor(&"motel", "shadow") == null, "created floor shadowed shipped id")

func _test_switch_and_independence() -> void:
	# Enter mgmt_a: two rooms materialize, player at derived spawn.
	_expect(_floor_manager.switch_floor(&"mgmt_a"), "switch to mgmt_a failed")
	_expect(_floor_manager.active_floor != null and _floor_manager.active_floor.floor_id == &"mgmt_a", "mgmt_a not active")
	_expect(_active_room_count() == 2, "mgmt_a has %d rooms, expected 2" % _active_room_count())
	_expect(_player.room != null and _player.room.room_coordinates == Vector2i(0, 0), "mgmt_a player room wrong")
	_expect(_player.grid_position == Vector2i(4, 4), "mgmt_a spawn %s != (4,4)" % _player.grid_position)

	# Place content, then move the player so its state must persist.
	var room_a := _room_world.get_room(Vector2i(0, 0))
	_place_block(room_a, Vector2i(4, 4))
	_player.place_at(Vector2i(5, 5), _player.stand_elevation_at(Vector2i(5, 5)))

	# mgmt_b shares no room ids with mgmt_a and must start empty.
	_expect(_floor_manager.switch_floor(&"mgmt_b"), "switch mgmt_a->mgmt_b failed")
	_expect(_active_room_count() == 1, "mgmt_b has %d rooms, expected 1" % _active_room_count())
	var room_b := _room_world.get_room(Vector2i(5, 5))
	_expect(room_b != null and room_b.block_layer != null and room_b.block_layer.blocks.is_empty(),
		"mgmt_b inherited mgmt_a content")
	_expect(_player.grid_position == Vector2i(3, 3), "mgmt_b spawn %s != center (3,3)" % _player.grid_position)

	# Back to mgmt_a: block restored; the player re-spawns at the
	# floor's spawn point — saved player_state no longer resumes.
	_expect(_floor_manager.switch_floor(&"mgmt_a"), "switch mgmt_b->mgmt_a failed")
	room_a = _room_world.get_room(Vector2i(0, 0))
	_expect(room_a != null and room_a.block_layer != null and room_a.block_layer.blocks.size() == 1,
		"mgmt_a block not restored")
	_expect(_player.grid_position == Vector2i(4, 4), "mgmt_a respawn %s != spawn (4,4)" % _player.grid_position)

func _test_delete_floors() -> void:
	# mgmt_a is active; mgmt_b and mgmt_c are not.
	_expect(_floor_manager.delete_floor(&"mgmt_c"), "delete non-active mgmt_c failed")
	_expect(not _floor_manager.has_floor(&"mgmt_c"), "mgmt_c still registered")
	_expect(not DirAccess.dir_exists_absolute(FloorSaveSystem.floor_dir(&"mgmt_c")),
		"mgmt_c save dir still exists")
	_expect(not _floor_manager.delete_floor(&"nonexistent"), "deleting unknown floor succeeded")

	# Delete the ACTIVE floor: the manager must travel elsewhere first,
	# leaving a consistent world on the fallback floor.
	var rooms_before := _active_room_count()
	_expect(_floor_manager.delete_floor(&"mgmt_a"), "delete active mgmt_a failed")
	_expect(not _floor_manager.has_floor(&"mgmt_a"), "mgmt_a still registered")
	_expect(_floor_manager.active_floor != null and _floor_manager.active_floor.floor_id != &"mgmt_a",
		"mgmt_a still active after delete")
	_expect(not DirAccess.dir_exists_absolute(FloorSaveSystem.floor_dir(&"mgmt_a")),
		"mgmt_a save dir still exists")
	_expect(_active_room_count() == _floor_manager.active_floor.rooms.size(),
		"world rooms (%d) != fallback floor specs (%d)" % [_active_room_count(), _floor_manager.active_floor.rooms.size()])
	_expect(_player.room != null and _player.room.is_inside_tree(), "player left dangling after active-floor delete")
	_expect(rooms_before == 2, "sanity: mgmt_a had 2 rooms before delete")

func _test_restart_retention() -> void:
	# Round-trip an explicit connection through floor_def.json first.
	var floor_b_live := _floor_manager.get_floor(&"mgmt_b")
	if floor_b_live == null:
		_failures.append("mgmt_b missing before restart check")
		return
	var link := RoomConnection.new()
	link.connection_id = &"mgmt_b_link"
	link.source_room_id = Vector2i(5, 5)
	link.destination_room_id = Vector2i(5, 5)
	link.source_cells = [Vector2i(0, 0)]
	link.destination_cells = [Vector2i(1, 0)]
	link.interactive = true
	var links: Array[RoomConnection] = [link]
	floor_b_live.connections = links
	_expect(FloorSaveSystem.save_floor_definition(floor_b_live) == OK, "re-save mgmt_b definition failed")

	# Simulate a restart: a fresh FloorManager scanning the same save
	# root must rediscover the surviving created floors — and only
	# those (mgmt_c/mgmt_a were deleted).
	var mgr2 := FloorManager.new()
	mgr2._load_floor_resources()
	mgr2._load_saved_floor_definitions()
	_expect(mgr2.has_floor(&"mgmt_b"), "mgmt_b lost across restart")
	_expect(not mgr2.has_floor(&"mgmt_a"), "deleted mgmt_a resurrected")
	_expect(not mgr2.has_floor(&"mgmt_c"), "deleted mgmt_c resurrected")
	var floor_b := mgr2.get_floor(&"mgmt_b")
	_expect(floor_b != null and floor_b.rooms.size() == 1, "mgmt_b spec count wrong after restart")
	_expect(floor_b != null and floor_b.rooms[0].room_id == Vector2i(5, 5), "mgmt_b room id wrong after restart")
	_expect(floor_b != null and floor_b.connections.size() == 1, "mgmt_b connection not restored")
	if floor_b != null and floor_b.connections.size() == 1:
		var restored := floor_b.connections[0]
		_expect(restored != null and restored.connection_id == &"mgmt_b_link"
			and restored.interactive and restored.source_cells == [Vector2i(0, 0)]
			and restored.destination_cells == [Vector2i(1, 0)],
			"mgmt_b connection fields wrong after restart")
	# Shipped floors still load alongside.
	_expect(mgr2.has_floor(&"motel"), "shipped motel floor missing after restart")

func _test_last_floor_protection() -> void:
	# Reduce to a single floor and verify deletion is refused.
	var keep: Floor = null
	for floor_def in _floor_manager.floors:
		keep = floor_def
		break
	for floor_def in _floor_manager.floors.duplicate():
		if floor_def != keep:
			_floor_manager.unregister_floor(floor_def.floor_id)
	_expect(_floor_manager.floors.size() == 1, "setup: expected 1 floor, have %d" % _floor_manager.floors.size())
	var verdict := _floor_manager.can_delete_floor(keep.floor_id)
	_expect(not verdict.get("allowed", true), "last floor reported deletable")
	_expect(not _floor_manager.delete_floor(keep.floor_id), "last floor was deleted")
	_expect(_floor_manager.has_floor(keep.floor_id), "last floor unregistered anyway")

func _report() -> void:
	if _failures.is_empty():
		print("FLOOR_MANAGEMENT_SMOKE: OK")
	else:
		print("FLOOR_MANAGEMENT_SMOKE: FAILED (%d)" % _failures.size())
		for failure in _failures:
			print("  FAIL: %s" % failure)
