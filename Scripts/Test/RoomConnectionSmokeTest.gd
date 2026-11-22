extends SceneTree

## Smoke test for the RoomConnection graph: explicit spatial and
## interactive connections between differently sized rooms, validation,
## player transitions through connections, and connection persistence.

const GRID_PATH := "res://Resources/IsometricGrid/TestGrid.tres"
const TILE_CATALOG_PATH := "res://Resources/TileCatalog.tres"
const BLOCK_CATALOG_PATH := "res://Resources/BlockCatalog.tres"
const FURNITURE_CATALOG_PATH := "res://Resources/FurnitureCatalog.tres"
const CARPET_CATALOG_PATH := "res://Resources/CarpetCatalog.tres"
const BLOCK_SCENE_PATH := "res://Scenes/Objects/Block.tscn"
const PLAYER_SCENE_PATH := "res://Scenes/Player/Player.tscn"

const LAYOUT := {
	Vector2i(0, 0): {"origin": Vector2i(0, 0), "size": Vector2i(16, 16)},    # A
	Vector2i(1, 0): {"origin": Vector2i(16, 0), "size": Vector2i(32, 16)},   # B
	Vector2i(2, 1): {"origin": Vector2i(48, 4), "size": Vector2i(8, 8)},     # C
	Vector2i(3, 3): {"origin": Vector2i(60, 20), "size": Vector2i(16, 24)},  # D
}

var _room_world: RoomWorld
var _grid: IsometricGrid
var _player: Player
var _frames := 0
var _failures: Array[String] = []

func _initialize() -> void:
	_grid = load(GRID_PATH) as IsometricGrid
	_room_world = RoomWorld.new()
	_room_world.name = "RoomWorld"
	_room_world.grid = _grid
	_room_world.room_dimensions = Vector2i(16, 16)
	_room_world.default_tile_id = &"floor_iso"
	_room_world.tile_catalog = load(TILE_CATALOG_PATH) as TileCatalog
	_room_world.block_catalog = load(BLOCK_CATALOG_PATH) as BlockCatalog
	_room_world.furniture_catalog = load(FURNITURE_CATALOG_PATH) as FurnitureCatalog
	_room_world.carpet_catalog = load(CARPET_CATALOG_PATH) as CarpetCatalog
	_room_world.block_scene = load(BLOCK_SCENE_PATH) as PackedScene
	_room_world.player_scene = load(PLAYER_SCENE_PATH) as PackedScene
	_room_world.hide_rooms_outside_neighborhood = false
	_room_world.deemphasize_neighbors = false
	_room_world.emphasis_transition_duration = 0.0
	_room_world.room_slide_duration = 0.0
	root.add_child(_room_world)
	for room_id in LAYOUT:
		var entry: Dictionary = LAYOUT[room_id]
		_room_world.create_room_at(room_id, entry["origin"], entry["size"])

func _process(_delta: float) -> bool:
	_frames += 1
	if _player == null and _room_world.entity_layer != null:
		_spawn_player()
	if _frames < 6:
		return false
	_run_checks()
	_report()
	quit()
	return true

func _spawn_player() -> void:
	var room_a := _room_world.get_room(Vector2i(0, 0))
	if room_a == null or _room_world.player_scene == null:
		return
	_player = _room_world.player_scene.instantiate() as Player
	_player.grid = _room_world.grid
	_player.block_layer = room_a.block_layer
	_player.room = room_a
	_player.room_size = room_a.size
	_player.place_at(Vector2i(6, 6), 0.0)
	_player.move_duration = 0.0
	_room_world.entity_layer.add_child(_player)

func _expect(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)

func _make_connection(id: StringName, source: Vector2i, dest: Vector2i, source_cells: Array, dest_cells: Array, interactive := false, bidirectional := true, type: RoomConnection.ConnectionType = RoomConnection.ConnectionType.DOOR) -> RoomConnection:
	var connection := RoomConnection.new()
	connection.connection_id = id
	connection.connection_type = type
	connection.source_room_id = source
	connection.destination_room_id = dest
	connection.source_cells.assign(source_cells)
	connection.destination_cells.assign(dest_cells)
	connection.interactive = interactive
	connection.bidirectional = bidirectional
	return connection

