extends SceneTree

var _scene: Node
var _room_world: RoomWorld
var _camera: WorldCamera
var _player: Player
var _grid: IsometricGrid
var _frames := 0
var _failures: Array[String] = []

func _initialize() -> void:
	_scene = load("res://Scenes/Test/RoomWorldTest.tscn").instantiate()
	root.add_child(_scene)

func _process(_delta: float) -> bool:
	_frames += 1
	if _frames < 4:
		return false
	_room_world = _scene.get_node("RoomWorld") as RoomWorld
	if _room_world != null:
		_camera = _room_world.get_node("WorldCamera") as WorldCamera
		_grid = _room_world.grid
		if _camera != null:
			_camera.follow_smoothing = 0.0
	_player = _scene.find_child("Player", true, false) as Player
	if _camera != null and _player != null:
		var camera_target: Vector2 = _player.global_position + _camera.focus_offset
		if _camera.global_position.distance_to(camera_target) > 0.5 and _frames < 60:
			return false
	_run_checks()
	_report()
	quit()
	return true

func _expect(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)

func _expected_coordinates() -> Array[Vector2i]:
	var coordinates: Array[Vector2i] = []
	for x in range(-1, 2):
		for y in range(-1, 2):
			coordinates.append(Vector2i(x, y))
	return coordinates

func _run_checks() -> void:
	_expect(_room_world != null, "RoomWorld node missing")
	_expect(_camera != null, "WorldCamera missing")
	_expect(_player != null, "Player missing")
	_expect(_grid != null, "IsometricGrid missing")
	if _room_world == null or _grid == null:
		return
	_test_registry()
	_test_positions()
	_test_contents()
	_test_floors()
	_test_camera()
	_test_neighbor_emphasis()

func _test_registry() -> void:
	var coordinates := _expected_coordinates()
	_expect(_room_world.get_rooms().size() == coordinates.size(), "expected %d rooms, got %d" % [coordinates.size(), _room_world.get_rooms().size()])
	for room_coordinates in coordinates:
		var room := _room_world.get_room(room_coordinates)
		_expect(room != null, "missing room at %s" % room_coordinates)
		if room == null:
			continue
		_expect(_room_world.has_room(room_coordinates), "has_room failed for %s" % room_coordinates)
		_expect(room.room_coordinates == room_coordinates, "room at %s reports coordinates %s" % [room_coordinates, room.room_coordinates])
		_expect(room.cell_origin == Vector2i(room_coordinates.x * _room_world.room_dimensions.x, room_coordinates.y * _room_world.room_dimensions.y), "room at %s has cell_origin %s" % [room_coordinates, room.cell_origin])
		_expect(room.size == _room_world.room_dimensions, "room at %s has size %s" % [room_coordinates, room.size])
		_expect(room.cells.size() == 256, "room at %s has %d cells" % [room_coordinates, room.cells.size()])
	_expect(not _room_world.has_room(Vector2i(2, 2)), "unexpected room at (2, 2)")
	_expect(_room_world.get_room(Vector2i(2, 2)) == null, "get_room returned a room for missing coordinates")
	_expect(_room_world.get_room_at_world_cell(Vector2i(31, 31)) != null, "world cell (31, 31) did not resolve to a room")
	_expect(_room_world.get_room_at_world_cell(Vector2i(32, 0)) == null, "world cell (32, 0) resolved outside the world")

	var center := _room_world.get_room(Vector2i.ZERO)
	if center != null:
		var room_count := _room_world.get_rooms().size()
		_expect(not _room_world.registry.register(center, Vector2i.ZERO), "registry accepted a duplicate coordinate")
		_expect(not _room_world.registry.register(center, Vector2i(1, 1)), "registry accepted a duplicate room instance")
		_expect(not _room_world.register_room(center, Vector2i(1, 1)), "RoomWorld accepted a duplicate room instance")
		_expect(_room_world.get_rooms().size() == room_count, "duplicate registration changed room count")
		_expect(center.room_coordinates == Vector2i.ZERO, "duplicate registration changed room coordinates")

