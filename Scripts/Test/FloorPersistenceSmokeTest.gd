extends SceneTree

## Smoke test for floor persistence and switching: each floor saves to
## its own directory (user://floors/<id>/, redirected to a scratch root
## here), switching saves the outgoing floor before rebuilding, player
## room/position is restored per floor, corrupt saves abort safely, and
## failed destinations never cost the current floor.

const GRID_PATH := "res://Resources/IsometricGrid/TestGrid.tres"
const TILE_CATALOG_PATH := "res://Resources/TileCatalog.tres"
const BLOCK_CATALOG_PATH := "res://Resources/BlockCatalog.tres"
const FURNITURE_CATALOG_PATH := "res://Resources/FurnitureCatalog.tres"
const CARPET_CATALOG_PATH := "res://Resources/CarpetCatalog.tres"
const BLOCK_SCENE_PATH := "res://Scenes/Objects/Block.tscn"
const PLAYER_SCENE_PATH := "res://Scenes/Player/Player.tscn"
const SCRATCH_ROOT := "user://smoke_floor_saves"

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
	# the player spawn and custom floor registration happen in _process.

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

func _floor(id: StringName, rooms: Array, entry: Vector2i, spawn: Vector2i, auto_connect := false) -> Floor:
	var floor_def := Floor.new()
	floor_def.floor_id = id
	floor_def.display_name = String(id)
	floor_def.entry_room_id = entry
	floor_def.spawn_position = spawn
	floor_def.auto_connect_adjacent = auto_connect
	floor_def.rooms.assign(rooms)
	return floor_def

func _register_test_floors() -> void:
	# Two-room floor with an explicit connection and distinct spawn.
	var floor_a := _floor(&"pf_a", [
		_spec(Vector2i(0, 0), Vector2i(0, 0), Vector2i(8, 8)),
		_spec(Vector2i(1, 0), Vector2i(8, 0), Vector2i(8, 8)),
	], Vector2i(0, 0), Vector2i(2, 2), false)
	var link := RoomConnection.new()
	link.connection_id = &"pf_a_link"
	link.source_room_id = Vector2i(0, 0)
	link.destination_room_id = Vector2i(1, 0)
	link.source_cells = [Vector2i(7, 3)]
	link.destination_cells = [Vector2i(0, 3)]
	link.interactive = false
	link.bidirectional = true
	var links: Array[RoomConnection] = [link]
	floor_a.connections = links
	_floor_manager.register_floor(floor_a)
	# Single-room floor reusing the same room id — proves save isolation.
	_floor_manager.register_floor(_floor(&"pf_b", [
		_spec(Vector2i(0, 0), Vector2i(0, 0), Vector2i(8, 8)),
	], Vector2i(0, 0), Vector2i(3, 3), false))
	# Invalid floor: duplicate room ids — switch must refuse it.
	_floor_manager.register_floor(_floor(&"pf_bad", [
		_spec(Vector2i(0, 0), Vector2i(0, 0), Vector2i(8, 8)),
		_spec(Vector2i(0, 0), Vector2i(8, 0), Vector2i(8, 8)),
	], Vector2i(0, 0), Vector2i(1, 1), false))
	# Auto-connect floor for created-room connection tests.
	_floor_manager.register_floor(_floor(&"pf_c", [
		_spec(Vector2i(0, 0), Vector2i(0, 0), Vector2i(8, 8)),
	], Vector2i(0, 0), Vector2i(1, 1), true))
	# Empty floor: first created room becomes entry/spawn.
	_floor_manager.register_floor(_floor(&"pf_d", [], Vector2i.ZERO, Vector2i.ZERO, false))

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

func _player_room_id() -> Vector2i:
	return _player.room.room_coordinates if _player.room != null else Vector2i(-999, -999)

func _place_block(room: Room, cell: Vector2i) -> void:
	var def: BlockDefinition = _room_world.block_catalog.get_definition(&"standard_block")
	if def == null or room == null or room.block_layer == null:
		_failures.append("cannot place test block")
		return
	room.block_layer.place_block(def, cell, 0.0)

func _active_room_count() -> int:
	return _room_world.registry.get_rooms().size()