func _place_player(room_id: Vector2i, local_cell: Vector2i) -> void:
	var room := _room_world.get_room(room_id)
	_expect(room != null, "place_player: missing room %s" % room_id)
	if room == null or _player == null:
		return
	_player.room = room
	_player.block_layer = room.block_layer
	_player.room_size = room.size
	var surface := 0.0
	if room.block_layer != null:
		surface = room.block_layer.get_surface_elevation(local_cell)
	_player.place_at(local_cell, surface)
	_room_world.set_primary_room(room_id)

func _run_checks() -> void:
	_expect(_room_world != null, "RoomWorld missing")
	_expect(_player != null, "Player missing")
	if _room_world == null or _player == null:
		return
	_test_registration()
	_test_manager_queries()
	_test_spatial_transitions()
	_test_interactive_transition()
	_test_unconnected_boundary()
	_test_connection_save_load()

func _test_registration() -> void:
	var good := _make_connection(&"door_a_b", Vector2i(0, 0), Vector2i(1, 0), [Vector2i(15, 7), Vector2i(15, 8)], [Vector2i(0, 7), Vector2i(0, 8)])
	_expect(_room_world.register_connection(good), "valid spatial connection rejected")
	_expect(_room_world.get_connection(&"door_a_b") == good, "registered connection not retrievable")
	# Different-size rooms: A (16x16) -> D (16x24) one-way override door.
	var override_door := _make_connection(&"door_a_d", Vector2i(0, 0), Vector2i(3, 3), [Vector2i(15, 10)], [Vector2i(4, 2)], false, false)
	_expect(_room_world.register_connection(override_door), "valid cross-size connection rejected")
	# Interactive portal inside room A leading to distant room D.
	var portal := _make_connection(&"portal_a_d", Vector2i(0, 0), Vector2i(3, 3), [Vector2i(8, 8)], [Vector2i(2, 2)], true, false, RoomConnection.ConnectionType.PORTAL)
	_expect(_room_world.register_connection(portal), "valid interactive connection rejected")
	_expect(_room_world.connections.size() == 3, "expected 3 connections, got %d" % _room_world.connections.size())
	# Invalid registrations.
	_expect(not _room_world.register_connection(_make_connection(&"bad_missing", Vector2i(0, 0), Vector2i(9, 9), [Vector2i(0, 0)], [Vector2i(0, 0)])), "connection to missing room accepted")
	_expect(not _room_world.register_connection(_make_connection(&"bad_cell", Vector2i(0, 0), Vector2i(1, 0), [Vector2i(99, 0)], [Vector2i(0, 0)])), "connection with out-of-bounds source cell accepted")
	_expect(not _room_world.register_connection(_make_connection(&"bad_dest_cell", Vector2i(0, 0), Vector2i(1, 0), [Vector2i(0, 0)], [Vector2i(0, 99)])), "connection with out-of-bounds destination cell accepted")
	_expect(not _room_world.register_connection(_make_connection(&"bad_empty", Vector2i(0, 0), Vector2i(1, 0), [], [Vector2i(0, 0)])), "connection with empty cells accepted")
	_expect(not _room_world.register_connection(_make_connection(&"bad_self", Vector2i(0, 0), Vector2i(0, 0), [Vector2i(0, 0)], [Vector2i(0, 0)])), "self-loop connection accepted")
	_expect(not _room_world.register_connection(good.duplicate()), "duplicate connection id accepted")
	var dup := _make_connection(&"door_a_b_dup", Vector2i(0, 0), Vector2i(1, 0), [Vector2i(15, 7), Vector2i(15, 8)], [Vector2i(0, 7), Vector2i(0, 8)])
	_expect(not _room_world.register_connection(dup), "duplicate connection signature accepted")
	_expect(_room_world.connections.size() == 3, "invalid registrations changed connection count")