func _test_positions() -> void:
	for room_coordinates in _expected_coordinates():
		var room := _room_world.get_room(room_coordinates)
		if room == null:
			continue
		var expected_offset := _room_world.room_screen_offset(room_coordinates, room.size)
		_expect(room.position.distance_to(expected_offset) < 0.01, "room %s position %s != expected %s" % [room_coordinates, room.position, expected_offset])
		_expect(room.global_position.distance_to(expected_offset) < 0.01, "room %s global position %s != expected %s" % [room_coordinates, room.global_position, expected_offset])
		var probe_local := Vector2i(2, 3)
		_expect(room.world_to_cell(room.cell_to_world(probe_local)) == room.get_cell(probe_local), "room %s world/local cell roundtrip failed" % room_coordinates)

	for room_coordinates in _expected_coordinates():
		var room := _room_world.get_room(room_coordinates)
		if room == null:
			continue
		for direction in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
			var neighbor_coordinates: Vector2i = room_coordinates + direction
			var neighbor := _room_world.get_room(neighbor_coordinates)
			if neighbor == null:
				continue
			var mid := Vector2i(floori(room.size.x * 0.5), floori(room.size.y * 0.5))
			var current_local: Vector2i
			var neighbor_local: Vector2i
			if direction == Vector2i(1, 0):
				current_local = Vector2i(room.size.x - 1, mid.y)
				neighbor_local = Vector2i(0, mid.y)
			elif direction == Vector2i(-1, 0):
				current_local = Vector2i(0, mid.y)
				neighbor_local = Vector2i(neighbor.size.x - 1, mid.y)
			elif direction == Vector2i(0, 1):
				current_local = Vector2i(mid.x, room.size.y - 1)
				neighbor_local = Vector2i(mid.x, 0)
			else:
				current_local = Vector2i(mid.x, 0)
				neighbor_local = Vector2i(mid.x, neighbor.size.y - 1)
			var actual_delta := neighbor.cell_to_world(neighbor_local) - room.cell_to_world(current_local)
			var expected_delta := _grid.grid_to_screen(direction) - _grid.grid_to_screen(Vector2i.ZERO)
			_expect(actual_delta.distance_to(expected_delta) < 0.01, "boundary %s -> %s delta %s != expected %s" % [room_coordinates, neighbor_coordinates, actual_delta, expected_delta])

func _test_contents() -> void:
	var seen_instances := {}
	for room_coordinates in _expected_coordinates():
		var room := _room_world.get_room(room_coordinates)
		if room == null:
			continue
		var block_layer := room.block_layer
		_expect(block_layer != null, "room %s has no BlockLayer" % room_coordinates)
		if block_layer == null:
			continue
		_expect(block_layer.blocks.size() == 3, "room %s has %d occupants, expected 3" % [room_coordinates, block_layer.blocks.size()])
		var index: int = (room_coordinates.x + 1) * 3 + (room_coordinates.y + 1)
		var offset_x := index % 3
		var offset_y := int(index / 3.0)
		var expected_cells := [
			Vector2i(2 + offset_x, 2 + offset_y),
			Vector2i(6 + offset_y, 7 + offset_x),
			Vector2i(11 - offset_x, 12 - offset_y),
		]
		for cell in expected_cells:
			_expect(block_layer.is_cell_occupied(cell), "room %s missing occupant at local cell %s" % [room_coordinates, cell])
			_expect(cell.x >= 0 and cell.y >= 0 and cell.x < room.size.x and cell.y < room.size.y, "room %s occupant escaped local bounds at %s" % [room_coordinates, cell])
		for block in block_layer.blocks:
			var instance_id := block.get_instance_id()
			_expect(not seen_instances.has(instance_id), "block instance shared between rooms")
			seen_instances[instance_id] = true
			_expect(block.grid_position.x >= 0 and block.grid_position.y >= 0 and block.grid_position.x < room.size.x and block.grid_position.y < room.size.y, "room %s block at non-local cell %s" % [room_coordinates, block.grid_position])

