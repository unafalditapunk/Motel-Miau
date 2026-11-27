extends SceneTree

var _frames := 0
var _main: Node
var _camera
var _player: Player
var _grid: IsometricGrid
var _original_player_position := Vector2i.ZERO
var _original_player_elevation := 0.0
var _failed := false
var _overview_cam_pos := Vector2.ZERO

func _initialize() -> void:
	_main = load("res://Scenes/Main/Main.tscn").instantiate()
	root.add_child(_main)

func _process(_delta: float) -> bool:
	_frames += 1
	if _frames == 1:
		_camera = _main.get_node("WorldBootstrap/WorldCamera")
		_player = _main.find_child("Player", true, false) as Player
		if _camera == null or _player == null:
			push_error("CAMERA_SMOKE: missing camera or player")
			quit(1)
			return true
		_grid = _player.grid
		_original_player_position = _player.grid_position
		_original_player_elevation = _player.elevation
		_player.move_duration = 0.0
		_camera.follow_target = _player
		_camera.follow_smoothing = 1000.0
		return false
	if _frames == 8:
		_check_follow()
		_check_zoom()
		_check_coordinate_roundtrip()
		# Zoom out to the overview level: the camera should lock to the
		# current room's center instead of trailing the player.
		_camera.set_zoom_level(_camera.zoom_levels.size() - 1)
		return false
	if _frames == 12:
		_check_overview_locked()
		_overview_cam_pos = _camera.global_position
		_player.place_at(Vector2i(2, 2), 0.0)
		return false
	if _frames == 16:
		_check_overview_holds()
		_camera.set_zoom_level(0)
		return false
	if _frames < 20:
		return false
	_check_overview_exit_snaps()
	_restore_player()

	if _failed:
		print("CAMERA_SMOKE: FAIL")
		quit(1)
	else:
		print("CAMERA_SMOKE: OK")
		quit()
	return true

func _restore_player() -> void:
	if _player != null and is_instance_valid(_player):
		_player.place_at(_original_player_position, _original_player_elevation)

func _check_follow() -> void:
	var expected: Vector2 = _player.global_position + _camera.focus_offset
	if _camera.global_position.distance_to(expected) > 1.0:
		push_error("CAMERA_SMOKE: camera did not settle on player. cam=%s expected=%s" % [_camera.global_position, expected])
		_failed = true
	_player.place_at(Vector2i(7, 6), 0.0)

func _check_zoom() -> void:
	_camera.set_zoom_level(0)
	if _camera.zoom != Vector2.ONE:
		push_error("CAMERA_SMOKE: zoom level 0 is not 1x: %s" % _camera.zoom)
		_failed = true
	_camera.zoom_in()
	if _camera.zoom.x != _camera.zoom_levels[1]:
		push_error("CAMERA_SMOKE: zoom_in did not apply level 1: %s" % _camera.zoom)
		_failed = true
	_camera.zoom_out()
	if _camera.zoom.x != _camera.zoom_levels[0]:
		push_error("CAMERA_SMOKE: zoom_out did not return to level 0: %s" % _camera.zoom)
		_failed = true
	_camera.set_zoom_level(0)

func _check_overview_locked() -> void:
	if _camera.zoom.x >= 1.0:
		push_error("CAMERA_SMOKE: overview check ran at zoom %s" % _camera.zoom.x)
		_failed = true
		return
	var center: Variant = _camera._overview_room_center(_player)
	if center == null:
		push_error("CAMERA_SMOKE: overview center is null at 0.5x (room too big or no room)")
		_failed = true
		return
	if _camera.global_position.distance_to(center) > 1.0:
		push_error("CAMERA_SMOKE: camera not locked to room center. cam=%s center=%s" % [_camera.global_position, center])
		_failed = true

func _check_overview_holds() -> void:
	if _camera.global_position.distance_to(_overview_cam_pos) > 0.5:
		push_error("CAMERA_SMOKE: overview camera moved inside the same room: %s -> %s" % [_overview_cam_pos, _camera.global_position])
		_failed = true

func _check_overview_exit_snaps() -> void:
	var expected: Vector2 = _player.global_position + _camera.focus_offset
	if _camera.global_position.distance_to(expected) > 2.0:
		push_error("CAMERA_SMOKE: camera did not snap back to player after leaving overview. cam=%s expected=%s" % [_camera.global_position, expected])
		_failed = true

func _check_coordinate_roundtrip() -> void:
	var cells := [Vector2i(0, 0), Vector2i(5, 5), Vector2i(11, 11), Vector2i(6, 4), Vector2i(3, 8)]
	for cell in cells:
		var world := _grid.grid_to_screen(cell)
		var screen: Vector2 = _camera.world_to_screen(world)
		var recovered := _grid.screen_to_grid(_camera.screen_to_world(screen))
		if recovered != cell:
			push_error("CAMERA_SMOKE: cell roundtrip failed for %s -> screen %s -> world %s -> cell %s" % [cell, screen, _camera.screen_to_world(screen), recovered])
			_failed = true
	var world_point := _player.global_position
	var screen_point: Vector2 = _camera.world_to_screen(world_point)
	var recovered_world: Vector2 = _camera.screen_to_world(screen_point)
	if recovered_world.distance_to(world_point) > 0.01:
		push_error("CAMERA_SMOKE: world/screen inverse failed: %s vs %s" % [world_point, recovered_world])
		_failed = true
