extends SceneTree

var _scene: Node
var _room_world: RoomWorld
var _world: World
var _player: Player
var _camera: WorldCamera
var _frames := 0
var _phase := 0
var _failures: Array[String] = []

func _initialize() -> void:
	_scene = load("res://Scenes/Main/Main.tscn").instantiate()
	root.add_child(_scene)

func _process(_delta: float) -> bool:
	_frames += 1
	if _phase == 0:
		if _frames < 8:
			return false
		_room_world = _scene.get_node("RoomWorld") as RoomWorld
		_world = _scene.get_node("World") as World
		if _room_world == null or _world == null:
			_failures.append("Main scene is missing RoomWorld or World")
			_report()
			quit()
			return true
		_camera = _world.get_node_or_null("WorldCamera") as WorldCamera
		if _camera != null:
			_camera.follow_smoothing = 1000.0
		_room_world.emphasis_transition_duration = 0.0
		_room_world.room_slide_duration = 0.0
		_room_world.refresh_room_emphasis()
		_player = _scene.find_child("Player", true, false) as Player
		if _player != null:
			_player.move_duration = 0.0
		_run_checks()
		_phase = 1
		_frames = 0
		return false
	if _frames < 4:
		return false
	_test_camera_settled()
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
	_expect(_player != null, "Player missing")
	if _room_world == null or _world == null:
		return
	if _player != null and _world.room != null:
		_place_player(Vector2i.ZERO, _world.room_definition.spawn_position)
	var coordinates := _expected_coordinates()
	_expect(_room_world.get_rooms().size() == coordinates.size(), "expected %d rooms in main, got %d" % [coordinates.size(), _room_world.get_rooms().size()])
	for room_coordinates in coordinates:
		var room := _room_world.get_room(room_coordinates)
		_expect(room != null, "missing room at %s" % room_coordinates)
		if room == null:
			continue
		_expect(room.size == _world.room.size, "room %s has size %s, expected %s" % [room_coordinates, room.size, _world.room.size])
		_expect(room.visible, "room %s is hidden while it is inside the primary neighborhood" % room_coordinates)
	_expect(_world.room == _room_world.get_room(Vector2i.ZERO), "World room is not registered as room (0, 0)")
	_expect(_world.room.room_coordinates == Vector2i.ZERO, "World room coordinates are %s" % _world.room.room_coordinates)
	_expect(_player != null and _player.room == _world.room, "player is not bound to the World room")
	_expect(_world.room.deemphasis_material == null, "primary room has a deemphasis material")
	for room_coordinates in coordinates:
		if room_coordinates == Vector2i.ZERO:
			continue
		var room := _room_world.get_room(room_coordinates)
		_expect(room != null and room.deemphasis_material != null, "neighbor room %s lacks deemphasis material" % room_coordinates)
		_expect(room != null and room.block_layer != null, "neighbor room %s has no block layer" % room_coordinates)
	if _world.block_layer != null:
		_expect(not _world.block_layer.blocks.is_empty(), "World room has no blocks after load")
	_test_transition()
	_test_room_saves()

func _place_player(room_coordinates: Vector2i, local_cell: Vector2i) -> void:
	var room := _room_world.get_room(room_coordinates)
	if room == null:
		return
	_player.room = room
	_player.block_layer = room.block_layer
	_player.room_size = room.size
	var surface := 0.0
	if room.block_layer != null:
		surface = room.block_layer.get_surface_elevation(local_cell)
	_player.place_at(local_cell, surface)
	_room_world.set_primary_room(room_coordinates)