func _test_floors() -> void:
	for room_coordinates in _expected_coordinates():
		var room := _room_world.get_room(room_coordinates)
		if room == null:
			continue
		var tile_layer := _room_world.get_tile_layer(room_coordinates)
		_expect(tile_layer != null, "room %s has no TileLayer" % room_coordinates)
		if tile_layer != null:
			_expect(tile_layer._tiles.size() == 256, "room %s has %d floor sprites, expected 256" % [room_coordinates, tile_layer._tiles.size()])
		var first_cell := room.get_cell(Vector2i.ZERO)
		_expect(first_cell != null and first_cell.tile != null, "room %s first cell has no tile" % room_coordinates)

	var corner_room := _room_world.get_room(Vector2i(-1, -1))
	var corner_tiles := _room_world.get_tile_layer(Vector2i(-1, -1))
	if corner_room != null and corner_tiles != null:
		var sprite := corner_tiles._tiles.get(Vector2i.ZERO) as Sprite2D
		if sprite != null:
			var expected := _grid.grid_to_screen(corner_room.world_cell_coordinates(Vector2i.ZERO)) + _tile_sprite_offset(corner_room, Vector2i.ZERO)
			_expect(sprite.global_position.distance_to(expected) < 0.01, "corner floor sprite at %s != world cell %s" % [sprite.global_position, expected])
	var far_room := _room_world.get_room(Vector2i(1, 1))
	var far_tiles := _room_world.get_tile_layer(Vector2i(1, 1))
	if far_room != null and far_tiles != null:
		var sprite := far_tiles._tiles.get(Vector2i(15, 15)) as Sprite2D
		if sprite != null:
			var expected := _grid.grid_to_screen(far_room.world_cell_coordinates(Vector2i(15, 15))) + _tile_sprite_offset(far_room, Vector2i(15, 15))
			_expect(sprite.global_position.distance_to(expected) < 0.01, "far floor sprite at %s != world cell %s" % [sprite.global_position, expected])

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

func _test_camera() -> void:
	if _camera == null or _player == null:
		return
	var expected_camera := _player.global_position + _camera.focus_offset
	_expect(_camera.global_position.distance_to(expected_camera) < 1.0, "camera did not follow player: %s vs %s" % [_camera.global_position, expected_camera])
	for world_cell in [Vector2i(-16, -16), Vector2i(0, 0), Vector2i(31, 31), Vector2i(16, -16), Vector2i(-16, 16)]:
		var world := _grid.grid_to_screen(world_cell)
		var screen: Vector2 = _camera.world_to_screen(world)
		var recovered: Vector2 = _camera.screen_to_world(screen)
		_expect(recovered.distance_to(world) < 0.01, "camera roundtrip failed for world cell %s" % world_cell)

func _test_neighbor_emphasis() -> void:
	var center := _room_world.get_room(Vector2i.ZERO)
	_expect(center != null, "center room missing for emphasis test")
	if center == null:
		return
	_expect(_room_world.deemphasize_neighbors, "deemphasize_neighbors is disabled")
	_expect(center.deemphasis_material == null, "primary room has a deemphasis material")
	for room_coordinates in _expected_coordinates():
		if room_coordinates == Vector2i.ZERO:
			continue
		var room := _room_world.get_room(room_coordinates)
		_expect(room != null and room.deemphasis_material != null, "neighbor room %s lacks deemphasis material" % room_coordinates)
		if room != null and room.deemphasis_material != null:
			var sprite_materials := 0
			for item in room._deemphasis_nodes:
				if is_instance_valid(item) and item.material == room.deemphasis_material:
					sprite_materials += 1
			_expect(sprite_materials > 0, "neighbor room %s has no deemphasized canvas items" % room_coordinates)

	_room_world.set_primary_room(Vector2i(1, 0))
	var new_primary := _room_world.get_room(Vector2i(1, 0))
	var old_primary := _room_world.get_room(Vector2i.ZERO)
	_expect(new_primary != null and new_primary.deemphasis_material == null, "new primary room is still deemphasized")
	_expect(old_primary != null and old_primary.deemphasis_material != null, "old primary room was not deemphasized after switch")
	_room_world.set_primary_room(Vector2i.ZERO)
	_expect(center.deemphasis_material == null, "primary room did not return to normal after restore")

	if _player != null:
		_expect(_player.material == null, "player has a deemphasis material")
		var ancestor := _player.get_parent()
		var inside_room := false
		while ancestor != null:
			if ancestor is Room:
				inside_room = true
			ancestor = ancestor.get_parent()
		_expect(not inside_room, "player is parented inside a room subtree")
		_expect(_player.get_parent() == _room_world.entity_layer, "player is not under the RoomWorld entity layer")

	var neighbor := _room_world.get_room(Vector2i(-1, -1))
	if neighbor != null and neighbor.block_layer != null:
		_expect(neighbor.block_layer.blocks.size() == 3, "deemphasis changed neighbor room contents")

func _report() -> void:
	if _failures.is_empty():
		print("ROOM_WORLD_SMOKE: OK")
	else:
		for failure in _failures:
			push_error("ROOM_WORLD_SMOKE FAIL: " + failure)
		print("ROOM_WORLD_SMOKE: FAILED (%d)" % _failures.size())
