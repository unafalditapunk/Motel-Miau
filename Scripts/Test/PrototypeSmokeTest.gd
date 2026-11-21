extends SceneTree

var _scene: Node
var _player: Player
var _blocks: BlockLayer
var _grid: IsometricGrid
var _frames := 0
var _failures: Array[String] = []

func _initialize() -> void:
	_scene = load("res://Scenes/Test/VisualStyleTest.tscn").instantiate()
	root.add_child(_scene)
	_player = _scene.get_node("BlockLayer/Player")
	_blocks = _scene.get_node("BlockLayer")
	_grid = _player.grid

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

func _run_checks() -> void:
	_test_grid_math()
	_test_block_placement()
	_test_furniture()
	_test_player_movement()
	_test_depth_ordering()

func _test_grid_math() -> void:
	_expect(_grid != null, "player grid is null")
	if _grid == null:
		return
	for x in range(8):
		for y in range(8):
			var cell := Vector2i(x, y)
			_expect(_grid.screen_to_grid(_grid.grid_to_screen(cell)) == cell, "grid round-trip failed for " + str(cell))
	_expect(_grid.grid_to_screen(Vector2i(1, 0)) == Vector2(32, 16) + _grid.screen_offset, "grid_to_screen(1,0) wrong")
	_expect(_grid.grid_to_screen(Vector2i(0, 1)) == Vector2(-32, 16) + _grid.screen_offset, "grid_to_screen(0,1) wrong")
	var elevated := _grid.grid_to_screen(Vector2i(3, 3), 1.0)
	var flat := _grid.grid_to_screen(Vector2i(3, 3), 0.0)
	_expect(is_equal_approx(elevated.y, flat.y - _grid.height_pixels_per_unit), "elevation offset wrong")
	_expect(_grid.is_valid(Vector2i(7, 7), Vector2i(8, 8)), "is_valid rejected (7,7)")
	_expect(not _grid.is_valid(Vector2i(8, 0), Vector2i(8, 8)), "is_valid accepted (8,0)")
	_expect(not _grid.is_valid(Vector2i(-1, 0), Vector2i(8, 8)), "is_valid accepted (-1,0)")

func _test_block_placement() -> void:
	_expect(_blocks.blocks.size() == 6, "expected 6 placed occupants, got %d" % _blocks.blocks.size())
	_expect(_blocks.is_cell_occupied(Vector2i(2, 2)), "cell (2,2) should be occupied")
	_expect(_blocks.is_cell_occupied(Vector2i(4, 2)), "cell (4,2) should be occupied")
	_expect(not _blocks.is_cell_occupied(Vector2i(3, 3)), "cell (3,3) should be free")
	_expect(is_equal_approx(_blocks.get_surface_elevation(Vector2i(4, 2)), 2.0), "stack surface elevation should be 2.0, got %.2f" % _blocks.get_surface_elevation(Vector2i(4, 2)))

	var standard := _blocks.get_definition(&"standard_block")
	_expect(standard != null, "standard_block definition missing")
	if standard == null:
		return
	_expect(_blocks.can_place(standard, Vector2i(5, 5), 0.0), "can_place rejected free cell")
	_expect(not _blocks.can_place(standard, Vector2i(2, 2), 0.0), "can_place allowed overlap")
	_expect(not _blocks.can_place(standard, Vector2i(8, 7), 0.0), "can_place allowed out-of-bounds")
	_expect(_blocks.can_place(standard, Vector2i(4, 2), 2.0), "can_place rejected valid stack top")
	_expect(not _blocks.can_place(standard, Vector2i(4, 2), 1.0), "can_place allowed unsupported elevation")
	_expect(not _blocks.can_place(standard, Vector2i(4, 2), 0.5), "can_place allowed mid-air elevation")

	var placed := _blocks.place_block_id(&"standard_block", Vector2i(6, 6), 0.0)
	_expect(placed != null, "place_block_id failed on free cell")
	if placed != null:
		_expect(_blocks.is_cell_occupied(Vector2i(6, 6)), "placed block not registered")
		_blocks.remove_block(placed)
		_expect(not _blocks.is_cell_occupied(Vector2i(6, 6)), "removed block still occupies cell")

