extends SceneTree

## Smoke test for the Floor architecture: Floor definitions are data,
## FloorManager materializes them into a runtime RoomWorld, floors are
## independent (rooms/connections never leak across floors), and the
## shipped example floors load correctly.

const GRID_PATH := "res://Resources/IsometricGrid/TestGrid.tres"
const TILE_CATALOG_PATH := "res://Resources/TileCatalog.tres"
const BLOCK_CATALOG_PATH := "res://Resources/BlockCatalog.tres"
const FURNITURE_CATALOG_PATH := "res://Resources/FurnitureCatalog.tres"
const CARPET_CATALOG_PATH := "res://Resources/CarpetCatalog.tres"
const BLOCK_SCENE_PATH := "res://Scenes/Objects/Block.tscn"
const SCRATCH_ROOT := "user://smoke_floor_smoke"

var _floor_manager: FloorManager
var _room_world: RoomWorld
var _frames := 0
var _failures: Array[String] = []

func _initialize() -> void:
	# User-created floors persist under FloorSaveSystem.save_root; point
	# it at a scratch dir so real user floors never leak into this test.
	FloorSaveSystem.save_root = SCRATCH_ROOT
	_remove_dir_contents(SCRATCH_ROOT)
	_floor_manager = FloorManager.new()
	_floor_manager.name = "FloorManager"
	root.add_child(_floor_manager)
	_room_world = _make_room_world()
	_floor_manager.room_world = _room_world

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
	world.hide_rooms_outside_neighborhood = false
	world.deemphasize_neighbors = false
	world.emphasis_transition_duration = 0.0
	world.room_slide_duration = 0.0
	root.add_child(world)
	return world

func _spec(room_id: Vector2i, origin: Vector2i, size: Vector2i) -> FloorRoomSpec:
	var spec := FloorRoomSpec.new()
	spec.room_id = room_id
	spec.global_origin = origin
	spec.size = size
	return spec

func _floor(id: StringName, rooms: Array, entry: Vector2i, auto_connect := true) -> Floor:
	var floor_def := Floor.new()
	floor_def.floor_id = id
	floor_def.display_name = String(id)
	floor_def.entry_room_id = entry
	floor_def.spawn_position = Vector2i(8, 8)
	floor_def.auto_connect_adjacent = auto_connect
	floor_def.rooms.assign(rooms)
	return floor_def

func _process(_delta: float) -> bool:
	_frames += 1
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

func _run_checks() -> void:
	_test_shipped_floors()
	_test_registry()
	_test_materialize_motel()
	_test_variable_rooms()
	_test_floor_isolation()
	_test_validation()

func _test_shipped_floors() -> void:
	for id in [&"motel", &"forest", &"village"]:
		var floor_def := _floor_manager.get_floor(id)
		_expect(floor_def != null, "shipped floor '%s' not registered" % id)
		if floor_def != null:
			# Motel is the ring world (12x12 center + sixteen 4x4 ring
			# rooms); forest/village are 3x3 grids of 16x16 rooms.
			var expected_rooms := 17 if id == &"motel" else 9
			var entry := Vector2i(0, 0) if id == &"motel" else Vector2i(1, 1)
			_expect(floor_def.rooms.size() == expected_rooms, "floor '%s' has %d rooms, expected %d" % [id, floor_def.rooms.size(), expected_rooms])
			_expect(floor_def.find_room_spec(entry) != null, "floor '%s' missing entry room %s" % [id, entry])
			_expect(not floor_def.display_name.is_empty(), "floor '%s' has no display name" % id)
	_expect(_floor_manager.floor_ids().size() == 3, "expected 3 shipped floors, got %d" % _floor_manager.floor_ids().size())

