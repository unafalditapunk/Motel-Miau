class_name BlockLayer
extends Node2D

const EPSILON := 0.001

## Emitted after the layer's block set changes (place, furniture place,
## remove, clear). RoomWorld forwards this as room_content_changed for
## floor dirty tracking. Also fires during save/load application.
signal content_changed

@export var grid: IsometricGrid
@export var room_size := Vector2i(10, 10)
var room: Room
@export var cell_origin := Vector2i.ZERO
@export var compact_depth := false
@export var block_scene: PackedScene
@export var block_catalog: BlockCatalog
@export var block_placements: Array[Resource] = []
@export var furniture_catalog: FurnitureCatalog
@export var furniture_placements: Array[Resource] = []

var blocks: Array[Block] = []
var _occupancy := {}

func _ready() -> void:
	if grid == null:
		push_error("BlockLayer requires an IsometricGrid resource.")
		set_process(false)
		return
	y_sort_enabled = false
	add_to_group(&"block_layers")
	_load_placements()

func rebuild() -> void:
	clear_blocks()
	_load_placements()

func refresh_depths() -> void:
	for block in blocks:
		if is_instance_valid(block):
			block.z_index = depth_for_block(block)

func clear_blocks() -> void:
	for block in blocks:
		if is_instance_valid(block):
			block.queue_free()
	blocks.clear()
	_occupancy.clear()
	content_changed.emit()

func _load_placements() -> void:
	for placement_resource in block_placements:
		var placement := placement_resource as BlockPlacement
		if placement == null:
			push_error("Invalid block placement in BlockLayer.")
			continue
		var definition := get_definition(placement.block_id)
		if definition == null:
			push_error("Missing block definition for id: " + str(placement.block_id))
			continue
		place_block(definition, placement.grid_position, placement.elevation)
	_load_furniture_placements()

func _load_furniture_placements() -> void:
	if furniture_catalog == null:
		return
	for placement_resource in furniture_placements:
		var placement := placement_resource as FurniturePlacement
		if placement == null:
			push_error("Invalid furniture placement in BlockLayer.")
			continue
		var definition := furniture_catalog.get_definition(placement.furniture_id)
		if definition == null:
			push_error("Missing furniture definition for id: " + str(placement.furniture_id))
			continue
		place_furniture(definition, placement.grid_position, placement.elevation, placement.rotation_degrees)

func get_definition(object_id: StringName) -> BlockDefinition:
	if block_catalog == null:
		return null
	return block_catalog.get_definition(object_id)

func footprint_cells(definition: BlockDefinition, grid_position: Vector2i) -> Array[Vector2i]:
	if definition == null:
		return []
	return _footprint_cells(definition.footprint, grid_position)

func _footprint_cells(footprint: Vector2i, grid_position: Vector2i) -> Array[Vector2i]:
	var cells: Array[Vector2i] = []
	for x in range(footprint.x):
		for y in range(footprint.y):
			cells.append(grid_position + Vector2i(x, y))
	return cells

func can_place(definition: BlockDefinition, grid_position: Vector2i, elevation: float) -> bool:
	if definition == null or block_scene == null or grid == null:
		return false
	return _can_place_occupant(definition.footprint, definition.height, definition.solid, definition.requires_support, grid_position, elevation)

func can_place_furniture(definition: FurnitureDefinition, grid_position: Vector2i, elevation: float, rotation_deg: int = 0) -> bool:
	if definition == null or grid == null:
		return false
	return _can_place_occupant(definition.rotated_footprint(rotation_deg), definition.height, definition.solid, definition.requires_support, grid_position, elevation)

func _can_place_occupant(footprint: Vector2i, height: float, solid: bool, requires_support: bool, grid_position: Vector2i, elevation: float) -> bool:
	if footprint.x <= 0 or footprint.y <= 0 or height <= 0.0 or elevation < 0.0:
		return false

	var cells := _footprint_cells(footprint, grid_position)
	if cells.is_empty():
		return false
	for cell in cells:
		if cell.x < 0 or cell.y < 0 or cell.x >= room_size.x or cell.y >= room_size.y:
			return false

	if solid:
		for cell in cells:
			for entry in _occupancy.get(cell, []):
				var other := entry.get("block") as Block
				if other == null or not other.solid:
					continue
				if _intervals_overlap(elevation, elevation + height, other.elevation, other.top_z()):
					return false

	if requires_support and elevation > EPSILON:
		for cell in cells:
			if not _has_support(cell, elevation):
				return false

	return true

func place_block(definition: BlockDefinition, grid_position: Vector2i, elevation: float = 0.0) -> Block:
	if not can_place(definition, grid_position, elevation):
		push_error("Cannot place block '%s' at %s elevation %.2f." % [definition.object_id if definition != null else &"<null>", grid_position, elevation])
		return null

	var block := block_scene.instantiate() as Block
	if block == null:
		push_error("Block scene must instantiate to a Block.")
		return null

	add_child(block)
	if room != null:
		room.apply_deemphasis_to(block)
	block.setup(definition, grid_position, elevation, grid)
	block.position = _footprint_screen_position(definition.footprint, grid_position, elevation)
	block.z_index = depth_for_block(block)
	_register(block)
	content_changed.emit()
	return block

func place_block_id(object_id: StringName, grid_position: Vector2i, elevation: float = 0.0) -> Block:
	return place_block(get_definition(object_id), grid_position, elevation)

