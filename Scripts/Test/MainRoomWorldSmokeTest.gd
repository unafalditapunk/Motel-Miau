extends SceneTree

var _scene: Node
var _room_world: RoomWorld
var _world: WorldBootstrap
var _player: Player
var _camera: WorldCamera
var _frames := 0
var _phase := 0
var _failures: Array[String] = []

func _initialize() -> void:
	RoomSaveSystem.save_dir = "user://smoke_saves/main_room_world"
	# The main world boots into the Motel floor; keep its floor saves in
	# a scratch root so the test never touches real user://floors data.
	FloorSaveSystem.save_root = "user://smoke_saves/floor_main_room_world"
	_remove_dir_contents(RoomSaveSystem.save_dir)
	_remove_dir_contents(FloorSaveSystem.save_root)
	_scene = load("res://Scenes/Main/Main.tscn").instantiate()
	root.add_child(_scene)

func _process(_delta: float) -> bool:
	_frames += 1
	if _phase == 0:
		if _frames < 8:
			return false
		_room_world = _scene.get_node("WorldBootstrap/RoomWorld") as RoomWorld
		_world = _scene.get_node("WorldBootstrap") as WorldBootstrap
		if _room_world == null or _world == null:
			_failures.append("Main scene is missing RoomWorld or WorldBootstrap")
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

func _remove_dir_contents(path: String) -> void:
	var dir := DirAccess.open(path)
	if dir == null:
		return
	for file_name in dir.get_files():
		dir.remove(file_name)
	for sub in dir.get_directories():
		_remove_dir_contents(path.path_join(sub))
		DirAccess.remove_absolute(path.path_join(sub))

const RING_SIZE := Vector2i(4, 4)
const RING_IDS: Array[Vector2i] = [
	Vector2i(0, -1), Vector2i(1, -1), Vector2i(2, -1), Vector2i(3, -1), Vector2i(4, -1),
	Vector2i(0, 2), Vector2i(1, 2), Vector2i(2, 2), Vector2i(3, 2), Vector2i(4, 2),
	Vector2i(-1, 0), Vector2i(-1, 1), Vector2i(-1, 2),
	Vector2i(5, 0), Vector2i(5, 1), Vector2i(5, 2),
]
# With bounds-based spatial adjacency (padding 1), every ring room
# touches the center's grown bounds, so the whole ring is visible.
const HIDDEN_FROM_CENTER: Array[Vector2i] = []

func _expected_coordinates() -> Array[Vector2i]:
	var coordinates: Array[Vector2i] = [Vector2i.ZERO]
	coordinates.append_array(RING_IDS)
	return coordinates

func _expected_size(room_coordinates: Vector2i) -> Vector2i:
	if room_coordinates == Vector2i.ZERO and _world != null:
		return _world.room.size
	return RING_SIZE

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
		_expect(room.size == _expected_size(room_coordinates), "room %s has size %s, expected %s" % [room_coordinates, room.size, _expected_size(room_coordinates)])
		var should_be_visible := not HIDDEN_FROM_CENTER.has(room_coordinates)
		_expect(room.visible == should_be_visible, "room %s visible=%s, expected %s in center neighborhood" % [room_coordinates, room.visible, should_be_visible])
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
	# Right edge of the 12x12 center maps onto the right column of 4x4
	# ring rooms: y 0..3 -> (5,0), 4..7 -> (5,1), 8..11 -> (5,2).
	var expected_room := Vector2i(5, edge_cell.y >> 2)
	var expected_local := Vector2i(0, edge_cell.y & 3)
	_expect(_player.room != null and _player.room.room_coordinates == expected_room, "transition right did not reach room %s, now %s" % [expected_room, _player.room.room_coordinates if _player.room != null else "<none>"])
	_expect(_player.grid_position == expected_local, "transition right landed on %s, expected %s" % [_player.grid_position, expected_local])
	_expect(_room_world.primary_room_coordinates == expected_room, "primary room is %s after transition" % _room_world.primary_room_coordinates)
	var center := _room_world.get_room(Vector2i.ZERO)
	var right := _room_world.get_room(expected_room)
	_expect(center != null and center.deemphasis_material != null, "old primary room was not deemphasized")
	_expect(right != null and right.deemphasis_material == null, "new primary room is still deemphasized")
	var far_corner := _room_world.get_room(Vector2i(0, 2))
	_expect(far_corner != null and not far_corner.visible, "room outside the connection neighborhood is still visible")
	_expect(center != null and center.visible, "connected center room hidden while standing in ring room")