func _test_registry() -> void:
	var dup := _floor(&"motel", [], Vector2i.ZERO)
	_expect(not _floor_manager.register_floor(dup), "duplicate floor id accepted")
	var no_id := Floor.new()
	no_id.display_name = "Nameless"
	_expect(not _floor_manager.register_floor(no_id), "floor without id accepted")
	var custom := _floor(&"custom_test", [_spec(Vector2i(0, 0), Vector2i(0, 0), Vector2i(8, 8))], Vector2i(0, 0))
	_expect(_floor_manager.register_floor(custom), "custom floor rejected")
	_expect(_floor_manager.has_floor(&"custom_test"), "custom floor not found after register")
	_expect(_floor_manager.unregister_floor(&"custom_test"), "unregister_floor failed")
	_expect(not _floor_manager.has_floor(&"custom_test"), "unregistered floor still present")

func _test_materialize_motel() -> void:
	var motel := _floor_manager.get_floor(&"motel")
	_expect(motel != null, "motel floor missing")
	if motel == null:
		return
	_expect(_floor_manager.materialize_floor(motel), "materialize_floor failed")
	_expect(_room_world.registry.get_rooms().size() == 17, "motel materialized %d rooms, expected 17" % _room_world.registry.get_rooms().size())
	var center := _room_world.get_room(Vector2i(0, 0))
	_expect(center != null, "motel center room missing")
	if center != null:
		_expect(center.size == Vector2i(12, 12), "center room size %s != 12x12" % center.size)
		_expect(center.cell_origin == Vector2i(0, 0), "center room origin %s != (0,0)" % center.cell_origin)
	var ring := _room_world.get_room(Vector2i(5, 0))
	_expect(ring != null and ring.size == Vector2i(4, 4) and ring.cell_origin == Vector2i(12, 0),
		"ring room (5,0) wrong: %s" % (ring.global_bounds() if ring != null else "missing"))
	# Center-ring + ring-ring edge adjacency auto-connects to 28 doors.
	_expect(_room_world.connections.size() == 28, "motel has %d connections, expected 28" % _room_world.connections.size())
	_expect(_room_world.primary_room_coordinates == Vector2i(0, 0), "primary room %s != entry (0,0)" % _room_world.primary_room_coordinates)
	# Spot-check a real transition from the center's right edge into the
	# right column of ring rooms.
	var exit := _room_world.find_room_exit(center, Vector2i(11, 1), Vector2i(1, 0))
	_expect(not exit.is_empty() and exit["room_id"] == Vector2i(5, 0), "materialized exit lookup failed: %s" % str(exit))

func _test_variable_rooms() -> void:
	# A floor with an irregular room count, mixed sizes, and no
	# auto-connect proves nothing is hardcoded to 3x3/nine rooms.
	var weird := _floor(&"weird_layout", [
		_spec(Vector2i(0, 0), Vector2i(0, 0), Vector2i(8, 8)),
		_spec(Vector2i(1, 0), Vector2i(8, 0), Vector2i(16, 8)),
		_spec(Vector2i(2, 0), Vector2i(24, 0), Vector2i(4, 4)),
		_spec(Vector2i(0, 1), Vector2i(0, 8), Vector2i(12, 12)),
	], Vector2i(0, 1), false)
	_expect(_floor_manager.register_floor(weird), "irregular floor rejected")
	_expect(_floor_manager.validate_floor(weird).is_empty(), "irregular floor reported problems: %s" % str(_floor_manager.validate_floor(weird)))
	_expect(_floor_manager.materialize_floor(weird), "materialize irregular floor failed")
	_expect(_room_world.registry.get_rooms().size() == 4, "irregular floor has %d rooms, expected 4" % _room_world.registry.get_rooms().size())
	var big := _room_world.get_room(Vector2i(0, 1))
	_expect(big != null and big.size == Vector2i(12, 12), "irregular room size wrong: %s" % (big.size if big != null else "missing"))
	var tiny := _room_world.get_room(Vector2i(2, 0))
	_expect(tiny != null and tiny.size == Vector2i(4, 4), "tiny room size wrong")
	_expect(_room_world.connections.size() == 0, "auto_connect=false floor gained %d connections" % _room_world.connections.size())
	_expect(_room_world.primary_room_coordinates == Vector2i(0, 1), "irregular floor entry not applied")
	_floor_manager.unregister_floor(&"weird_layout")