func _test_shipped_switch_chain() -> void:
	# Motel -> Forest -> Village -> Motel using the shipped floors.
	# Motel is the ring world: 12x12 center + sixteen 4x4 ring rooms.
	_expect(_floor_manager.switch_floor(&"motel"), "switch to motel failed")
	_expect(_floor_manager.active_floor != null and _floor_manager.active_floor.floor_id == &"motel", "active floor is not motel")
	_expect(_active_room_count() == 17, "motel has %d rooms, expected 17" % _active_room_count())
	_expect(_room_world.connections.size() == 28, "motel has %d connections, expected 28" % _room_world.connections.size())
	_expect(_player_room_id() == Vector2i(0, 0), "motel player room %s != entry (0,0)" % _player_room_id())
	_expect(_player.grid_position == Vector2i(6, 6), "motel spawn %s != (6,6)" % _player.grid_position)
	_expect(_floor_manager.has_floor_save(&"motel") == false, "motel should have no save before first outgoing switch")

	_expect(_floor_manager.switch_floor(&"forest"), "switch motel->forest failed")
	_expect(_active_room_count() == 9, "forest has %d rooms" % _active_room_count())
	_expect(_floor_manager.has_floor_save(&"motel"), "motel save missing after switching away")
	_expect(not _floor_manager.has_floor_save(&"forest"), "forest unexpectedly has a save")
	_expect(_player_room_id() == Vector2i(1, 1) and _player.grid_position == Vector2i(8, 8), "forest spawn not restored")

	_expect(_floor_manager.switch_floor(&"village"), "switch forest->village failed")
	_expect(_floor_manager.has_floor_save(&"forest"), "forest save missing")
	_expect(_active_room_count() == 9, "village has %d rooms" % _active_room_count())

	_expect(_floor_manager.switch_floor(&"motel"), "switch village->motel failed")
	_expect(_active_room_count() == 17, "motel reload has %d rooms" % _active_room_count())
	_expect(_player_room_id() == Vector2i(0, 0), "motel player room wrong after reload")

	# A stale/empty saved connection graph must not wipe the
	# auto-generated doors: hydration replaces the graph, then
	# load_floor re-runs auto-connect (idempotent).
	var conn_path := FloorSaveSystem.floor_dir(&"motel").path_join("connections.json")
	var conn_file := FileAccess.open(conn_path, FileAccess.WRITE)
	conn_file.store_string(JSON.stringify({"version": 1, "connections": []}))
	conn_file.close()
	_expect(_floor_manager.load_floor(&"motel"), "motel reload after empty connections failed")
	_expect(_room_world.connections.size() == 28,
		"empty saved graph wiped auto connections: %d" % _room_world.connections.size())
	# Per-floor directories were actually created under the scratch root.
	for id in [&"motel", &"forest"]:
		var manifest := FloorSaveSystem.manifest_path(id)
		_expect(FileAccess.file_exists(manifest), "missing manifest for '%s'" % id)

func _test_content_and_player_persistence() -> void:
	_expect(_floor_manager.switch_floor(&"pf_a"), "switch to pf_a failed")
	_expect(_active_room_count() == 2, "pf_a has %d rooms, expected 2" % _active_room_count())
	_expect(_room_world.connections.size() == 1, "pf_a connections = %d, expected 1" % _room_world.connections.size())
	_expect(_player_room_id() == Vector2i(0, 0) and _player.grid_position == Vector2i(2, 2), "pf_a spawn not applied: %s @ %s" % [_player_room_id(), _player.grid_position])

	var room_a := _room_world.get_room(Vector2i(0, 0))
	_place_block(room_a, Vector2i(4, 4))
	_player.place_at(Vector2i(5, 5), _player.stand_elevation_at(Vector2i(5, 5)))
	_expect(_floor_manager.is_floor_dirty(), "placing content did not mark floor dirty")

	# Switch away: pf_a must be fully saved first.
	_expect(_floor_manager.switch_floor(&"pf_b"), "switch pf_a->pf_b failed")
	_expect(not _floor_manager.is_floor_dirty(), "dirty flag not cleared after save+switch")
	_expect(_floor_manager.has_floor_save(&"pf_a"), "pf_a save missing")
	_expect(not _floor_manager.has_floor_save(&"pf_b"), "pf_b should have no save yet")
	# pf_b reuses room id (0,0) but is a different floor: no block, own spawn.
	_expect(_active_room_count() == 1, "pf_b has %d rooms, expected 1" % _active_room_count())
	var room_b := _room_world.get_room(Vector2i(0, 0))
	_expect(room_b != null and room_b.block_layer != null and room_b.block_layer.blocks.is_empty(), "pf_b room inherited pf_a content")
	_expect(_player.grid_position == Vector2i(3, 3), "pf_b spawn %s != (3,3)" % _player.grid_position)
	# pf_a's files exist under its own directory.
	_expect(FileAccess.file_exists(FloorSaveSystem.floor_dir(&"pf_a").path_join("room_0_0_8x8.json")), "pf_a room save missing")
	_expect(FileAccess.file_exists(FloorSaveSystem.floor_dir(&"pf_a").path_join("player_state.json")), "pf_a player save missing")

	# Back to pf_a: contents, connection, and player position restored.
	_expect(_floor_manager.switch_floor(&"pf_a"), "switch pf_b->pf_a failed")
	_expect(_active_room_count() == 2, "pf_a reload has %d rooms" % _active_room_count())
	_expect(_room_world.connections.size() == 1, "pf_a connection not restored")
	room_a = _room_world.get_room(Vector2i(0, 0))
	_expect(room_a != null and room_a.block_layer != null and room_a.block_layer.blocks.size() == 1, "pf_a block not restored (blocks=%d)" % (room_a.block_layer.blocks.size() if room_a != null and room_a.block_layer != null else -1))
	_expect(_player_room_id() == Vector2i(0, 0) and _player.grid_position == Vector2i(5, 5), "pf_a player pos not restored: %s @ %s" % [_player_room_id(), _player.grid_position])

