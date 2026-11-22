extends SceneTree

var _frames := 0
var _failures: Array[String] = []
var _world: WorldBootstrap
var _room: Room
var _controller: BlockPlacementController
var _tile_def: TileDefinition

func _initialize() -> void:
	_world = load("res://Scenes/World/WorldBootstrap.tscn").instantiate()
	root.add_child(_world)

func _process(_delta: float) -> bool:
	_frames += 1
	if _frames == 2:
		_room = _world.room
		_controller = _world.get_node_or_null("BlockPlacementController") as BlockPlacementController
		if _world.tile_catalog != null:
			_tile_def = _world.tile_catalog.get_definition(&"floor_iso")
	if _frames < 5:
		return false
	_reset_tiles()
	_run_checks()
	_reset_tiles()
	_report()
	quit()
	return true

func _expect(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)

func _free_cell() -> Vector2i:
	var player_cell: Vector2i = _world.player.grid_position
	for x in range(_room.size.x):
		for y in range(_room.size.y):
			var cell := Vector2i(x, y)
			if cell == player_cell:
				continue
			if _world.block_layer.is_cell_occupied(cell):
				continue
			return cell
	return Vector2i(-1, -1)

func _run_checks() -> void:
	_expect(_room != null, "world has no room")
	_expect(_world.tile_catalog != null, "world tile_catalog missing")
	_expect(_tile_def != null, "floor_iso tile definition missing")
	if _room == null or _tile_def == null:
		return
	_expect(_room.default_tile == _tile_def, "room default_tile is not floor_iso")

	var tiled_count := 0
	for coordinates in _room.cells:
		if _room.cells[coordinates].tile == _tile_def:
			tiled_count += 1
	_expect(tiled_count == _room.size.x * _room.size.y, "expected all cells pre-tiled, got %d" % tiled_count)

	var cell := _free_cell()
	_expect(cell != Vector2i(-1, -1), "no free cell available for tile tests")
	if cell == Vector2i(-1, -1):
		return

	# Destroy: clearing the tile leaves the cell bare but walkable.
	_expect(_room.clear_cell_tile(cell), "clear_cell_tile failed")
	_expect(_room.get_cell_tile(cell) == null, "cell still has a tile after clear")
	_expect(_world.player.can_move_to(cell), "player cannot move onto bare cell")

	# Rebuild via the placement controller (selected definition is floor_iso).
	_controller.selected_definition = _tile_def
	_expect(_controller.place_at(cell), "place_at failed to restore tile")
	_expect(_room.get_cell_tile(cell) == _tile_def, "tile not restored by place_at")

	# Left-click removal peels the tile once no blocks remain.
	_expect(_controller.remove_at(cell), "remove_at did not clear bare-blocked cell tile")
	_expect(_room.get_cell_tile(cell) == null, "remove_at left tile behind")
	_expect(not _controller.remove_at(cell), "remove_at should fail on fully bare cell")
	_room.set_cell_tile(cell, _tile_def)

	# Save data records the destroyed cell as an empty tile id.
	_room.clear_cell_tile(cell)
	var data := RoomSaveSystem.collect_room_state(_room, _world.block_layer, _world.player)
	var tiles: Array = data.get("tiles", [])
	var found_bare := false
	for entry in tiles:
		if entry is Dictionary and entry.get("id", "") == "" and entry.get("position") == [cell.x, cell.y]:
			found_bare = true
	_expect(found_bare, "save data missing bare-cell tile entry at %s" % str(cell))
	var validation := RoomSaveSystem.validate_data(data)
	_expect(validation["ok"], "collected room data failed validation: %s" % str(validation["errors"]))

	# Round-trip: apply_data rebuilds cells from defaults then reapplies deltas.
	RoomSaveSystem.apply_room_state(_world.room_world, _room, data, _world.player)
	_expect(_room.get_cell_tile(cell) == null, "apply_data did not restore bare cell")
	var other := _free_cell()
	if other != Vector2i(-1, -1) and other != cell:
		_expect(_room.get_cell_tile(other) == _tile_def, "apply_data lost default tile on %s" % str(other))

	# Elevated tile: placing on an occupied cell snaps to the surface height.
	var blocked := Vector2i(-1, -1)
	for coordinates in _room.cells:
		var candidate: Vector2i = coordinates
		if candidate != _world.player.grid_position and _world.block_layer.is_cell_occupied(candidate):
			blocked = candidate
			break
	if blocked != Vector2i(-1, -1):
		var surface := _world.block_layer.get_top_z_at(blocked)
		_controller.selected_definition = _tile_def
		_expect(_controller.place_at(blocked), "place_at failed on occupied cell")
		var blocked_cell := _room.get_cell(blocked)
		_expect(blocked_cell.tile == _tile_def, "tile not placed on blocked cell")
		_expect(is_equal_approx(blocked_cell.tile_elevation, surface),
			"tile elevation %.2f != surface %.2f" % [blocked_cell.tile_elevation, surface])
		_world.tile_layer._resync_tiles()
		_expect(_world.tile_layer != null and _world.tile_layer._tiles.has(blocked),
			"TileLayer missing sprite for elevated tile")
		var sprite: Sprite2D = _world.tile_layer._tiles[blocked]
		_expect(is_equal_approx(sprite.position.y, _world.room.grid.grid_to_screen_position(Vector2(blocked), surface).y),
			"elevated tile sprite not positioned at surface height")
		var surface_depth := _world.tile_layer._depth_for_cell(blocked, surface)
		var expected_z := surface_depth if surface > 0.001 else surface_depth + (-54 if _world.tile_layer.compact_depth else -145)
		_expect(sprite.z_index == expected_z, "tile z_index %d != expected %d" % [sprite.z_index, expected_z])
		var top_block_z := -2147483648
		for block in _world.block_layer.get_blocks_at(blocked):
			if block.solid:
				top_block_z = maxi(top_block_z, block.z_index)
		_expect(sprite.z_index > top_block_z, "elevated tile should render in front of supporting blocks")

		var pick := _room._pick_hovered_cell(sprite.position)
		_expect(pick["cell"] == blocked, "hover pick missed elevated tile cell")
		_expect(is_equal_approx(float(pick["elevation"]), surface),
			"hover pick elevation %.2f != tile surface %.2f" % [float(pick["elevation"]), surface])

		# Elevated tiles round-trip through save data with their elevation.
		var elevated_data := RoomSaveSystem.collect_room_state(_room, _world.block_layer, _world.player)
		var elevated_entry: Dictionary = {}
		for entry in elevated_data.get("tiles", []):
			if entry is Dictionary and entry.get("position") == [blocked.x, blocked.y]:
				elevated_entry = entry
		_expect(not elevated_entry.is_empty(), "save data missing elevated tile entry at %s" % str(blocked))
		_expect(is_equal_approx(float(elevated_entry.get("elevation", -1.0)), surface),
			"saved tile elevation %.2f != surface %.2f" % [float(elevated_entry.get("elevation", -1.0)), surface])
		_room.set_cell_tile(blocked, null)
		RoomSaveSystem.apply_room_state(_world.room_world, _room, elevated_data, _world.player)
		_expect(is_equal_approx(_room.get_cell(blocked).tile_elevation, surface),
			"apply_data did not restore elevated tile (got %.2f)" % _room.get_cell(blocked).tile_elevation)

func _reset_tiles() -> void:
	if _room == null:
		return
	for coordinates in _room.cells:
		_room.cells[coordinates].tile = _room.default_tile
		_room.cells[coordinates].tile_elevation = 0.0
	_room._notify_changed()

func _report() -> void:
	if _failures.is_empty():
		print("TILE_SMOKE: OK")
	else:
		for failure in _failures:
			push_error("TILE_SMOKE FAIL: " + failure)
		print("TILE_SMOKE: FAILED (%d)" % _failures.size())
