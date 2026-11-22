extends SceneTree

var _frames := 0
var _failures: Array[String] = []
var _world: WorldBootstrap
var _room: Room
var _controller: BlockPlacementController
var _carpet: CarpetDefinition

func _initialize() -> void:
	_world = load("res://Scenes/World/WorldBootstrap.tscn").instantiate()
	root.add_child(_world)

func _process(_delta: float) -> bool:
	_frames += 1
	if _frames == 2:
		_room = _world.room
		_controller = _world.get_node_or_null("BlockPlacementController") as BlockPlacementController
		_carpet = _world.carpet_catalog.get_definition(&"flower_carpet") if _world.carpet_catalog != null else null
	if _frames < 5:
		return false
	_run_checks()
	if is_instance_valid(_world):
		_world.room = null
	_report()
	quit()
	return true

func _expect(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)

func _find_cell() -> Vector2i:
	var player_cell: Vector2i = _world.player.grid_position
	for x in range(_room.size.x):
		for y in range(_room.size.y):
			var cell := Vector2i(x, y)
			if cell == player_cell:
				continue
			if not _room.can_place_carpet(_carpet, cell, 0):
				continue
			if not _world.block_layer.get_blocks_at(cell).is_empty():
				continue
			return cell
	return Vector2i(-1, -1)

func _carpet_sprite(cell: Vector2i) -> Sprite2D:
	_world.carpet_layer._resync_carpets()
	return _world.carpet_layer._carpets.get(cell) as Sprite2D

func _check_carpet_surface(cell: Vector2i, surface: float, elevated: bool, label: String) -> void:
	var room_cell := _room.get_cell(cell)
	if room_cell == null or room_cell.carpet == null:
		_expect(false, "%s: carpet missing on cell %s" % [label, cell])
		return
	_expect(is_equal_approx(room_cell.carpet_elevation, surface),
		"%s: carpet elevation %.2f != surface %.2f" % [label, room_cell.carpet_elevation, surface])
	var sprite := _carpet_sprite(cell)
	_expect(sprite != null, "%s: CarpetLayer missing sprite" % label)
	if sprite == null:
		return
	var footprint := room_cell.carpet.rotated_footprint(room_cell.carpet_rotation_degrees)
	var center := Vector2(cell) + Vector2(footprint - Vector2i.ONE) * 0.5
	var expected_position := _room.grid.grid_to_screen_position(center, surface)
	_expect(sprite.position.is_equal_approx(expected_position),
		"%s: carpet sprite not positioned at surface height" % label)
	var front_cell := cell + footprint - Vector2i.ONE
	var expected_z := _world.carpet_layer._depth_for_cell(front_cell, surface)
	if not elevated:
		expected_z += -54 if _world.carpet_layer.compact_depth else CarpetLayer.DEPTH_OFFSET
	_expect(sprite.z_index == expected_z,
		"%s: carpet z_index %d != expected %d" % [label, sprite.z_index, expected_z])

func _select_carpet() -> void:
	_controller.selected_definition = _carpet
	_controller.rotation_degrees = 0
	_controller.flipped = false