func _test_corrupt_manifest() -> void:
	# pf_a is active with unsaved state? No — it was just loaded. Move the
	# player so a failed switch would be detectable, then corrupt pf_b.
	_player.place_at(Vector2i(6, 6), _player.stand_elevation_at(Vector2i(6, 6)))
	var manifest_path := FloorSaveSystem.manifest_path(&"pf_b")
	DirAccess.make_dir_recursive_absolute(FloorSaveSystem.floor_dir(&"pf_b"))
	var file := FileAccess.open(manifest_path, FileAccess.WRITE)
	file.store_string("this is not json {{{")
	file.close()
	_expect(not _floor_manager.has_floor_save(&"pf_b"), "corrupt manifest reported as valid save")

	var before_rooms := _active_room_count()
	var before_pos := _player.grid_position
	_expect(not _floor_manager.switch_floor(&"pf_b"), "switch to corrupt-save floor succeeded")
	_expect(_floor_manager.active_floor != null and _floor_manager.active_floor.floor_id == &"pf_a", "active floor changed despite failed switch")
	_expect(_active_room_count() == before_rooms, "world torn down by failed switch")
	_expect(_player.grid_position == before_pos, "player moved by failed switch")

	# Repair the manifest; the floor now loads fresh (manifest ok, no rooms).
	var floor_b := _floor_manager.get_floor(&"pf_b")
	_expect(FloorSaveSystem.save_manifest(floor_b) == OK, "could not repair pf_b manifest")
	_expect(_floor_manager.switch_floor(&"pf_b"), "switch to repaired pf_b failed")
	_expect(_active_room_count() == 1, "repaired pf_b has %d rooms" % _active_room_count())

func _test_corrupt_room_save() -> void:
	# pf_b is active, so pf_a's save files sit untouched on disk —
	# corrupt one room file inside it, then switch back.
	var bad_path := FloorSaveSystem.floor_dir(&"pf_a").path_join("room_0_0_8x8.json")
	var file := FileAccess.open(bad_path, FileAccess.WRITE)
	file.store_string("{broken json")
	file.close()
	_expect(_floor_manager.switch_floor(&"pf_a"), "switch to pf_a with one corrupt room failed")
	_expect(_floor_manager.active_floor != null and _floor_manager.active_floor.floor_id == &"pf_a", "pf_a not active after partial-corruption load")
	# The corrupt room loads empty; the sibling room and player state survive.
	var room_a := _room_world.get_room(Vector2i(0, 0))
	var room_b := _room_world.get_room(Vector2i(1, 0))
	_expect(room_a != null and room_a.block_layer != null and room_a.block_layer.blocks.is_empty(), "corrupt room should load empty")
	_expect(room_b != null, "sibling room missing after partial-corruption load")
	_expect(_player_room_id() == Vector2i(0, 0), "player room not restored after partial-corruption load")

func _test_invalid_destination() -> void:
	var before_rooms := _active_room_count()
	var before_pos := _player.grid_position
	_expect(not _floor_manager.switch_floor(&"pf_bad"), "switch to invalid floor succeeded")
	_expect(_floor_manager.active_floor != null and _floor_manager.active_floor.floor_id == &"pf_a", "active floor changed by invalid-floor switch")
	_expect(_active_room_count() == before_rooms, "world changed by invalid-floor switch")
	_expect(_player.grid_position == before_pos, "player moved by invalid-floor switch")
	_floor_manager.unregister_floor(&"pf_bad")

func _test_layout_override() -> void:
	# pf_a is active (2 rooms). Its specs persist as user:// layout.json
	# and override the res:// resource specs on load — never the reverse.
	var floor_a := _floor_manager.get_floor(&"pf_a")
	_expect(FloorSaveSystem.save_layout(floor_a) == OK, "save_layout failed")
	_expect(FileAccess.file_exists(FloorSaveSystem.layout_path(&"pf_a")), "layout.json missing")
	var data := FloorSaveSystem.load_layout(&"pf_a")
	_expect((data.get("rooms", []) as Array).size() == 2, "layout override room count wrong")

	# A floor carrying the same id but bogus specs gets them replaced.
	var dummy := _floor(&"pf_a", [
		_spec(Vector2i(9, 9), Vector2i(99, 99), Vector2i(4, 4)),
	], Vector2i(9, 9), Vector2i(1, 1), false)
	_floor_manager._apply_layout_override(dummy)
	_expect(dummy.rooms.size() == 2, "layout override did not replace specs")
	var origins := {}
	for spec in dummy.rooms:
		origins[spec.global_origin] = true
	_expect(origins.has(Vector2i(0, 0)) and origins.has(Vector2i(8, 0)), "override origins wrong: %s" % origins)

	# The registered resource specs were not mutated by the dummy apply.
	_expect(floor_a.rooms.size() == 2, "registered floor specs mutated")

	# A corrupt layout file is ignored with a warning, never fatal.
	var file := FileAccess.open(FloorSaveSystem.layout_path(&"pf_a"), FileAccess.WRITE)
	file.store_string("not json")
	file.close()
	_expect(FloorSaveSystem.load_layout(&"pf_a").is_empty(), "corrupt layout not ignored")
	FloorSaveSystem.save_layout(floor_a)