func _test_transition() -> void:
	if _player == null or _world.room == null or _world.block_layer == null:
		return
	var edge_cell := Vector2i(-1, -1)
	for y in range(_world.room.size.y):
		var candidate := Vector2i(_world.room.size.x - 1, y)
		if _world.block_layer.get_blocks_at(candidate).is_empty():
			edge_cell = candidate
			break
	_expect(edge_cell.x >= 0, "no free cell on the right edge of the World room")
	if edge_cell.x < 0:
		return
	_place_player(Vector2i.ZERO, edge_cell)
	_player.request_move(Vector2i(1, 0))
	_expect(_player.room != null and _player.room.room_coordinates == Vector2i(1, 0), "transition right did not reach room (1, 0), now %s" % (_player.room.room_coordinates if _player.room != null else "<none>"))
	_expect(_player.grid_position == Vector2i(0, edge_cell.y), "transition right landed on %s, expected (0, %d)" % [_player.grid_position, edge_cell.y])
	_expect(_room_world.primary_room_coordinates == Vector2i(1, 0), "primary room is %s after transition" % _room_world.primary_room_coordinates)
	var center := _room_world.get_room(Vector2i.ZERO)
	var right := _room_world.get_room(Vector2i(1, 0))
	_expect(center != null and center.deemphasis_material != null, "old primary room was not deemphasized")
	_expect(right != null and right.deemphasis_material == null, "new primary room is still deemphasized")
	var far_left := _room_world.get_room(Vector2i(-1, 1))
	var near_bottom := _room_world.get_room(Vector2i(0, 1))
	_expect(far_left != null and not far_left.visible, "room outside the new 3x3 neighborhood is still visible")
	_expect(near_bottom != null and near_bottom.visible, "neighbor room inside the new 3x3 neighborhood is hidden")

func _test_room_saves() -> void:
	if _room_world == null or _player == null:
		return
	var room := _player.room
	if room == null or room.block_layer == null:
		_failures.append("no player room for save test")
		return
	var block_def: BlockDefinition = _room_world.block_catalog.get_definition(&"standard_block") if _room_world.block_catalog != null else null
	_expect(block_def != null, "standard_block definition missing for save test")
	if block_def == null:
		return
	var free_cell := Vector2i(-1, -1)
	for y in range(room.size.y):
		for x in range(room.size.x):
			var candidate := Vector2i(x, y)
			if room.block_layer.get_blocks_at(candidate).is_empty():
				free_cell = candidate
				break
		if free_cell.x >= 0:
			break
	_expect(free_cell.x >= 0, "no free cell for save test")
	if free_cell.x < 0:
		return
	_expect(room.block_layer.place_block(block_def, free_cell, 0.0) != null, "could not place test block")
	if room.block_layer.get_blocks_at(free_cell).is_empty():
		return
	var expected := room.block_layer.blocks.size()
	var error := _room_world.save_room_state(room)
	_expect(error == OK, "save_room_state failed with error %d" % error)
	_expect(FileAccess.file_exists(RoomSaveSystem.room_state_path(room.room_coordinates, room.size)), "room state file missing after save")
	room.block_layer.clear_blocks()
	_room_world.reset_room_state(room)
	_expect(_room_world.ensure_room_loaded(room), "ensure_room_loaded returned false for saved room")
	_expect(room.block_layer.blocks.size() == expected, "room state load restored %d blocks, expected %d" % [room.block_layer.blocks.size(), expected])
	for block in room.block_layer.get_blocks_at(free_cell):
		room.block_layer.remove_block(block)
	_room_world.save_room_state(room)
	_room_world.save_all_rooms()
	var state := RoomSaveSystem.load_player_state()
	_expect(not state.is_empty(), "player state missing after save_all_rooms")
	if not state.is_empty():
		_expect(state["room_coordinates"] == room.room_coordinates, "player state room mismatch")
		_expect(state["position"] == _player.grid_position, "player state position mismatch")

func _test_camera_settled() -> void:
	if _camera == null or _player == null:
		return
	var expected := _player.global_position + _camera.focus_offset
	_expect(_camera.global_position.distance_to(expected) < 1.0, "camera did not follow player in main world")
	var controller := _world.placement_controller
	_expect(controller != null and controller.room == _player.room, "placement controller did not follow the player room")
	_expect(controller != null and controller.block_layer == _player.block_layer, "placement controller block layer mismatch")
	_expect(FileAccess.file_exists(RoomSaveSystem.room_state_path(Vector2i.ZERO, _world.room.size)), "leaving the center room did not write its save")

func _report() -> void:
	if _failures.is_empty():
		print("MAIN_ROOM_WORLD_SMOKE: OK")
	else:
		for failure in _failures:
			push_error("MAIN_ROOM_WORLD_SMOKE FAIL: " + failure)
		print("MAIN_ROOM_WORLD_SMOKE: FAILED (%d)" % _failures.size())