func place_furniture(definition: FurnitureDefinition, grid_position: Vector2i, elevation: float = 0.0, rotation_deg: int = 0) -> Furniture:
	if not can_place_furniture(definition, grid_position, elevation, rotation_deg):
		push_error("Cannot place furniture '%s' at %s elevation %.2f rotation %d." % [definition.object_id if definition != null else &"<null>", grid_position, elevation, rotation_deg])
		return null
	if definition.scene == null:
		push_error("Furniture definition '%s' has no scene." % definition.object_id)
		return null

	var furniture := definition.scene.instantiate() as Furniture
	if furniture == null:
		push_error("Furniture scene for '%s' is not a Furniture." % definition.object_id)
		return null

	add_child(furniture)
	if room != null:
		room.apply_deemphasis_to(furniture)
	furniture.setup_furniture(definition, grid_position, elevation, rotation_deg, grid)
	furniture.position = _footprint_screen_position(furniture.footprint, grid_position, elevation)
	furniture.z_index = depth_for_block(furniture)
	_register(furniture)
	content_changed.emit()
	return furniture

func remove_block(block: Block) -> void:
	if block == null:
		return
	_unregister(block)
	blocks.erase(block)
	if is_instance_valid(block):
		block.queue_free()
	content_changed.emit()

func get_blocks_at(cell: Vector2i) -> Array[Block]:
	var result: Array[Block] = []
	for entry in _occupancy.get(cell, []):
		var block := entry.get("block") as Block
		if block != null and is_instance_valid(block):
			result.append(block)
	return result

func is_cell_occupied(cell: Vector2i) -> bool:
	return not get_blocks_at(cell).is_empty()

func get_top_z_at(cell: Vector2i) -> float:
	var top := 0.0
	for block in get_blocks_at(cell):
		if block.solid:
			top = maxf(top, block.top_z())
	return top

func get_surface_elevation(cell: Vector2i) -> float:
	return get_top_z_at(cell)

func depth_for_cell(cell: Vector2i, elevation: float = 0.0) -> int:
	var world_cell := cell + cell_origin
	if grid != null:
		world_cell = grid.depth_cell(world_cell)
	if compact_depth:
		return (world_cell.x + world_cell.y) * 48 + world_cell.y * 6 + int(round(elevation))
	return (world_cell.x + world_cell.y) * 128 + world_cell.y * 16 + int(round(elevation))

func depth_for_block(block: Block) -> int:
	if block == null:
		return 0
	var front_cell := block.grid_position + block.footprint - Vector2i.ONE
	return depth_for_cell(front_cell, block.elevation)

func get_solid_intervals(cell: Vector2i) -> Array[Vector2]:
	var intervals: Array[Vector2] = []
	for block in get_blocks_at(cell):
		if block.solid:
			intervals.append(Vector2(block.elevation, block.top_z()))
	return intervals

func is_supported_elevation(cell: Vector2i, elevation: float) -> bool:
	if elevation <= EPSILON:
		return true
	for interval in get_solid_intervals(cell):
		if absf(interval.y - elevation) <= EPSILON:
			return true
	return false

func can_actor_occupy(cell: Vector2i, elevation: float, height: float) -> bool:
	for interval in get_solid_intervals(cell):
		if _intervals_overlap(elevation, elevation + height, interval.x, interval.y):
			return false
	return true

func can_actor_stand(cell: Vector2i, elevation: float, height: float) -> bool:
	return can_actor_occupy(cell, elevation, height) and is_supported_elevation(cell, elevation)

func is_standable_surface(cell: Vector2i, elevation: float) -> bool:
	if elevation <= EPSILON:
		return true
	var found := false
	for block in get_blocks_at(cell):
		if block == null or not is_instance_valid(block) or not block.solid:
			continue
		if absf(block.top_z() - elevation) <= EPSILON:
			found = true
			if not block.walkable:
				return false
	return found

func _register(block: Block) -> void:
	blocks.append(block)
	for cell in block.occupied_cells():
		var entries: Array = _occupancy.get(cell, [])
		entries.append({"block": block, "min_z": block.elevation, "max_z": block.top_z()})
		_occupancy[cell] = entries

func _unregister(block: Block) -> void:
	for cell in block.occupied_cells():
		var entries: Array = _occupancy.get(cell, [])
		for i in range(entries.size() - 1, -1, -1):
			if entries[i].get("block") == block:
				entries.remove_at(i)
		if entries.is_empty():
			_occupancy.erase(cell)
		else:
			_occupancy[cell] = entries

func _has_support(cell: Vector2i, elevation: float) -> bool:
	for block in get_blocks_at(cell):
		if block.solid and absf(block.top_z() - elevation) <= EPSILON:
			return true
	return false

func _intervals_overlap(min_a: float, max_a: float, min_b: float, max_b: float) -> bool:
	return min_a < max_b - EPSILON and min_b < max_a - EPSILON

func _footprint_screen_position(footprint: Vector2i, grid_position: Vector2i, elevation: float) -> Vector2:
	var center := Vector2(
		grid_position.x + (footprint.x - 1) * 0.5,
		grid_position.y + (footprint.y - 1) * 0.5
	)
	var front_offset := (footprint.x + footprint.y) * grid.tile_height * 0.25
	return grid.grid_to_screen_position(center, elevation) + Vector2(0.0, front_offset)
