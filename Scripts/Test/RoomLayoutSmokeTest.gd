extends SceneTree

## Smoke test for variable-size rooms at arbitrary global origins.
## Builds a RoomWorld in code (no .tscn) with rooms of different sizes
## placed at non-uniform world-grid positions, then verifies local/global
## coordinate conversion, room lookup, bounds, overlap detection,
## isometric placement, player transitions and save/load.

const GRID_PATH := "res://Resources/IsometricGrid/TestGrid.tres"
const TILE_CATALOG_PATH := "res://Resources/TileCatalog.tres"
const BLOCK_CATALOG_PATH := "res://Resources/BlockCatalog.tres"
const FURNITURE_CATALOG_PATH := "res://Resources/FurnitureCatalog.tres"
const CARPET_CATALOG_PATH := "res://Resources/CarpetCatalog.tres"
const BLOCK_SCENE_PATH := "res://Scenes/Objects/Block.tscn"
const PLAYER_SCENE_PATH := "res://Scenes/Player/Player.tscn"

# room_id -> {origin, size}
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
	RoomSaveSystem.save_dir = "user://smoke_saves/room_layout"
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
		var room := _room_world.create_room_at(room_id, entry["origin"], entry["size"])
		if room == null:
			push_error("RoomLayoutSmokeTest failed to create room %s." % room_id)

func _spawn_player() -> void:
	var room_a := _room_world.get_room(Vector2i(0, 0))
	if room_a == null or _room_world.player_scene == null:
		return
	_player = _room_world.player_scene.instantiate() as Player
	_player.grid = _room_world.grid
	_player.block_layer = room_a.block_layer
	_player.room = room_a
	_player.room_size = room_a.size
	_player.place_at(Vector2i(7, 7), 0.0)
	_player.move_duration = 0.0
	_room_world.entity_layer.add_child(_player)

func _process(_delta: float) -> bool:
	_frames += 1
	# RoomWorld._ready (entity_layer) only runs once the tree is active.
	if _player == null and _room_world.entity_layer != null:
		_spawn_player()
	if _frames < 6:
		return false
	_run_checks()
	_report()
	quit()
	return true

func _expect(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)

func _run_checks() -> void:
	_expect(_room_world != null, "RoomWorld missing")
	_expect(_grid != null, "IsometricGrid missing")
	_expect(_player != null, "Player missing")
	if _room_world == null or _grid == null:
		return
	_test_registration_and_dimensions()
	_test_coordinate_conversion()
	_test_global_queries()
	_test_overlap_detection()
	_test_isometric_placement()
	_test_player_transitions()
	_test_save_load()

func _test_registration_and_dimensions() -> void:
	_expect(_room_world.get_rooms().size() == LAYOUT.size(), "expected %d rooms, got %d" % [LAYOUT.size(), _room_world.get_rooms().size()])
	for room_id in LAYOUT:
		var entry: Dictionary = LAYOUT[room_id]
		var room := _room_world.get_room(room_id)
		_expect(room != null, "missing room id %s" % room_id)
		if room == null:
			continue
		_expect(room.room_coordinates == room_id, "room id %s reports coordinates %s" % [room_id, room.room_coordinates])
		_expect(room.size == entry["size"], "room %s has size %s, expected %s" % [room_id, room.size, entry["size"]])
		_expect(room.cell_origin == entry["origin"], "room %s cell_origin %s != global origin %s" % [room_id, room.cell_origin, entry["origin"]])
		_expect(room.global_origin == entry["origin"], "room %s global_origin %s != %s" % [room_id, room.global_origin, entry["origin"]])
		_expect(room.global_bounds() == Rect2i(entry["origin"], entry["size"]), "room %s global_bounds %s wrong" % [room_id, room.global_bounds()])
		_expect(room.cells.size() == entry["size"].x * entry["size"].y, "room %s has %d cells" % [room_id, room.cells.size()])
		# Local coordinates always start at the room's own origin.
		_expect(room.has_cell(Vector2i.ZERO), "room %s missing local cell (0,0)" % room_id)
		_expect(not room.has_cell(Vector2i(-1, 0)), "room %s accepts negative local cell" % room_id)
		_expect(not room.has_cell(entry["size"]), "room %s accepts out-of-bounds local cell %s" % [room_id, entry["size"]])
		_expect(room.block_layer != null, "room %s has no BlockLayer" % room_id)