func _test_created_room_persistence() -> void:
	# pf_a is active (2 rooms, auto_connect=false, one explicit link).
	var specs_before := _floor_manager.active_floor.rooms.size()
	var rooms_before := _active_room_count()

	# Failed creations leave no spec, no room, no corrupted state.
	var overlap := FloorRoomSpec.new()
	overlap.room_id = Vector2i(7, 7)
	overlap.global_origin = Vector2i(4, 0)  # overlaps room (0,0): 0..7 x 0..7
	overlap.size = Vector2i(8, 8)
	_expect(_floor_manager.add_room_to_active_floor(overlap) == null, "overlapping room was created")
	var dup := FloorRoomSpec.new()
	dup.room_id = Vector2i(0, 0)
	dup.global_origin = Vector2i(40, 40)
	dup.size = Vector2i(4, 4)
	_expect(_floor_manager.add_room_to_active_floor(dup) == null, "duplicate room id was created")
	var bad_size := FloorRoomSpec.new()
	bad_size.room_id = Vector2i(8, 8)
	bad_size.global_origin = Vector2i(60, 60)
	bad_size.size = Vector2i.ZERO
	_expect(_floor_manager.add_room_to_active_floor(bad_size) == null, "zero-size room was created")
	var too_small := FloorRoomSpec.new()
	too_small.room_id = Vector2i(9, 9)
	too_small.global_origin = Vector2i(80, 80)
	too_small.size = Vector2i(2, 1)
	_expect(_floor_manager.add_room_to_active_floor(too_small) == null, "sub-minimum room was created")
	var isolated := FloorRoomSpec.new()
	isolated.room_id = Vector2i(10, 10)
	isolated.global_origin = Vector2i(40, 40)
	isolated.size = Vector2i(4, 4)
	_expect(_floor_manager.add_room_to_active_floor(isolated) == null, "isolated room was created")
	_expect(_floor_manager.active_floor.rooms.size() == specs_before, "failed creations appended specs")
	_expect(_active_room_count() == rooms_before, "failed creations registered rooms")

	# Create rooms: one east of room (1,0), one at negative coordinates
	# sharing the west edge of room (0,0).
	_expect(_floor_manager.add_room_to_active_floor(_spec(Vector2i(7, 0), Vector2i(16, 0), Vector2i(6, 6))) != null, "east room creation failed")
	_expect(_floor_manager.add_room_to_active_floor(_spec(Vector2i(-3, -2), Vector2i(-6, 0), Vector2i(6, 4))) != null, "negative-coord room creation failed")
	# Corner-only contact does not count as adjacency.
	var corner_only := FloorRoomSpec.new()
	corner_only.room_id = Vector2i(11, 11)
	corner_only.global_origin = Vector2i(22, 6)  # touches room (7,0) only at the point (22,6)
	corner_only.size = Vector2i(4, 4)
	_expect(_floor_manager.add_room_to_active_floor(corner_only) == null, "corner-only room was created")
	_expect(_active_room_count() == rooms_before + 2, "room count wrong after creations: %d" % _active_room_count())
	# pf_a has auto_connect=false: only the explicit link exists.
	_expect(_room_world.connections.size() == 1, "auto-connect ran on non-auto floor")

	# Contents inside a created room persist like any other room.
	var created := _room_world.get_room(Vector2i(7, 0))
	_expect(created != null and created.global_bounds() == Rect2i(Vector2i(16, 0), Vector2i(6, 6)), "created room bounds wrong")
	_place_block(created, Vector2i(1, 1))

	# Save, switch away and back: layout + contents are reconstructed.
	_expect(_floor_manager.save_active_floor(), "save after creation failed")
	_expect(_floor_manager.switch_floor(&"pf_b"), "switch away after creation failed")
	_expect(_active_room_count() == 1, "pf_b gained created rooms")
	_expect(_floor_manager.switch_floor(&"pf_a"), "return to pf_a failed")
	_expect(_active_room_count() == rooms_before + 2, "created rooms not restored: %d" % _active_room_count())
	created = _room_world.get_room(Vector2i(7, 0))
	_expect(created != null and created.global_bounds() == Rect2i(Vector2i(16, 0), Vector2i(6, 6)), "created room bounds not restored")
	_expect(created != null and created.block_layer != null and created.block_layer.blocks.size() == 1, "created room contents not restored")
	var neg := _room_world.get_room(Vector2i(-3, -2))
	_expect(neg != null and neg.global_bounds() == Rect2i(Vector2i(-6, 0), Vector2i(6, 4)), "negative-coord room not restored")
	var layout := FloorSaveSystem.load_layout(&"pf_a")
	_expect((layout.get("rooms", []) as Array).size() == specs_before + 2, "layout.json spec count wrong")

