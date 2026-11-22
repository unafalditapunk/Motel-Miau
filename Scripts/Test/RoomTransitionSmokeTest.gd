extends SceneTree

var _scene: Node
var _room_world: RoomWorld
var _player: Player
var _grid: IsometricGrid
var _camera: WorldCamera
var _frames := 0
var _phase := 0
var _failures: Array[String] = []

func _initialize() -> void:
	_scene = load("res://Scenes/Test/RoomWorldTest.tscn").instantiate()
	root.add_child(_scene)

func _process(_delta: float) -> bool:
	_frames += 1
	if _phase == 0:
		if _frames < 8:
			return false
		_room_world = _scene.get_node("RoomWorld") as RoomWorld
		if _room_world == null:
			_failures.append("RoomWorld node missing")
			_report()
			quit()
			return true
		_grid = _room_world.grid
		_camera = _room_world.get_node("WorldCamera") as WorldCamera
		if _camera != null:
			_camera.follow_smoothing = 1000.0
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

func _place_player(room_coordinates: Vector2i, local_cell: Vector2i) -> void:
	var room := _room_world.get_room(room_coordinates)
	_expect(room != null, "place_player: missing room %s" % room_coordinates)
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

func _expect_transition(room_coordinates: Vector2i, local_cell: Vector2i, direction: Vector2i) -> void:
	_player.request_move(direction)
	_expect(_player.room != null and _player.room.room_coordinates == room_coordinates, "transition %s did not reach room %s (now %s)" % [direction, room_coordinates, _player.room.room_coordinates if _player.room != null else "<none>"])
	_expect(_player.grid_position == local_cell, "transition %s landed on local cell %s, expected %s" % [direction, _player.grid_position, local_cell])
	_expect(_room_world.primary_room_coordinates == room_coordinates, "primary room is %s after transition, expected %s" % [_room_world.primary_room_coordinates, room_coordinates])

func _expect_no_transition(room: Room, local_cell: Vector2i, direction: Vector2i) -> void:
	var before_position := _player.position
	_player.request_move(direction)
	_expect(_player.room == room, "rejected transition changed room to %s" % (_player.room.room_coordinates if _player.room != null else "<none>"))
	_expect(_player.grid_position == local_cell, "rejected transition moved player to %s" % _player.grid_position)
	_expect(_player.position.distance_to(before_position) < 0.01, "rejected transition moved player position")

func _run_checks() -> void:
	_expect(_player != null, "Player missing")
	_expect(_grid != null, "IsometricGrid missing")
	if _player == null or _grid == null:
		return
	_test_cardinal_transitions()
	_test_missing_boundaries()
	_test_contents_persist()

func _test_cardinal_transitions() -> void:
	_place_player(Vector2i.ZERO, Vector2i(15, 7))
	var before := _player.position
	_expect_transition(Vector2i(1, 0), Vector2i(0, 7), Vector2i(1, 0))
	var expected_right := _grid.grid_to_screen(Vector2i(16, 7), _player.elevation)
	_expect(_player.position.distance_to(expected_right) < 0.5, "right transition screen pos %s != expected %s" % [_player.position, expected_right])
	var step := _player.position - before
	_expect(absf(step.x - 32.0) < 0.5 and absf(step.y - 16.0) < 0.5, "right transition was not a single tile step: %s" % step)

	_expect_transition(Vector2i.ZERO, Vector2i(15, 7), Vector2i(-1, 0))
	_place_player(Vector2i.ZERO, Vector2i(7, 0))
	_expect_transition(Vector2i(0, -1), Vector2i(7, 15), Vector2i(0, -1))
	_expect_transition(Vector2i.ZERO, Vector2i(7, 0), Vector2i(0, 1))
	_place_player(Vector2i.ZERO, Vector2i(7, 15))
	_expect_transition(Vector2i(0, 1), Vector2i(7, 0), Vector2i(0, 1))
	_expect_transition(Vector2i.ZERO, Vector2i(7, 15), Vector2i(0, -1))

	var right_room := _room_world.get_room(Vector2i(1, 0))
	var center_room := _room_world.get_room(Vector2i.ZERO)
	_expect(center_room != null and center_room.deemphasis_material == null, "center room not primary after returning")
	_expect(right_room != null and right_room.deemphasis_material != null, "right room lost deemphasis after primary moved back")

func _test_missing_boundaries() -> void:
	_place_player(Vector2i(1, 0), Vector2i(8, 15))
	_expect_transition(Vector2i(1, 1), Vector2i(8, 0), Vector2i(0, 1))
	var corner_room := _room_world.get_room(Vector2i(1, 1))
	_expect(corner_room != null, "missing room (1, 1)")
	if corner_room == null:
		return
	_place_player(Vector2i(1, 1), Vector2i(15, 8))
	var info := _player.evaluate_transition(Vector2i(1, 0))
	_expect(info.get("attempted", false), "evaluate_transition did not report attempt beyond world edge")
	_expect(not info.get("valid", true), "evaluate_transition reported valid move into missing room")
	_expect(str(info.get("reason", "")) == "no room beyond boundary", "unexpected rejection reason: %s" % info.get("reason"))
	_expect_no_transition(corner_room, Vector2i(15, 8), Vector2i(1, 0))
	_expect(_room_world.primary_room_coordinates == Vector2i(1, 1), "primary room changed after rejected transition")

	var top_room := _room_world.get_room(Vector2i(0, -1))
	_expect(top_room != null, "missing room (0, -1)")
	if top_room != null:
		_place_player(Vector2i(0, -1), Vector2i(7, 0))
		_expect_no_transition(top_room, Vector2i(7, 0), Vector2i(0, -1))

func _test_contents_persist() -> void:
	for room_coordinates in [Vector2i(-1, -1), Vector2i(0, -1), Vector2i(1, -1), Vector2i(-1, 0), Vector2i(0, 0), Vector2i(1, 0), Vector2i(-1, 1), Vector2i(0, 1), Vector2i(1, 1)]:
		var room := _room_world.get_room(room_coordinates)
		_expect(room != null, "room %s missing after transitions" % room_coordinates)
		if room == null or room.block_layer == null:
			continue
		_expect(room.block_layer.blocks.size() == 3, "room %s has %d blocks after transitions, expected 3" % [room_coordinates, room.block_layer.blocks.size()])

func _test_camera_settled() -> void:
	if _camera == null or _player == null:
		return
	var expected := _player.global_position + _camera.focus_offset
	_expect(_camera.global_position.distance_to(expected) < 1.0, "camera did not follow player after transitions: %s vs %s" % [_camera.global_position, expected])

func _report() -> void:
	if _failures.is_empty():
		print("ROOM_TRANSITION_SMOKE: OK")
	else:
		for failure in _failures:
			push_error("ROOM_TRANSITION_SMOKE FAIL: " + failure)
		print("ROOM_TRANSITION_SMOKE: FAILED (%d)" % _failures.size())