func _test_coordinate_conversion() -> void:
	for room_id in LAYOUT:
		var room := _room_world.get_room(room_id)
		if room == null:
			continue
		var origin: Vector2i = room.cell_origin
		var size: Vector2i = room.size
		for local: Vector2i in [Vector2i.ZERO, Vector2i(size.x - 1, size.y - 1), Vector2i(floori(size.x * 0.5), floori(size.y * 0.5))]:
			var world: Vector2i = origin + local
			_expect(room.world_cell_coordinates(local) == world, "room %s world_cell_coordinates(%s) = %s, expected %s" % [room_id, local, room.world_cell_coordinates(local), world])
			_expect(room.local_cell_coordinates(world) == local, "room %s local_cell_coordinates(%s) = %s, expected %s" % [room_id, world, room.local_cell_coordinates(world), local])
			_expect(room.global_origin + local == world, "room %s global_origin conversion failed" % room_id)

func _test_global_queries() -> void:
	# Containment: world cell -> owning room.
	var cases := {
		Vector2i(0, 0): Vector2i(0, 0),      # A origin corner
		Vector2i(15, 15): Vector2i(0, 0),    # A far corner (inclusive of last cell)
		Vector2i(16, 0): Vector2i(1, 0),     # B west edge = A east edge + 1
		Vector2i(47, 15): Vector2i(1, 0),    # B far corner
		Vector2i(48, 4): Vector2i(2, 1),     # C origin
		Vector2i(55, 11): Vector2i(2, 1),    # C far corner
		Vector2i(60, 20): Vector2i(3, 3),    # D origin
		Vector2i(75, 43): Vector2i(3, 3),    # D far corner
	}
	for world_cell in cases:
		var expected: Vector2i = cases[world_cell]
		var room := _room_world.get_room_at_world_cell(world_cell)
		_expect(room != null and room.room_coordinates == expected, "world cell %s resolved to %s, expected room %s" % [world_cell, room.room_coordinates if room != null else "<none>", expected])
		var via_alias := _room_world.get_room_at_global_cell(world_cell)
		_expect(via_alias == room, "get_room_at_global_cell disagrees for %s" % world_cell)
	# Cells outside every room.
	for world_cell in [Vector2i(16, 16), Vector2i(48, 0), Vector2i(59, 30), Vector2i(-1, -1), Vector2i(100, 100)]:
		_expect(_room_world.get_room_at_world_cell(world_cell) == null, "world cell %s unexpectedly inside a room" % world_cell)
	# Registry-level containment returns correct local cell.
	var room_b := _room_world.get_room(Vector2i(1, 0))
	if room_b != null:
		var found := _room_world.registry.get_room_at_global_cell(Vector2i(20, 5))
		_expect(found == room_b, "registry lookup for (20,5) did not return room B")
		_expect(_room_world.registry.global_bounds(room_b) == Rect2i(Vector2i(16, 0), Vector2i(32, 16)), "registry bounds for room B wrong")
	_expect(_room_world.validate_layout().is_empty(), "validate_layout reported problems on a clean layout: %s" % str(_room_world.validate_layout()))

func _test_overlap_detection() -> void:
	var room_a := _room_world.get_room(Vector2i(0, 0))
	var room_b := _room_world.get_room(Vector2i(1, 0))
	var room_c := _room_world.get_room(Vector2i(2, 1))
	_expect(room_a != null and room_b != null and room_c != null, "rooms missing for overlap test")
	if room_a == null or room_b == null or room_c == null:
		return
	# Edge-adjacent rooms share a border but must not count as overlapping.
	_expect(not _room_world.registry.rooms_overlap(room_a, room_b), "edge-adjacent rooms A/B reported as overlapping")
	_expect(not _room_world.registry.rooms_overlap(room_b, room_c), "edge-adjacent rooms B/C reported as overlapping")
	_expect(_room_world.registry.find_overlap(room_a) == null, "find_overlap flagged a clean room")
	# An overlapping placement must be rejected by default.
	var rejected := _room_world.create_room_at(Vector2i(9, 9), Vector2i(8, 8), Vector2i(16, 16))
	_expect(rejected == null, "overlapping room was registered despite allow_overlapping_rooms=false")
	# With the flag enabled it registers, and the layout reports the clash.
	_room_world.allow_overlapping_rooms = true
	var clash := _room_world.create_room_at(Vector2i(9, 9), Vector2i(8, 8), Vector2i(16, 16))
	_room_world.allow_overlapping_rooms = false
	_expect(clash != null, "overlapping room rejected even with allow_overlapping_rooms=true")
	if clash != null:
		_expect(not _room_world.validate_layout().is_empty(), "validate_layout missed the overlapping room")
		_room_world.unregister_room(Vector2i(9, 9))
		clash.queue_free()
		_expect(_room_world.validate_layout().is_empty(), "validate_layout still reports problems after unregister")

