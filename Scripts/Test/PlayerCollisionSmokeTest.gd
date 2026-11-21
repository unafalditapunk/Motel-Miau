extends SceneTree

var _scene: Node
var _player: Player
var _blocks: BlockLayer
var _frames := 0
var _failures: Array[String] = []

func _initialize() -> void:
	_scene = load("res://Scenes/Test/CollisionTest.tscn").instantiate()
	root.add_child(_scene)
	_player = _scene.get_node("BlockLayer/Player")
	_blocks = _scene.get_node("BlockLayer")

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

func _blocked(from: Vector2i, direction: Vector2i) -> bool:
	_player.place_at(from, 0.0)
	_player.move_duration = 0.0
	_player.request_move(direction)
	return _player.grid_position == from

func _run_checks() -> void:
	_player.move_duration = 0.0

	_expect(not _blocked(Vector2i(2, 3), Vector2i(1, 0)), "single block east climb was blocked")
	_expect(_player.elevation == 1.0, "single block climb did not reach elevation 1.0")
	_expect(not _blocked(Vector2i(4, 3), Vector2i(-1, 0)), "single block west climb was blocked")
	_expect(_player.elevation == 1.0, "single block climb did not reach elevation 1.0")
	_expect(_player.can_move_to(Vector2i(3, 3)), "single block cell should be a valid climb target")

	_expect(not _blocked(Vector2i(4, 3), Vector2i(1, 0)), "adjacent block east climb was blocked")
	_expect(not _blocked(Vector2i(7, 3), Vector2i(-1, 0)), "adjacent block west climb was blocked")
	_expect(not _blocked(Vector2i(5, 5), Vector2i(0, -1)), "adjacent block north climb was blocked")
	_expect(not _blocked(Vector2i(5, 2), Vector2i(0, 1)), "adjacent block south climb was blocked")

	_expect(_blocked(Vector2i(7, 3), Vector2i(1, 0)), "stacked block east approach not blocked")
	_expect(_blocked(Vector2i(9, 3), Vector2i(-1, 0)), "stacked block west approach not blocked")
	_expect(not _blocks.can_actor_stand(Vector2i(8, 3), 0.0, _player.height_units), "floor stand inside stacked cell should fail")
	_expect(_blocks.can_actor_occupy(Vector2i(8, 3), 3.0, _player.height_units), "elevated occupy above stack should be possible")
	_expect(_blocks.is_supported_elevation(Vector2i(8, 3), 3.0), "stack top should be a supported elevation")
	_expect(not _player.can_move_to(Vector2i(8, 3)), "three-block climb should be rejected")
	_player.place_at(Vector2i(7, 3), 1.0)
	_expect(not _player.can_move_to(Vector2i(8, 3)), "two-block climb should be rejected")
	_player.place_at(Vector2i(7, 3), 2.0)
	_expect(_player.can_move_to(Vector2i(8, 3)), "one-block step onto stack top was rejected")

	_expect(not _blocked(Vector2i(9, 3), Vector2i(1, 0)), "front block east climb was blocked")
	_expect(not _blocked(Vector2i(10, 2), Vector2i(0, 1)), "front block south climb was blocked")
	_expect(not _blocked(Vector2i(10, 5), Vector2i(0, -1)), "standard block north climb was blocked")
	_expect(not _blocked(Vector2i(11, 4), Vector2i(-1, 0)), "standard block west climb was blocked")

	_expect(not _blocked(Vector2i(2, 6), Vector2i(0, 1)), "front obstacle south climb was blocked")
	_expect(not _blocked(Vector2i(2, 6), Vector2i(1, 0)), "front obstacle east climb was blocked")
	_expect(not _blocked(Vector2i(2, 6), Vector2i(0, -1)), "front obstacle north should be open")
	_expect(not _blocked(Vector2i(2, 6), Vector2i(-1, 0)), "front obstacle west should be open")

	_player.place_at(Vector2i(3, 3), 1.0)
	_expect(_player.move_to(Vector2i(2, 3)), "descent from block top failed")
	_expect(is_equal_approx(_player.elevation, 0.0), "descent did not return to floor elevation")

func _report() -> void:
	if _failures.is_empty():
		print("PLAYER_COLLISION_SMOKE: OK")
	else:
		for failure in _failures:
			push_error("PLAYER_COLLISION_SMOKE FAIL: " + failure)
		print("PLAYER_COLLISION_SMOKE: FAILED (" + str(_failures.size()) + ")")