func _test_floor_isolation() -> void:
	# Floor A: two rooms with an explicit connection.
	var floor_a := _floor(&"iso_a", [
		_spec(Vector2i(0, 0), Vector2i(0, 0), Vector2i(8, 8)),
		_spec(Vector2i(1, 0), Vector2i(8, 0), Vector2i(8, 8)),
	], Vector2i(0, 0), false)
	var link := RoomConnection.new()
	link.connection_id = &"iso_a_link"
	link.source_room_id = Vector2i(0, 0)
	link.destination_room_id = Vector2i(1, 0)
	link.source_cells = [Vector2i(7, 3)]
	link.destination_cells = [Vector2i(0, 3)]
	link.interactive = false
	link.bidirectional = true
	var floor_connections: Array[RoomConnection] = [link]
	floor_a.connections = floor_connections
	_floor_manager.register_floor(floor_a)
	_floor_manager.activate_floor(&"iso_a")
	_expect(_room_world.connections.size() == 1, "floor A connections = %d, expected 1" % _room_world.connections.size())
	# Floor B reuses the same room ids but is a different floor.
	var floor_b := _floor(&"iso_b", [
		_spec(Vector2i(0, 0), Vector2i(40, 40), Vector2i(8, 8)),
		_spec(Vector2i(1, 0), Vector2i(48, 40), Vector2i(8, 8)),
	], Vector2i(1, 0), false)
	_floor_manager.register_floor(floor_b)
	_floor_manager.activate_floor(&"iso_b")
	_expect(_floor_manager.active_floor == floor_b, "active floor is not iso_b")
	_expect(_room_world.registry.get_rooms().size() == 2, "floor B rooms = %d, expected 2" % _room_world.registry.get_rooms().size())
	# Floor A's rooms and connection must be gone: same room ids, different
	# origins, and zero connections (B has none and no auto-connect).
	var room := _room_world.get_room(Vector2i(0, 0))
	_expect(room != null and room.cell_origin == Vector2i(40, 40), "floor B room kept floor A origin: %s" % (room.cell_origin if room != null else "missing"))
	_expect(_room_world.connections.size() == 0, "floor A connection leaked into floor B (%d connections)" % _room_world.connections.size())
	_expect(_room_world.validate_connections().is_empty(), "floor B connections invalid")
	# Re-activating A restores its own content.
	_floor_manager.activate_floor(&"iso_a")
	_expect(_room_world.connections.size() == 1, "floor A connection not restored")
	room = _room_world.get_room(Vector2i(0, 0))
	_expect(room != null and room.cell_origin == Vector2i(0, 0), "floor A room origin wrong after re-activation")
	_floor_manager.unregister_floor(&"iso_a")
	_floor_manager.unregister_floor(&"iso_b")

func _test_validation() -> void:
	var bad := _floor(&"bad_floor", [
		_spec(Vector2i(0, 0), Vector2i(0, 0), Vector2i(8, 8)),
		_spec(Vector2i(0, 0), Vector2i(8, 0), Vector2i(8, 8)),
	], Vector2i(9, 9), false)
	var problems := _floor_manager.validate_floor(bad)
	_expect(problems.size() >= 2, "validate_floor found only %d problems: %s" % [problems.size(), str(problems)])
	_expect(_floor_manager.register_floor(bad), "invalid floor should still register (warnings only)")
	_floor_manager.unregister_floor(&"bad_floor")

func _report() -> void:
	if _failures.is_empty():
		print("FLOOR_SMOKE: OK")
	else:
		for failure in _failures:
			push_error("FLOOR_SMOKE FAIL: " + failure)
		print("FLOOR_SMOKE: FAILED (%d)" % _failures.size())