func _test_manager_queries() -> void:
	var room_a_conns := _room_world.get_room_connections(Vector2i(0, 0))
	_expect(room_a_conns.size() == 3, "room A reports %d connections, expected 3" % room_a_conns.size())
	var exit := _room_world.find_room_exit(_room_world.get_room(Vector2i(0, 0)), Vector2i(15, 7))
	_expect(not exit.is_empty(), "find_room_exit missed covered cell (15,7)")
	if not exit.is_empty():
		_expect(exit["room_id"] == Vector2i(1, 0), "exit destination room %s != (1,0)" % exit["room_id"])
		_expect(exit["cell"] == Vector2i(0, 7), "exit entry cell %s != (0,7)" % exit["cell"])
	# Reverse traversal of the bidirectional door.
	var reverse := _room_world.find_room_exit(_room_world.get_room(Vector2i(1, 0)), Vector2i(0, 8))
	_expect(not reverse.is_empty(), "reverse exit lookup missed B cell (0,8)")
	if not reverse.is_empty():
		_expect(reverse["room_id"] == Vector2i(0, 0), "reverse exit destination %s != (0,0)" % reverse["room_id"])
		_expect(reverse["cell"] == Vector2i(15, 8), "reverse exit entry %s != (15,8)" % reverse["cell"])
	# One-way override door has no reverse.
	var no_reverse := _room_world.find_room_exit(_room_world.get_room(Vector2i(3, 3)), Vector2i(4, 2))
	_expect(no_reverse.is_empty(), "one-way connection allowed reverse traversal")
	# Interactive lookup only fires on the portal cell.
	var entry := _room_world.find_interactive_entry(Vector2i(0, 0), Vector2i(8, 8))
	_expect(not entry.is_empty(), "interactive entry missed portal cell (8,8)")
	if not entry.is_empty():
		_expect(entry["room_id"] == Vector2i(3, 3), "portal destination %s != (3,3)" % entry["room_id"])
		_expect(entry["cell"] == Vector2i(2, 2), "portal entry %s != (2,2)" % entry["cell"])
	_expect(_room_world.find_interactive_entry(Vector2i(0, 0), Vector2i(8, 9)).is_empty(), "interactive entry fired on non-portal cell")
	_expect(_room_world.find_interactive_entry(Vector2i(1, 0), Vector2i(8, 8)).is_empty(), "interactive entry fired in wrong room")
	_expect(_room_world.validate_connections().is_empty(), "validate_connections reported problems: %s" % str(_room_world.validate_connections()))

func _test_spatial_transitions() -> void:
	# Explicit door overrides geometric adjacency: A(15,7) stepping east
	# must land on the connection's B entry (0,7), not the mirrored cell.
	_place_player(Vector2i(0, 0), Vector2i(15, 7))
	_player.request_move(Vector2i(1, 0))
	_expect(_player.room != null and _player.room.room_coordinates == Vector2i(1, 0), "door transition failed, room is %s" % (_player.room.room_coordinates if _player.room != null else "<none>"))
	_expect(_player.grid_position == Vector2i(0, 7), "door transition landed on %s, expected (0,7)" % _player.grid_position)
	# One-way override door: A(15,10) -> D(4,2), skipping geometry entirely
	# (D is not adjacent to A; this proves connection-driven placement).
	_place_player(Vector2i(0, 0), Vector2i(15, 10))
	_player.request_move(Vector2i(1, 0))
	_expect(_player.room != null and _player.room.room_coordinates == Vector2i(3, 3), "override door failed, room is %s" % (_player.room.room_coordinates if _player.room != null else "<none>"))
	_expect(_player.grid_position == Vector2i(4, 2), "override door landed on %s, expected (4,2)" % _player.grid_position)
	# Bidirectional return through the door: B(0,7) stepping west -> A(15,7).
	_place_player(Vector2i(1, 0), Vector2i(0, 7))
	_player.request_move(Vector2i(-1, 0))
	_expect(_player.room != null and _player.room.room_coordinates == Vector2i(0, 0), "return door failed, room is %s" % (_player.room.room_coordinates if _player.room != null else "<none>"))
	_expect(_player.grid_position == Vector2i(15, 7), "return door landed on %s, expected (15,7)" % _player.grid_position)
	# Uncovered edge cell still uses geometric adjacency (no connection there).
	_place_player(Vector2i(0, 0), Vector2i(15, 9))
	_player.request_move(Vector2i(1, 0))
	_expect(_player.room != null and _player.room.room_coordinates == Vector2i(1, 0), "geometric fallback failed, room is %s" % (_player.room.room_coordinates if _player.room != null else "<none>"))
	_expect(_player.grid_position == Vector2i(0, 9), "geometric fallback landed on %s, expected (0,9)" % _player.grid_position)