func _run_checks() -> void:
	_expect(_world.carpet_catalog != null, "world carpet_catalog missing")
	_expect(_carpet != null, "flower_carpet definition missing")
	_expect(_world.carpet_layer != null, "world carpet_layer missing")
	if _room == null or _controller == null or _carpet == null or _world.carpet_layer == null:
		return

	var block_definition := _world.block_catalog.get_definition(&"standard_block")
	_expect(block_definition != null, "standard_block definition missing")
	if block_definition == null:
		return

	# Floor carpet: no supporting blocks, keeps the below-blocks depth offset.
	var floor_cell := _find_cell()
	_expect(floor_cell != Vector2i(-1, -1), "no free cell available for floor carpet")
	if floor_cell != Vector2i(-1, -1):
		_select_carpet()
		_expect(_controller.place_at(floor_cell), "place_at failed for floor carpet")
		_check_carpet_surface(floor_cell, 0.0, false, "floor carpet")
		_expect(not _room.can_place_carpet(_carpet, floor_cell, 0), "can_place_carpet allowed floor duplicate")
		_expect(_room.clear_cell_carpet(floor_cell), "could not clear floor carpet")

	# One block of support: carpet snaps to the block's top surface.
	var single_cell := _find_cell()
	_expect(single_cell != Vector2i(-1, -1), "no free cell available for single-block carpet")
	var single_block: Block = null
	var single_surface := 0.0
	if single_cell != Vector2i(-1, -1):
		single_block = _world.block_layer.place_block(block_definition, single_cell, 0.0)
		_expect(single_block != null, "could not place single block for carpet test")
		if single_block != null:
			single_surface = single_block.top_z()
			_select_carpet()
			_expect(_controller.place_at(single_cell), "place_at failed for carpet on first block")
			_expect(_room.get_cell_carpet(single_cell) == _carpet, "carpet not stored on single-block cell")
			_check_carpet_surface(single_cell, single_surface, true, "single-block carpet")
			_expect(not _controller.place_at(single_cell), "place_at allowed duplicate elevated carpet")
			_room.set_cell_tile(single_cell, _room.default_tile, single_surface)

	# Two or more blocks of support: carpet uses the top surface and renders
	# in front of every supporting block.
	var stack_cell := _find_cell()
	_expect(stack_cell != Vector2i(-1, -1), "no free cell available for stacked carpet")
	var lower_block: Block = null
	var upper_block: Block = null
	var stack_surface := 0.0
	if stack_cell != Vector2i(-1, -1):
		lower_block = _world.block_layer.place_block(block_definition, stack_cell, 0.0)
		_expect(lower_block != null, "could not place lower block for carpet test")
		if lower_block != null:
			upper_block = _world.block_layer.place_block(block_definition, stack_cell, lower_block.top_z())
			_expect(upper_block != null, "could not place upper block for carpet test")
			if upper_block != null:
				stack_surface = upper_block.top_z()
				_select_carpet()
				_expect(_controller.place_at(stack_cell), "place_at failed for carpet on block stack")
				_check_carpet_surface(stack_cell, stack_surface, true, "stacked carpet")

	# Hover picking resolves the supporting cell at the surface elevation.
	if single_cell != Vector2i(-1, -1):
		var single_pick := _room._pick_hovered_cell(_room.grid.grid_to_screen_position(Vector2(single_cell), single_surface))
		_expect(single_pick["cell"] == single_cell, "hover pick missed single-block carpet cell")
		_expect(is_equal_approx(float(single_pick["elevation"]), single_surface),
			"hover pick elevation %.2f != single-block surface %.2f" % [float(single_pick["elevation"]), single_surface])
	if stack_cell != Vector2i(-1, -1):
		var stack_pick := _room._pick_hovered_cell(_room.grid.grid_to_screen_position(Vector2(stack_cell), stack_surface))
		_expect(stack_pick["cell"] == stack_cell, "hover pick missed stacked carpet cell")
		_expect(is_equal_approx(float(stack_pick["elevation"]), stack_surface),
			"hover pick elevation %.2f != stack surface %.2f" % [float(stack_pick["elevation"]), stack_surface])

	# Save round-trip preserves carpet elevation.
	var data := RoomSaveSystem.collect_room_state(_room, _world.block_layer, _world.player)
	var validation := RoomSaveSystem.validate_data(data)
	_expect(validation["ok"], "carpet room data failed validation: %s" % str(validation["errors"]))
	var carpet_entries: Array = data.get("carpet_placements", [])
	var elevations := {}
	for entry in carpet_entries:
		if entry is Dictionary:
			elevations[Vector2i(int(entry.get("position", [0, 0])[0]), int(entry.get("position", [0, 0])[1]))] = float(entry.get("elevation", -1.0))
	if single_cell != Vector2i(-1, -1):
		_expect(is_equal_approx(float(elevations.get(single_cell, -1.0)), single_surface),
			"saved carpet elevation %.2f != single-block surface %.2f" % [float(elevations.get(single_cell, -1.0)), single_surface])
	if stack_cell != Vector2i(-1, -1):
		_expect(is_equal_approx(float(elevations.get(stack_cell, -1.0)), stack_surface),
			"saved carpet elevation %.2f != stack surface %.2f" % [float(elevations.get(stack_cell, -1.0)), stack_surface])
	_expect(RoomSaveSystem.apply_room_state(_world.room_world, _room, data, _world.player), "apply_room_state failed carpet round-trip")
	if single_cell != Vector2i(-1, -1):
		var restored_single := _room.get_cell(single_cell)
		_expect(restored_single != null and restored_single.carpet == _carpet, "apply_data did not restore single-block carpet")
		if restored_single != null:
			_expect(is_equal_approx(restored_single.carpet_elevation, single_surface),
				"apply_data did not restore single-block carpet elevation")
	if stack_cell != Vector2i(-1, -1):
		var restored_stack := _room.get_cell(stack_cell)
		_expect(restored_stack != null and restored_stack.carpet == _carpet, "apply_data did not restore stacked carpet")
		if restored_stack != null:
			_expect(is_equal_approx(restored_stack.carpet_elevation, stack_surface),
				"apply_data did not restore stacked carpet elevation")

	# Elevated carpets render in front of their supporting blocks.
	_world.carpet_layer._resync_carpets()
	if single_cell != Vector2i(-1, -1):
		var single_sprite := _world.carpet_layer._carpets.get(single_cell) as Sprite2D
		var single_support: Block = null
		for block in _world.block_layer.get_blocks_at(single_cell):
			if block.solid:
				single_support = block
		_expect(single_sprite != null and single_support != null and single_sprite.z_index > single_support.z_index,
			"single-block carpet should render in front of supporting block")
	if stack_cell != Vector2i(-1, -1):
		var stack_sprite := _world.carpet_layer._carpets.get(stack_cell) as Sprite2D
		var max_block_z := -1000000000
		for block in _world.block_layer.get_blocks_at(stack_cell):
			if block.solid:
				max_block_z = maxi(max_block_z, block.z_index)
		_expect(stack_sprite != null and stack_sprite.z_index > max_block_z,
			"stacked carpet should render in front of supporting blocks")

	# Removal order is top-to-bottom: carpet, then tile, then block.
	if single_cell != Vector2i(-1, -1):
		_expect(_controller.remove_at(single_cell), "remove_at failed to remove carpet")
		_expect(_room.get_cell_carpet(single_cell) == null, "carpet still present after removal")
		_expect(not _world.block_layer.get_blocks_at(single_cell).is_empty(), "remove_at removed block before tile")
		_expect(_room.get_cell_tile(single_cell) != null, "remove_at removed tile before carpet")
		_expect(_controller.remove_at(single_cell), "remove_at failed to remove tile")
		_expect(_room.get_cell_tile(single_cell) == null, "tile still present after removal")
		_expect(not _world.block_layer.get_blocks_at(single_cell).is_empty(), "remove_at removed block before tile")
		_expect(_controller.remove_at(single_cell), "remove_at failed to remove block")
		_expect(_world.block_layer.get_blocks_at(single_cell).is_empty(), "block still present after removal")
		_expect(not _controller.remove_at(single_cell), "remove_at should fail on empty cell")

func _report() -> void:
	if _failures.is_empty():
		print("CARPET_SMOKE: OK")
	else:
		for failure in _failures:
			push_error("CARPET_SMOKE FAIL: " + failure)
		print("CARPET_SMOKE: FAILED (%d)" % _failures.size())