func _test_created_room_connections() -> void:
	# pf_c: one 8x8 room + auto_connect. Every adjacent creation gets a
	# door; isolated placements are rejected outright.
	_expect(_floor_manager.switch_floor(&"pf_c"), "switch to pf_c failed")
	_expect(_floor_manager.add_room_to_active_floor(_spec(Vector2i(1, 0), Vector2i(8, 0), Vector2i(8, 8))) != null, "east room creation failed")
	_expect(_floor_manager.add_room_to_active_floor(_spec(Vector2i(0, 1), Vector2i(0, 8), Vector2i(8, 8))) != null, "south room creation failed")
	_expect(_floor_manager.add_room_to_active_floor(_spec(Vector2i(2, 2), Vector2i(40, 40), Vector2i(4, 4))) == null, "isolated room was created")
	var door_count := 0
	for connection in _room_world.connections.get_all_connections():
		if connection.source_room_id == Vector2i(0, 0) or connection.destination_room_id == Vector2i(0, 0):
			door_count += 1
	_expect(door_count == 2, "expected two auto doors, got %d" % door_count)

	# Save + reload: the generated door is preserved (saved graph or
	# idempotent auto-connect regeneration — never duplicated).
	_expect(_floor_manager.save_active_floor(), "pf_c save failed")
	_expect(_floor_manager.switch_floor(&"pf_b"), "switch away from pf_c failed")
	_expect(_floor_manager.switch_floor(&"pf_c"), "return to pf_c failed")
	door_count = 0
	for connection in _room_world.connections.get_all_connections():
		if connection.source_room_id == Vector2i(0, 0) or connection.destination_room_id == Vector2i(0, 0):
			door_count += 1
	_expect(_active_room_count() == 3, "pf_c rooms not restored: %d" % _active_room_count())
	_expect(door_count == 2, "auto doors lost or duplicated after reload: %d" % door_count)

func _test_empty_floor_first_room() -> void:
	# An empty floor accepts its first created room; that room becomes
	# the entry room and spawn centers inside it.
	_expect(_floor_manager.activate_floor(&"pf_d"), "activate empty floor failed")
	_expect(_floor_manager.active_floor.rooms.is_empty(), "pf_d not empty before creation")
	_expect(_floor_manager.add_room_to_active_floor(_spec(Vector2i(4, 4), Vector2i(-10, -10), Vector2i(12, 12))) != null, "first room on empty floor failed")
	_expect(_floor_manager.active_floor.entry_room_id == Vector2i(4, 4), "entry room not set on empty floor")
	_expect(_floor_manager.active_floor.spawn_position == Vector2i(6, 6), "spawn not centered: %s" % _floor_manager.active_floor.spawn_position)
	_expect(_floor_manager.validate_floor(_floor_manager.active_floor).is_empty(), "pf_d invalid after first room")
	_expect(_room_world.get_room(Vector2i(4, 4)) != null, "first room not registered")
	# The floor now persists like any other: save + reload reconstructs it.
	_expect(_floor_manager.save_active_floor(), "pf_d save failed")
	_expect(_floor_manager.switch_floor(&"pf_b"), "switch away from pf_d failed")
	_expect(_floor_manager.switch_floor(&"pf_d"), "return to pf_d failed")
	_expect(_active_room_count() == 1, "pf_d room not restored")
	var room := _room_world.get_room(Vector2i(4, 4))
	_expect(room != null and room.global_bounds() == Rect2i(Vector2i(-10, -10), Vector2i(12, 12)), "pf_d bounds wrong after reload")
	_expect(_floor_manager.active_floor.entry_room_id == Vector2i(4, 4), "pf_d entry not restored")