## Floor-scoped room save path: with an active floor the effective save
## directory is user://floors/<id>/ (redirected to scratch here), not
## the legacy RoomSaveSystem.save_dir.
func _room_state_file(room: Room) -> String:
	return _room_world.effective_save_directory().path_join(
		"%s.json" % RoomSaveSystem.room_state_name(room.room_coordinates, room.size))

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
	_expect(FileAccess.file_exists(_room_state_file(room)), "room state file missing after save")
	room.block_layer.clear_blocks()
	_room_world.reset_room_state(room)
	_expect(_room_world.ensure_room_loaded(room), "ensure_room_loaded returned false for saved room")
	_expect(room.block_layer.blocks.size() == expected, "room state load restored %d blocks, expected %d" % [room.block_layer.blocks.size(), expected])
	# Floor-level round-trip: commit through FloorManager (manifest
	# included), re-materialize the whole floor, and confirm the placed
	# block survived — this is the authoritative save/load path.
	_expect(_world.floor_manager.save_active_floor(), "save_active_floor failed")
	_expect(_world.floor_manager.load_floor(&"motel"), "motel floor reload failed")
	var reloaded := _room_world.get_room(room.room_coordinates)
	_expect(reloaded != null and reloaded.block_layer != null \
		and reloaded.block_layer.blocks.size() == expected,
		"floor reload lost blocks: %s" % (reloaded.block_layer.blocks.size() if reloaded != null and reloaded.block_layer != null else -1))
	room = reloaded
	if room == null or room.block_layer == null:
		return
	for block in room.block_layer.get_blocks_at(free_cell):
		room.block_layer.remove_block(block)
	_room_world.save_room_state(room)
	_room_world.save_all_rooms()
	# Player state lives in the floor-scoped directory; point the static
	# save_dir at it just for this read, like RoomWorld._with_save_dir.
	var saved_dir := RoomSaveSystem.save_dir
	RoomSaveSystem.save_dir = _room_world.effective_save_directory()
	var state := RoomSaveSystem.load_player_state()
	RoomSaveSystem.save_dir = saved_dir
	_expect(not state.is_empty(), "player state missing after save_all_rooms")
	if not state.is_empty():
		# The floor reload re-spawned the player at a spawn point, so
		# compare against the player's CURRENT room, not the stale
		# pre-reload reference.
		var current_room: Room = _player.room
		_expect(current_room != null and state["room_coordinates"] == current_room.room_coordinates, "player state room mismatch")
		_expect(state["position"] == _player.grid_position, "player state position mismatch")

func _test_camera_settled() -> void:
	if _camera == null or _player == null:
		return
	var expected := _player.global_position + _camera.focus_offset
	_expect(_camera.global_position.distance_to(expected) < 1.0, "camera did not follow player in main world")
	var controller := _world.placement_controller
	_expect(controller != null and controller.room == _player.room, "placement controller did not follow the player room")
	_expect(controller != null and controller.block_layer == _player.block_layer, "placement controller block layer mismatch")
	var center_room := _room_world.get_room(Vector2i.ZERO)
	_expect(center_room != null and FileAccess.file_exists(_room_state_file(center_room)), "leaving the center room did not write its save")

func _report() -> void:
	if _failures.is_empty():
		print("MAIN_ROOM_WORLD_SMOKE: OK")
	else:
		for failure in _failures:
			push_error("MAIN_ROOM_WORLD_SMOKE FAIL: " + failure)
		print("MAIN_ROOM_WORLD_SMOKE: FAILED (%d)" % _failures.size())