func _test_isometric_placement() -> void:
	# Room screen position must equal the isometric projection of its
	# global origin, so differently sized rooms tile without gaps.
	for room_id in LAYOUT:
		var entry: Dictionary = LAYOUT[room_id]
		var room := _room_world.get_room(room_id)
		if room == null:
			continue
		var expected_pos: Vector2 = _grid.grid_to_screen(entry["origin"]) - _grid.grid_to_screen(Vector2i.ZERO)
		_expect(room.position.distance_to(expected_pos) < 0.01, "room %s position %s != projected origin %s" % [room_id, room.position, expected_pos])
		var local := Vector2i(floori(entry["size"].x * 0.5), floori(entry["size"].y * 0.5))
		var expected_world: Vector2 = _grid.grid_to_screen(entry["origin"] + local)
		_expect(room.cell_to_world(local).distance_to(expected_world) < 0.01, "room %s cell_to_world(%s) = %s != %s" % [room_id, local, room.cell_to_world(local), expected_world])
		var roundtrip := room.world_to_cell_coordinates(room.cell_to_world(local))
		_expect(roundtrip == local, "room %s world->local roundtrip gave %s, expected %s" % [room_id, roundtrip, local])
	# Floor sprites of a non-origin room must land on their global cells.
	var room_c := _room_world.get_room(Vector2i(2, 1))
	if room_c != null:
		var tile_layer := _room_world.get_tile_layer(Vector2i(2, 1))
		_expect(tile_layer != null, "room C has no TileLayer")
		if tile_layer != null:
			_expect(tile_layer._tiles.size() == 64, "room C has %d floor sprites, expected 64" % tile_layer._tiles.size())
			var sprite := tile_layer._tiles.get(Vector2i.ZERO) as Sprite2D
			if sprite != null:
				var expected := _grid.grid_to_screen(Vector2i(48, 4)) + _tile_sprite_offset(room_c, Vector2i.ZERO)
				_expect(sprite.global_position.distance_to(expected) < 0.01, "room C floor sprite at %s != world cell (48,4) screen %s" % [sprite.global_position, expected])
	# Shared edges must be exactly one isometric step apart.
	var expected_step := _grid.grid_to_screen(Vector2i(1, 0)) - _grid.grid_to_screen(Vector2i.ZERO)
	var room_a := _room_world.get_room(Vector2i(0, 0))
	var room_b := _room_world.get_room(Vector2i(1, 0))
	if room_a != null and room_b != null:
		var a_world := room_a.cell_to_world(Vector2i(15, 7))
		var b_edge_world := room_b.cell_to_world(Vector2i(0, 7))
		var step := b_edge_world - a_world
		_expect(step.distance_to(expected_step) < 0.01, "A->B edge step %s != expected %s" % [step, expected_step])
	# B (32 wide) and C (8 wide) share the edge x=47/48 for y in [4,11].
	var room_c2 := _room_world.get_room(Vector2i(2, 1))
	if room_b != null and room_c2 != null:
		var b_world := room_b.cell_to_world(Vector2i(31, 8))   # world (47, 8)
		var c_world := room_c2.cell_to_world(Vector2i(0, 4))   # world (48, 8)
		_expect(b_world.distance_to(c_world - expected_step) < 0.01, "B/C shared edge is not a single tile step: %s vs %s" % [b_world, c_world])

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