func _test_interactive_transition() -> void:
	# Stepping next to (not onto) the portal cell must not trigger.
	_place_player(Vector2i(0, 0), Vector2i(8, 7))
	_player.request_move(Vector2i(1, 0))
	_expect(_player.room != null and _player.room.room_coordinates == Vector2i(0, 0), "portal triggered without entering its cell")
	_expect(_player.grid_position == Vector2i(9, 7), "expected player on (9,7), got %s" % _player.grid_position)
	# Walk onto portal cell (8,8) in room A -> warps to D local (2,2).
	_place_player(Vector2i(0, 0), Vector2i(7, 8))
	_player.request_move(Vector2i(1, 0))
	_expect(_player.room != null and _player.room.room_coordinates == Vector2i(3, 3), "portal transition failed, room is %s" % (_player.room.room_coordinates if _player.room != null else "<none>"))
	_expect(_player.grid_position == Vector2i(2, 2), "portal landed on %s, expected (2,2)" % _player.grid_position)
	_expect(_player.facing_direction == Vector2i(1, 0), "portal did not preserve facing, got %s" % _player.facing_direction)
	# Re-entering the portal triggers again.
	_place_player(Vector2i(0, 0), Vector2i(8, 7))
	_player.request_move(Vector2i(0, 1))
	_expect(_player.room != null and _player.room.room_coordinates == Vector2i(3, 3), "re-entering portal did not transition")

func _test_unconnected_boundary() -> void:
	# With require_explicit_connections, an edge shared with another room
	# but not covered by a connection must block movement.
	_room_world.require_explicit_connections = true
	_place_player(Vector2i(0, 0), Vector2i(15, 9))
	var info := _player.evaluate_transition(Vector2i(1, 0))
	_expect(info.get("attempted", false), "evaluate_transition did not attempt uncovered edge")
	_expect(not info.get("valid", true), "uncovered edge reported valid under require_explicit_connections")
	_expect(str(info.get("reason", "")) == "no connection", "unexpected reason: %s" % info.get("reason"))
	_player.request_move(Vector2i(1, 0))
	_expect(_player.room != null and _player.room.room_coordinates == Vector2i(0, 0), "player escaped through unconnected edge")
	# Covered cells still transition under the strict mode.
	_place_player(Vector2i(0, 0), Vector2i(15, 7))
	_player.request_move(Vector2i(1, 0))
	_expect(_player.room != null and _player.room.room_coordinates == Vector2i(1, 0), "connected edge blocked under require_explicit_connections")
	_expect(_player.grid_position == Vector2i(0, 7), "strict-mode door landed on %s" % _player.grid_position)
	_room_world.require_explicit_connections = false

func _test_connection_save_load() -> void:
	_room_world.save_all_rooms()
	var path := RoomSaveSystem.connections_path()
	_expect(FileAccess.file_exists(path), "connections file missing after save")
	var file := FileAccess.open(path, FileAccess.READ)
	var data: Variant = JSON.parse_string(file.get_as_text()) if file != null else null
	if file != null:
		file.close()
	if data is Dictionary:
		_expect((data.get("connections", []) as Array).size() == 3, "saved connections count != 3")
	# Round-trip through deserialize_all, including a bogus entry.
	var serialized := _room_world.connections.serialize_all()
	serialized.append({"id": "bad_conn", "type": "door", "source_room": [0, 0], "destination_room": [9, 9], "source_cells": [[0, 0]], "destination_cells": [[0, 0]]})
	var loaded := _room_world.connections.deserialize_all(serialized)
	_expect(loaded == 3, "deserialize_all loaded %d connections, expected 3 (bad entry skipped)" % loaded)
	var exit := _room_world.find_room_exit(_room_world.get_room(Vector2i(0, 0)), Vector2i(15, 7))
	_expect(not exit.is_empty() and exit["room_id"] == Vector2i(1, 0), "restored connection lookup failed")
	# Full clear + file load.
	_room_world.connections.clear()
	_expect(_room_world.connections.size() == 0, "clear did not empty graph")
	_expect(RoomSaveSystem.load_connections(_room_world), "load_connections returned false")
	_expect(_room_world.connections.size() == 3, "load_connections restored %d connections, expected 3" % _room_world.connections.size())
	# Unregister removes the connection; the same data can register again.
	_expect(_room_world.unregister_connection(&"portal_a_d"), "unregister_connection failed")
	_expect(_room_world.get_connection(&"portal_a_d") == null, "unregistered connection still present")
	_expect(_room_world.register_connection(_make_connection(&"portal_a_d", Vector2i(0, 0), Vector2i(3, 3), [Vector2i(8, 8)], [Vector2i(2, 2)], true, false, RoomConnection.ConnectionType.PORTAL)), "re-registration after unregister failed")

func _report() -> void:
	if _failures.is_empty():
		print("ROOM_CONNECTION_SMOKE: OK")
	else:
		for failure in _failures:
			push_error("ROOM_CONNECTION_SMOKE FAIL: " + failure)
		print("ROOM_CONNECTION_SMOKE: FAILED (%d)" % _failures.size())
