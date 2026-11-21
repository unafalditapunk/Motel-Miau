extends SceneTree

var _scene: Node
var _player: Player
var _frames := 0
var _failures: Array[String] = []

func _initialize() -> void:
	_scene = load("res://Scenes/Test/PlayerDirectionTest.tscn").instantiate()
	root.add_child(_scene)
	_player = _scene.get_node("PlayerDownRight")

func _process(_delta: float) -> bool:
	_frames += 1
	if _frames < 2:
		return false
	_run_checks()
	_report()
	quit()
	return true

func _expect(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)

func _check_facing(expected_direction: Vector2i, expected_animation: StringName, label: String) -> void:
	_expect(_player.facing_direction == expected_direction, label + " facing_direction mismatch: " + str(_player.facing_direction))
	_expect(_player.visual.animation == expected_animation, label + " animation mismatch: " + str(_player.visual.animation))

func _run_checks() -> void:
	_player.move_duration = 0.0
	_player.buffer_movement_input = false
	_player.place_at(Vector2i(2, 4), 0.0)

	_player.request_move(Vector2i(1, 0))
	_check_facing(Vector2i(1, 0), &"idle_down_right", "grid +X")

	_player.request_move(Vector2i(0, 1))
	_check_facing(Vector2i(0, 1), &"idle_down_left", "grid +Y")

	_player.request_move(Vector2i(-1, 0))
	_check_facing(Vector2i(-1, 0), &"idle_up_left", "grid -X")

	_player.request_move(Vector2i(0, -1))
	_check_facing(Vector2i(0, -1), &"idle_up_right", "grid -Y")

	_player.place_at(Vector2i(0, 0), 0.0)
	_player.request_move(Vector2i(-1, 0))
	_check_facing(Vector2i(0, -1), &"idle_up_right", "blocked move")

func _report() -> void:
	if _failures.is_empty():
		print("PLAYER_DIRECTION_SMOKE: OK")
	else:
		for failure in _failures:
			push_error("PLAYER_DIRECTION_SMOKE FAIL: " + failure)
		print("PLAYER_DIRECTION_SMOKE: FAILED (" + str(_failures.size()) + ")")