func _test_room_deletion() -> void:
	# pf_a has 4 rooms after the creation test: (0,0), (1,0) [explicit
	# link], created (7,0) [holds a block], created (-3,-2).
	_expect(_floor_manager.switch_floor(&"pf_a"), "switch to pf_a failed")
	_expect(_active_room_count() == 4, "pf_a rooms before deletion: %d" % _active_room_count())
	# Protected rooms refuse deletion with clear reasons.
	_expect(not bool(_floor_manager.can_delete_room(Vector2i(1, 0)).get("allowed", true)),
		"explicit-connection room was deletable")
	_expect(not bool(_floor_manager.can_delete_room(Vector2i(0, 0)).get("allowed", true)),
		"player-occupied entry room was deletable")
	_expect(not bool(_floor_manager.can_delete_room(Vector2i(7, 0)).get("allowed", true)),
		"room with contents was deletable")
	# Build a chain: (2,0) touches only (7,0); (3,0) touches only (2,0).
	_expect(_floor_manager.add_room_to_active_floor(_spec(Vector2i(2, 0), Vector2i(22, 0), Vector2i(4, 4))) != null, "chain room (2,0) failed")
	_expect(_floor_manager.add_room_to_active_floor(_spec(Vector2i(3, 0), Vector2i(26, 0), Vector2i(4, 4))) != null, "chain room (3,0) failed")
	# Deleting (2,0) now would isolate (3,0) → refused.
	var verdict := _floor_manager.can_delete_room(Vector2i(2, 0))
	_expect(not bool(verdict.get("allowed", true)), "isolation-unsafe delete allowed: %s" % verdict.get("reason", ""))
	# Remove the tip first, then the middle — both safe.
	_expect(_floor_manager.remove_room_from_active_floor(Vector2i(3, 0)), "tip room delete failed")
	_expect(_room_world.get_room(Vector2i(3, 0)) == null, "deleted room (3,0) still registered")
	_expect(_floor_manager.remove_room_from_active_floor(Vector2i(2, 0)), "middle room delete failed")
	_expect(_room_world.get_room(Vector2i(2, 0)) == null, "deleted room (2,0) still registered")
	# The explicit connection survived all deletions.
	_expect(_room_world.connections.size() == 1, "connections changed by deletion: %d" % _room_world.connections.size())
	# Deletions persist through save + reload.
	_expect(_floor_manager.switch_floor(&"pf_b"), "switch away after deletes failed")
	_expect(_floor_manager.switch_floor(&"pf_a"), "return after deletes failed")
	_expect(_room_world.get_room(Vector2i(2, 0)) == null and _room_world.get_room(Vector2i(3, 0)) == null,
		"deleted rooms restored from stale layout")
	_expect(_active_room_count() == 4, "pf_a rooms after deletes: %d" % _active_room_count())
	_expect(_floor_manager.switch_floor(&"pf_b"), "final switch to pf_b failed")

func _test_invalid_layout_rejected() -> void:
	# pf_c is active with a valid saved layout. Hand-write invalid
	# layout.json variants; load_floor must refuse and leave the
	# in-memory specs untouched.
	var floor_c := _floor_manager.get_floor(&"pf_c")
	var specs_before := floor_c.rooms.size()
	var layout_path := FloorSaveSystem.layout_path(&"pf_c")
	var base := {
		"version": 1,
		"floor_id": "pf_c",
		"rooms": []
	}
	# Duplicate room ids.
	var dup_layout: Dictionary = base.duplicate(true)
	dup_layout["rooms"] = [
		{"room_id": [0, 0], "global_origin": [0, 0], "size": [8, 8], "definition": "", "floor_colors": []},
		{"room_id": [0, 0], "global_origin": [20, 0], "size": [8, 8], "definition": "", "floor_colors": []},
	]
	# Overlapping bounds.
	var overlap_layout: Dictionary = base.duplicate(true)
	overlap_layout["rooms"] = [
		{"room_id": [0, 0], "global_origin": [0, 0], "size": [8, 8], "definition": "", "floor_colors": []},
		{"room_id": [1, 0], "global_origin": [4, 0], "size": [8, 8], "definition": "", "floor_colors": []},
	]
	# Unresolvable size (no definition to defer to).
	var bad_size_layout: Dictionary = base.duplicate(true)
	bad_size_layout["rooms"] = [
		{"room_id": [0, 0], "global_origin": [0, 0], "size": [0, 0], "definition": "", "floor_colors": []},
	]
	for bad in [dup_layout, overlap_layout, bad_size_layout]:
		var file := FileAccess.open(layout_path, FileAccess.WRITE)
		file.store_string(JSON.stringify(bad))
		file.close()
		_expect(not _floor_manager.load_floor(&"pf_c"), "load_floor accepted invalid layout: %s" % JSON.stringify(bad["rooms"]))
		_expect(floor_c.rooms.size() == specs_before, "refused load left mutated specs")
	# Heal the layout file from the still-valid in-memory specs and reload.
	_expect(FloorSaveSystem.save_layout(floor_c) == OK, "could not heal pf_c layout")
	_expect(_floor_manager.load_floor(&"pf_c"), "pf_c reload after heal failed")
	_expect(_active_room_count() == 3, "pf_c rooms wrong after heal: %d" % _active_room_count())