func _test_player_transitions() -> void:
	if _player == null:
		return
	# A (16 wide) -> B (32 wide): east edge crossing lands on B local x=0.
	_place_player(Vector2i(0, 0), Vector2i(15, 7))
	_player.request_move(Vector2i(1, 0))
	_expect(_player.room != null and _player.room.room_coordinates == Vector2i(1, 0), "A->B transition failed, room is %s" % (_player.room.room_coordinates if _player.room != null else "<none>"))
	_expect(_player.grid_position == Vector2i(0, 7), "A->B landed on %s, expected (0,7)" % _player.grid_position)
	# B -> C: B local (31,8) is world (47,8); stepping +x enters C at local (0,4).
	_place_player(Vector2i(1, 0), Vector2i(31, 8))
	_player.request_move(Vector2i(1, 0))
	_expect(_player.room != null and _player.room.room_coordinates == Vector2i(2, 1), "B->C transition failed, room is %s" % (_player.room.room_coordinates if _player.room != null else "<none>"))
	_expect(_player.grid_position == Vector2i(0, 4), "B->C landed on %s, expected (0,4)" % _player.grid_position)
	# C -> B back across the same edge.
	_player.request_move(Vector2i(-1, 0))
	_expect(_player.room != null and _player.room.room_coordinates == Vector2i(1, 0), "C->B transition failed, room is %s" % (_player.room.room_coordinates if _player.room != null else "<none>"))
	_expect(_player.grid_position == Vector2i(31, 8), "C->B landed on %s, expected (31,8)" % _player.grid_position)
	# D is isolated: stepping off any edge finds no room.
	_place_player(Vector2i(3, 3), Vector2i(0, 10))
	var before_room := _player.room
	_player.request_move(Vector2i(-1, 0))
	_expect(_player.room == before_room, "isolated room D allowed a transition west")
	_expect(_player.grid_position == Vector2i(0, 10), "isolated room D moved player to %s" % _player.grid_position)
	# Placement still uses room-local coordinates in a variable-size room.
	_place_player(Vector2i(1, 0), Vector2i(5, 5))
	var block_def: BlockDefinition = _room_world.block_catalog.get_definition(&"standard_block") if _room_world.block_catalog != null else null
	if block_def != null and _player.room != null and _player.room.block_layer != null:
		var layer := _player.room.block_layer
		var placed := layer.place_block(block_def, Vector2i(20, 10), 0.0)
		_expect(placed != null, "could not place block at local (20,10) in 32x16 room B")
		if placed != null:
			_expect(layer.is_cell_occupied(Vector2i(20, 10)), "placed block not registered at local cell")
			_expect(not layer.is_cell_occupied(Vector2i(52, 10)), "block leaked into world-cell coordinates")
			layer.remove_block(placed)

func _test_save_load() -> void:
	var room_d := _room_world.get_room(Vector2i(3, 3))
	if room_d == null or room_d.block_layer == null:
		_failures.append("room D missing for save/load test")
		return
	var block_def: BlockDefinition = _room_world.block_catalog.get_definition(&"standard_block") if _room_world.block_catalog != null else null
	if block_def == null:
		_failures.append("standard_block definition missing for save/load test")
		return
	var placed := room_d.block_layer.place_block(block_def, Vector2i(2, 2), 0.0)
	if placed == null:
		_failures.append("could not place block for save/load test")
		return
	var error := _room_world.save_room_state(room_d)
	_expect(error == OK, "save_room_state failed with error %d" % error)
	var path := RoomSaveSystem.room_state_path(room_d.room_coordinates, room_d.size)
	_expect(FileAccess.file_exists(path), "room state file missing after save: %s" % path)
	if FileAccess.file_exists(path):
		var file := FileAccess.open(path, FileAccess.READ)
		var data: Variant = JSON.parse_string(file.get_as_text())
		file.close()
		if data is Dictionary:
			var origin = RoomSaveSystem._read_vec2i(data.get("global_origin"))
			_expect(origin == Vector2i(60, 20), "saved global_origin %s != (60,20)" % origin)
			var size = RoomSaveSystem._read_vec2i(data.get("size"))
			_expect(size == Vector2i(16, 24), "saved size %s != (16,24)" % size)
	room_d.block_layer.clear_blocks()
	_room_world.reset_room_state(room_d)
	_expect(_room_world.ensure_room_loaded(room_d), "ensure_room_loaded returned false for saved room D")
	_expect(room_d.block_layer.blocks.size() == 1, "room D restored %d blocks, expected 1" % room_d.block_layer.blocks.size())
	# Clean up so repeated runs start from a clean save.
	room_d.block_layer.clear_blocks()
	_room_world.save_room_state(room_d)

## Screen-space offset TileLayer applies to tall tile sprites
## (texture taller than tile_height, bottom-center anchor).
func _tile_sprite_offset(room: Room, local: Vector2i) -> Vector2:
	var tile := room.get_cell_tile(local) as TileDefinition
	if tile == null or tile.sprite_texture == null or tile.sprite_anchor != 0:
		return Vector2.ZERO
	var size := tile.sprite_texture.get_size()
	if size.y <= _grid.tile_height + 0.001:
		return Vector2.ZERO
	return Vector2(0.0, _grid.tile_height * 0.5 - size.y * 0.5)

func _report() -> void:
	if _failures.is_empty():
		print("ROOM_LAYOUT_SMOKE: OK")
	else:
		for failure in _failures:
			push_error("ROOM_LAYOUT_SMOKE FAIL: " + failure)
		print("ROOM_LAYOUT_SMOKE: FAILED (%d)" % _failures.size())