func _test_furniture() -> void:
	_expect(_blocks.furniture_catalog != null, "furniture catalog missing")
	if _blocks.furniture_catalog == null:
		return
	var chair := _blocks.furniture_catalog.get_definition(&"chair")
	_expect(chair != null, "chair definition missing")
	if chair == null:
		return
	_expect(_blocks.is_cell_occupied(Vector2i(6, 2)), "chair cell (6,2) should be occupied")
	_expect(_blocks.is_cell_occupied(Vector2i(2, 6)), "chair cell (2,6) should be occupied")
	_expect(_blocks.is_cell_occupied(Vector2i(5, 6)), "chair cell (5,6) should be occupied")
	_expect(not _blocks.can_place_furniture(chair, Vector2i(6, 2), 0.0, 0), "can_place_furniture allowed overlap")
	_expect(not _blocks.can_place_furniture(chair, Vector2i(8, 7), 0.0, 0), "can_place_furniture allowed out-of-bounds")
	_expect(_blocks.can_place_furniture(chair, Vector2i(6, 3), 0.0, 90), "can_place_furniture rejected free cell")

	var placed := _blocks.place_furniture(chair, Vector2i(6, 3), 0.0, 90)
	_expect(placed != null, "place_furniture failed on free cell")
	if placed != null:
		_expect(placed is Furniture, "placed object is not Furniture")
		_expect(placed.footprint == Vector2i(1, 1), "chair footprint should be 1x1")
		_expect(placed.furniture_rotation_degrees == 90, "chair rotation not stored")
		_expect(placed.solid, "chair should be solid")
		_expect(is_equal_approx(placed.top_z(), 1.0), "chair top_z should be 1.0")
		_expect(_blocks.is_cell_occupied(Vector2i(6, 3)), "placed furniture not registered")
		_expect(not _blocks.can_place_furniture(chair, Vector2i(6, 3), 0.0, 0), "can_place_furniture allowed placed overlap")
		_blocks.remove_block(placed)
		_expect(not _blocks.is_cell_occupied(Vector2i(6, 3)), "removed furniture still occupies cell")

	var wide := FurnitureDefinition.new()
	wide.footprint = Vector2i(2, 1)
	_expect(wide.rotated_footprint(0) == Vector2i(2, 1), "footprint rotation 0 wrong")
	_expect(wide.rotated_footprint(90) == Vector2i(1, 2), "footprint rotation 90 wrong")
	_expect(wide.rotated_footprint(180) == Vector2i(2, 1), "footprint rotation 180 wrong")
	_expect(wide.rotated_footprint(270) == Vector2i(1, 2), "footprint rotation 270 wrong")

func _test_player_movement() -> void:
	_player.move_duration = 0.0
	_player.place_at(Vector2i(3, 4), 0.0)
	_expect(_player.grid_position == Vector2i(3, 4), "place_at failed")
	_expect(_player.can_move_to(Vector2i(4, 4)), "can_move_to rejected free neighbor")
	_expect(_player.can_move_to(Vector2i(2, 2)), "can_move_to rejected one-block climb")
	_expect(not _player.can_move_to(Vector2i(-1, 0)), "can_move_to allowed negative cell")
	_expect(not _player.can_move_to(Vector2i(8, 0)), "can_move_to allowed out-of-bounds cell")
	_expect(not _player.can_move_to(Vector2i(4, 2)), "can_move_to allowed two-block climb")
	_expect(not _player.can_move_to(Vector2i(6, 2)), "can_move_to allowed furniture cell")
	_expect(_player.can_move_to(Vector2i(7, 7)), "can_move_to rejected far free cell")
	_expect(is_equal_approx(_player.stand_elevation_at(Vector2i(4, 2)), 2.0), "stand_elevation_at stack wrong")
	_expect(_player.move_to(Vector2i(4, 4)), "move_to failed on free cell")
	_expect(_player.grid_position == Vector2i(4, 4), "move_to did not update grid_position")
	_expect(not _player.move_to(Vector2i(4, 2)), "move_to succeeded climbing two blocks")
	_expect(_player.grid_position == Vector2i(4, 4), "failed move_to changed position")
	_expect(_player.move_to(Vector2i(2, 2)), "move_to failed climbing one block")
	_expect(_player.grid_position == Vector2i(2, 2), "climb did not update grid_position")
	_expect(is_equal_approx(_player.elevation, 1.0), "climb did not set elevation to block top")
	_expect(_player.can_move_to(Vector2i(4, 2)), "can_move_to rejected one-block step onto stack top")
	_expect(_player.move_to(Vector2i(4, 2)), "move_to failed stepping onto stack top")
	_expect(is_equal_approx(_player.elevation, 2.0), "stack top elevation wrong")
	_expect(not _player.move_to(Vector2i(6, 2)), "move_to allowed non-walkable furniture top")
	_expect(_player.move_to(Vector2i(2, 2)), "move_to failed descending one block")
	_expect(is_equal_approx(_player.elevation, 1.0), "descent did not lower elevation")
	_expect(_player.move_to(Vector2i(3, 4)), "move_to failed descending to floor")
	_expect(is_equal_approx(_player.elevation, 0.0), "descent did not return to floor elevation")

func _test_depth_ordering() -> void:
	var d00 := _blocks.depth_for_cell(Vector2i(0, 0), 0.0)
	var d10 := _blocks.depth_for_cell(Vector2i(1, 0), 0.0)
	var d01 := _blocks.depth_for_cell(Vector2i(0, 1), 0.0)
	var d77 := _blocks.depth_for_cell(Vector2i(7, 7), 0.0)
	_expect(d10 > d00, "depth not increasing with x")
	_expect(d01 > d00, "depth not increasing with y")
	_expect(d77 > d10, "depth not increasing overall")
	var elevated := _blocks.depth_for_cell(Vector2i(3, 3), 1.0)
	var flat := _blocks.depth_for_cell(Vector2i(3, 3), 0.0)
	_expect(elevated > flat, "elevation should increase depth")

func _report() -> void:
	if _failures.is_empty():
		print("PROTOTYPE_SMOKE: OK")
	else:
		for failure in _failures:
			push_error("PROTOTYPE_SMOKE FAIL: " + failure)
		print("PROTOTYPE_SMOKE: FAILED (%d)" % _failures.size())