func _test_room_visibility_flags() -> void:
	# pf_c is active: (0,0) entry/primary plus edge-adjacent (1,0) and
	# (0,1). This world shows every room (hide_rooms_outside_neighborhood
	# = false), so the flags are the only thing hiding/showing rooms.
	var room00 := _room_world.get_room(Vector2i(0, 0))
	var room10 := _room_world.get_room(Vector2i(1, 0))
	var room01 := _room_world.get_room(Vector2i(0, 1))
	_expect(room00 != null and room10 != null and room01 != null, "pf_c rooms missing")
	if room00 == null or room10 == null or room01 == null:
		return
	_room_world.set_primary_room(Vector2i(0, 0))

	# show_from_outside=false: hidden while not primary, shown on entry.
	room10.show_from_outside = false
	_room_world.visuals.begin_transition()
	_expect(not room10.visible, "hidden-from-outside room still visible")
	_room_world.set_primary_room(Vector2i(1, 0))
	_expect(room10.visible, "hidden room did not appear when entered")
	_room_world.set_primary_room(Vector2i(0, 0))
	_expect(not room10.visible, "room did not hide after leaving")
	room10.show_from_outside = true
	_room_world.visuals.begin_transition()
	_expect(room10.visible, "flag restore did not reshow room")

	# Corner room (1,1) at (8,8) touches (0,0) only at a corner; it must
	# still be concealed by show_outside.
	_expect(_floor_manager.add_room_to_active_floor(_spec(Vector2i(1, 1), Vector2i(8, 8), Vector2i(8, 8))) != null,
		"corner room creation failed")
	var room11 := _room_world.get_room(Vector2i(1, 1))
	_expect(room11 != null, "corner room missing")
	if room11 == null:
		return

	# show_outside=false on the primary room conceals adjacent rooms
	# entirely (room.modulate reaches every visual layer).
	room00.show_outside = false
	_room_world.visuals.begin_transition()
	_expect(room10.modulate.a < 0.5, "adjacent room not concealed (room10)")
	_expect(room01.modulate.a < 0.5, "adjacent room not concealed (room01)")
	_expect(room11.modulate.a < 0.5, "corner room not concealed (room11)")
	_expect(room10.visible, "concealment should not touch room.visible")
	room00.show_outside = true
	_room_world.visuals.begin_transition()
	_expect(is_equal_approx(room10.modulate.a, 1.0), "concealed room not restored (room10)")
	_expect(is_equal_approx(room01.modulate.a, 1.0), "concealed room not restored (room01)")
	_expect(is_equal_approx(room11.modulate.a, 1.0), "concealed corner room not restored (room11)")

	# Flags persist through layout.json: create with both off, reload.
	var flagged := _spec(Vector2i(2, 2), Vector2i(16, 8), Vector2i(4, 4))
	flagged.show_from_outside = false
	flagged.show_outside = false
	_expect(_floor_manager.add_room_to_active_floor(flagged) != null, "flagged room creation failed")
	_expect(_floor_manager.save_active_floor(), "save with flagged room failed")
	_expect(_floor_manager.switch_floor(&"pf_b"), "switch away from flagged floor failed")
	_expect(_floor_manager.switch_floor(&"pf_c"), "return to flagged floor failed")
	var restored := _room_world.get_room(Vector2i(2, 2))
	_expect(restored != null, "flagged room not restored")
	if restored != null:
		_expect(not restored.show_from_outside and not restored.show_outside,
			"visibility flags not persisted (from=%s out=%s)" % [restored.show_from_outside, restored.show_outside])

func _test_shaped_rooms() -> void:
	# pf_d holds one 12x12 room (id (4,4)) at global origin (-10,-10),
	# covering x/y in [-10, 2). Build an L-shaped room attached to its
	# south edge: section A x[-10,-2) y[2,6), section B x[-2,2) y[2,10).
	_expect(_floor_manager.switch_floor(&"pf_d"), "switch to pf_d failed")
	var l_spec := FloorRoomSpec.new()
	l_spec.room_id = Vector2i(5, 5)
	l_spec.shape_sections = [
		Rect2i(Vector2i(-10, 2), Vector2i(8, 4)),
		Rect2i(Vector2i(-2, 2), Vector2i(4, 8)),
	]
	# No size/origin needed: they resolve from the sections.
	_expect(_floor_manager.add_room_to_active_floor(l_spec) != null, "shaped room creation failed")
	var shaped := _room_world.get_room(Vector2i(5, 5))
	_expect(shaped != null, "shaped room not registered")
	if shaped == null:
		return
	_expect(shaped.size == Vector2i(12, 8), "shaped room size %s != bbox 12x8" % shaped.size)
	_expect(shaped.cell_origin == Vector2i(-10, 2), "shaped room origin %s wrong" % shaped.cell_origin)
	_expect(shaped.cells.size() == 64, "shaped room cell count %d != 64" % shaped.cells.size())
	_expect(shaped.has_cell(Vector2i(0, 0)), "shaped room missing footprint cell (0,0)")
	_expect(shaped.has_cell(Vector2i(8, 5)), "shaped room missing footprint cell (8,5)")
	# Local (4,5) = global (-6,7) sits in the L's bounding-box hole.
	_expect(not shaped.has_cell(Vector2i(4, 5)), "shaped room claims a hole cell")
	_expect(_room_world.get_room_at_world_cell(Vector2i(-6, 7)) == null,
		"hole cell wrongly resolves to a room")
	# Invalid shapes are refused: disconnected sections and sections
	# overlapping each other.
	var disconnected := FloorRoomSpec.new()
	disconnected.room_id = Vector2i(6, 6)
	disconnected.shape_sections = [
		Rect2i(Vector2i(-10, 12), Vector2i(4, 4)),
		Rect2i(Vector2i(0, 20), Vector2i(4, 4)),
	]
	_expect(_floor_manager.add_room_to_active_floor(disconnected) == null, "disconnected sections accepted")
	var self_overlap := FloorRoomSpec.new()
	self_overlap.room_id = Vector2i(7, 7)
	self_overlap.shape_sections = [
		Rect2i(Vector2i(-10, 12), Vector2i(6, 4)),
		Rect2i(Vector2i(-8, 14), Vector2i(6, 4)),
	]
	_expect(_floor_manager.add_room_to_active_floor(self_overlap) == null, "self-overlapping sections accepted")
	# A room may fill the L's hole: its cells do not intersect the
	# footprint even though its bounds sit inside the bbox.
	var hole_fill := FloorRoomSpec.new()
	hole_fill.room_id = Vector2i(8, 8)
	hole_fill.shape_sections = [Rect2i(Vector2i(-10, 6), Vector2i(4, 4))]
	_expect(_floor_manager.add_room_to_active_floor(hole_fill) != null, "hole-fill room rejected")
	# Save + reload: sections, sparse cells, and hole behavior persist.
	_expect(_floor_manager.save_active_floor(), "pf_d shaped save failed")
	_expect(_floor_manager.switch_floor(&"pf_b"), "switch away from shaped pf_d failed")
	_expect(_floor_manager.switch_floor(&"pf_d"), "return to shaped pf_d failed")
	var reloaded := _room_world.get_room(Vector2i(5, 5))
	_expect(reloaded != null, "shaped room not restored")
	if reloaded != null:
		_expect(reloaded.shape_sections.size() == 2, "shaped room sections lost: %d" % reloaded.shape_sections.size())
		_expect(reloaded.cells.size() == 64, "reloaded shaped cell count %d != 64" % reloaded.cells.size())
		_expect(not reloaded.has_cell(Vector2i(4, 5)), "reloaded shaped room claims a hole")
	_expect(_room_world.get_room_at_world_cell(Vector2i(-6, 7)) == null,
		"hole cell resolves to a room after reload")
	var spec := _floor_manager.active_floor.find_room_spec(Vector2i(5, 5))
	_expect(spec != null and spec.shape_sections.size() == 2, "layout spec lost sections")

	# Collision: bbox holes are not standable — stepping into one is
	# blocked like stepping outside the room, while stepping into a
	# room that fills the hole transitions normally.
	var shaped_room := _room_world.get_room(Vector2i(5, 5))
	_expect(shaped_room != null, "shaped room missing for collision check")
	if shaped_room != null:
		_player.room = shaped_room
		_player.block_layer = shaped_room.block_layer
		_player.room_size = shaped_room.size
		_player.place_at(Vector2i(8, 5), 0.0)
		_expect(not _player.can_move_to(Vector2i(7, 5)), "player can move into shaped-room hole")
		_expect(not _player.move_to(Vector2i(7, 5)), "player moved into shaped-room hole")
		# Local (1,3) is section A; stepping south enters global (-9,6),
		# which is the hole-fill room's footprint.
		_player.place_at(Vector2i(1, 3), 0.0)
		var transition := _player.evaluate_transition(Vector2i(0, 1))
		_expect(bool(transition.get("valid", false)),
			"transition into hole-fill room refused: %s" % transition.get("reason", ""))

func _run_checks() -> void:
	_test_shipped_switch_chain()
	_test_content_and_player_persistence()
	_test_corrupt_manifest()
	_test_corrupt_room_save()
	_test_invalid_destination()
	_test_layout_override()
	_test_created_room_persistence()
	_test_created_room_connections()
	_test_empty_floor_first_room()
	_test_room_deletion()
	_test_invalid_layout_rejected()
	_test_room_visibility_flags()
	_test_shaped_rooms()

func _report() -> void:
	if _failures.is_empty():
		print("FLOOR_PERSISTENCE_SMOKE: OK")
	else:
		for failure in _failures:
			push_error("FLOOR_PERSISTENCE_SMOKE FAIL: " + failure)
		print("FLOOR_PERSISTENCE_SMOKE: FAILED (%d)" % _failures.size())
