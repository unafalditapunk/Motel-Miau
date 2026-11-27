class_name Room
extends Node2D

signal cells_changed

@export var grid: IsometricGrid
@export var size := Vector2i(10, 10)
@export var default_walkable := true
@export var floor_colors: Array[Color] = [Color(0.30, 0.50, 0.70, 0.35), Color(0.38, 0.58, 0.78, 0.35)]
@export var floor_texture: Texture2D
@export var default_tile: TileDefinition
@export var debug_coordinates := false
@export var room_coordinates := Vector2i.ZERO
@export var cell_origin := Vector2i.ZERO

## World-grid origin of this room: the global cell coordinate that local
## cell (0, 0) maps to. Backed by cell_origin, which every layer already
## uses as the local->global cell offset.
var global_origin: Vector2i:
	get:
		return cell_origin
	set(value):
		cell_origin = value

var cells := {}
## Local cell -> tile_id for ground-cover patches auto-scattered at
## room creation (FloorRoomSpec.scatter_ground). These render as
## normal tile overrides but are excluded from placed-content counts
## and room saves so they never block deletion or bloat saves; a
## cell the player repaints simply stops matching and counts again.
var auto_tiles := {}
var hovered_cell: Vector2i = Vector2i(-1, -1)
var hovered_elevation := 0.0
var block_layer: BlockLayer
## Per-room visibility options (FloorRoomSpec / Creation Mode panel).
## RoomVisuals reads them live: show_from_outside=false keeps the room
## hidden until it becomes primary; show_outside=false conceals the
## block layers of edge-adjacent rooms while this room is primary.
var show_from_outside := true
var show_outside := true
## Local-space rects (position + size in room cell coords) whose union
## forms this room's footprint. Empty means the full size.x by size.y
## rectangle. `cells` only ever contains footprint cells, so every
## per-cell system (movement, building, saves, rendering) is
## shape-aware automatically.
var shape_sections: Array[Rect2i] = []
var deemphasis_material: Material = null
var is_sliding := false
var _deemphasis_nodes: Array[CanvasItem] = []

const HOVER_EPSILON := 0.001
const HOVER_TOLERANCE := 0.08

@onready var floor_renderer: RoomFloorRenderer = $FloorRenderer
@onready var hover_highlight: RoomHoverHighlight = $HoverHighlight

func _ready() -> void:
	rebuild()
	if grid == null:
		push_error("Room requires an IsometricGrid resource.")

func rebuild() -> void:
	build_cells()
	_notify_changed()

func build_cells() -> void:
	cells.clear()
	auto_tiles.clear()
	if shape_sections.is_empty():
		for x in range(size.x):
			for y in range(size.y):
				var coordinates := Vector2i(x, y)
				var cell := RoomCell.new(coordinates, default_walkable)
				cell.tile = default_tile
				cells[coordinates] = cell
		return
	for section in shape_sections:
		for x in range(section.position.x, section.end.x):
			for y in range(section.position.y, section.end.y):
				var coordinates := Vector2i(x, y)
				if cells.has(coordinates):
					continue
				var cell := RoomCell.new(coordinates, default_walkable)
				cell.tile = default_tile
				cells[coordinates] = cell

## Replaces the room's footprint with local-space rect sections and
## rebuilds the cell grid. Pass an empty array for a full rectangle.
func set_shape_sections(sections: Array[Rect2i]) -> void:
	shape_sections = sections.duplicate()
	rebuild()

## Footprint rects in global world-cell coordinates.
func global_sections() -> Array[Rect2i]:
	if shape_sections.is_empty():
		return [global_bounds()]
	var result: Array[Rect2i] = []
	for section in shape_sections:
		result.append(Rect2i(section.position + cell_origin, section.size))
	return result

func set_size(new_size: Vector2i) -> void:
	size = new_size
	rebuild()

func set_grid(new_grid: IsometricGrid) -> void:
	grid = new_grid
	_notify_changed()

func has_cell(coordinates: Vector2i) -> bool:
	return cells.has(coordinates)

## Footprint membership that does not require built cells: true when the
## local coordinate lies inside a shape section (or the full rect for
## rectangular rooms). Safe before _ready/build_cells runs — used by
## spatial queries that may run during registration.
func has_footprint_cell(local_coordinates: Vector2i) -> bool:
	if shape_sections.is_empty():
		return local_coordinates.x >= 0 and local_coordinates.y >= 0 \
			and local_coordinates.x < size.x and local_coordinates.y < size.y
	for section in shape_sections:
		if local_coordinates.x >= section.position.x \
				and local_coordinates.x < section.end.x \
				and local_coordinates.y >= section.position.y \
				and local_coordinates.y < section.end.y:
			return true
	return false

func get_cell(coordinates: Vector2i) -> RoomCell:
	var cell = cells.get(coordinates)
	if cell == null:
		return null
	return cell as RoomCell

func is_walkable(coordinates: Vector2i) -> bool:
	var cell := get_cell(coordinates)
	return cell != null and cell.walkable

func is_occupied(coordinates: Vector2i) -> bool:
	var cell := get_cell(coordinates)
	return cell != null and cell.occupied

func set_walkable(coordinates: Vector2i, value: bool) -> void:
	var cell := get_cell(coordinates)
	if cell != null:
		cell.walkable = value
		_notify_changed()

func set_occupied(coordinates: Vector2i, value: bool) -> void:
	var cell := get_cell(coordinates)
	if cell != null:
		cell.occupied = value
		_notify_changed()

func set_height_level(coordinates: Vector2i, height_level: int) -> void:
	var cell := get_cell(coordinates)
	if cell != null:
		cell.height_level = height_level
		_notify_changed()

func set_occupant(coordinates: Vector2i, occupant: Node) -> void:
	var cell := get_cell(coordinates)
	if cell != null:
		cell.occupy(occupant)
		_notify_changed()

func set_cell_tile(coordinates: Vector2i, tile: TileDefinition, elevation := 0.0) -> bool:
	var cell := get_cell(coordinates)
	if cell == null:
		return false
	cell.tile = tile
	cell.tile_elevation = elevation if tile != null else 0.0
	_notify_changed()
	return true

func clear_cell_tile(coordinates: Vector2i) -> bool:
	return set_cell_tile(coordinates, null)

func get_cell_tile(coordinates: Vector2i) -> TileDefinition:
	var cell := get_cell(coordinates)
	if cell == null:
		return null
	return cell.tile

func can_place_carpet(carpet: CarpetDefinition, coordinates: Vector2i, carpet_degrees := 0) -> bool:
	if carpet == null:
		return false
	var footprint := carpet.rotated_footprint(carpet_degrees)
	if footprint.x <= 0 or footprint.y <= 0:
		return false
	for x in range(footprint.x):
		for y in range(footprint.y):
			var cell := get_cell(coordinates + Vector2i(x, y))
			if cell == null or cell.carpet != null:
				return false
	return true

func place_carpet(carpet: CarpetDefinition, coordinates: Vector2i, carpet_degrees := 0, flip := false, elevation := 0.0) -> bool:
	if not can_place_carpet(carpet, coordinates, carpet_degrees):
		return false
	var footprint := carpet.rotated_footprint(carpet_degrees)
	var normalized_degrees := posmod(carpet_degrees, 360)
	var carpet_elevation := maxf(elevation, 0.0)
	for x in range(footprint.x):
		for y in range(footprint.y):
			var cell := get_cell(coordinates + Vector2i(x, y))
			cell.carpet = carpet
			cell.carpet_anchor = coordinates
			cell.carpet_rotation_degrees = normalized_degrees
			cell.carpet_flip = flip
			cell.carpet_elevation = carpet_elevation
	_notify_changed()
	return true

func clear_cell_carpet(coordinates: Vector2i) -> bool:
	var cell := get_cell(coordinates)
	if cell == null or cell.carpet == null:
		return false
	var carpet := cell.carpet
	var anchor := cell.carpet_anchor
	var carpet_degrees := cell.carpet_rotation_degrees
	var footprint := carpet.rotated_footprint(carpet_degrees)
	for x in range(footprint.x):
		for y in range(footprint.y):
			var covered := get_cell(anchor + Vector2i(x, y))
			if covered != null:
				covered.carpet = null
				covered.carpet_anchor = Vector2i(-1, -1)
				covered.carpet_rotation_degrees = 0
				covered.carpet_flip = false
				covered.carpet_elevation = 0.0
	_notify_changed()
	return true

func get_cell_carpet(coordinates: Vector2i) -> CarpetDefinition:
	var cell := get_cell(coordinates)
	if cell == null:
		return null
	return cell.carpet

func get_occupant(coordinates: Vector2i) -> Node:
	var cell := get_cell(coordinates)
	if cell == null:
		return null
	return cell.occupant

## Counts of player-placed contents, using the same criteria as
## RoomSaveSystem: blocks+furniture in the block layer, anchored
## carpets, and tile overrides (non-default tile or non-zero tile
## elevation). Default floor tiles do not count.
func placed_content_counts() -> Dictionary:
	var blocks := 0
	if block_layer != null:
		blocks = block_layer.blocks.size()
	var carpets := 0
	var tiles := 0
	var default_tile_id := StringName()
	if default_tile != null:
		default_tile_id = default_tile.object_id
	for cell: RoomCell in cells.values():
		if cell.carpet != null and cell.carpet_anchor == cell.coordinates:
			carpets += 1
		var tile_id := cell.tile.object_id if cell.tile != null else StringName()
		var tile_differs := tile_id != default_tile_id or not is_equal_approx(cell.tile_elevation, 0.0)
		# Auto-scattered ground patches still showing their assigned
		# tile are decoration, not player-placed content.
		if tile_differs and auto_tiles.get(cell.coordinates) == tile_id \
				and is_equal_approx(cell.tile_elevation, 0.0):
			tile_differs = false
		if tile_differs:
			tiles += 1
	return {"blocks": blocks, "carpets": carpets, "tiles": tiles}

## True when the room holds no player-placed contents — the only
## state a room deletion is allowed to discard.
func has_placed_contents() -> bool:
	for count in placed_content_counts().values():
		if int(count) > 0:
			return true
	return false

func cell_to_screen(coordinates: Vector2i) -> Vector2:
	if grid == null:
		return Vector2.ZERO
	return grid.grid_to_screen(coordinates)

func world_cell_coordinates(local_coordinates: Vector2i) -> Vector2i:
	return cell_origin + local_coordinates

func local_cell_coordinates(world_coordinates: Vector2i) -> Vector2i:
	return world_coordinates - cell_origin

## Global cell bounds of this room: [global_origin, global_origin + size).
func global_bounds() -> Rect2i:
	return Rect2i(cell_origin, size)

func cell_to_world(coordinates: Vector2i, elevation := 0.0) -> Vector2:
	if grid == null:
		return Vector2.ZERO
	var local_screen := grid.grid_to_screen(coordinates, elevation)
	if is_inside_tree():
		return to_global(local_screen)
	return position + local_screen

func world_to_cell(world_position: Vector2) -> RoomCell:
	return get_cell(world_to_cell_coordinates(world_position))

func world_to_cell_coordinates(world_position: Vector2) -> Vector2i:
	if grid == null:
		return Vector2i(-1, -1)
	var local_position := world_position
	if is_inside_tree():
		local_position = to_local(world_position)
	else:
		local_position = world_position - position
	return grid.screen_to_grid(local_position)

func screen_to_cell(screen_position: Vector2) -> RoomCell:
	if grid == null:
		return null
	return get_cell(grid.screen_to_grid(screen_position))

func screen_to_cell_coordinates(screen_position: Vector2) -> Vector2i:
	if grid == null:
		return Vector2i(-1, -1)
	return grid.screen_to_grid(screen_position)

func get_cell_under_mouse() -> RoomCell:
	return world_to_cell(get_global_mouse_position())

func set_hovered_cell(coordinates: Vector2i, elevation := 0.0) -> void:
	if coordinates == hovered_cell and is_equal_approx(elevation, hovered_elevation):
		return
	hovered_cell = coordinates
	hovered_elevation = elevation
	if hover_highlight != null:
		hover_highlight.queue_redraw()

func _process(_delta: float) -> void:
	if grid == null:
		return
	if not is_visible_in_tree() or is_sliding:
		if hovered_cell != Vector2i(-1, -1):
			set_hovered_cell(Vector2i(-1, -1), 0.0)
		return
	var local_mouse := to_local(get_global_mouse_position())
	if not cells.has(grid.screen_to_grid(local_mouse)):
		set_hovered_cell(Vector2i(-1, -1), 0.0)
		return
	var pick := _pick_hovered_cell(local_mouse)
	set_hovered_cell(pick["cell"], pick["elevation"])

func _pick_hovered_cell(mouse_position: Vector2) -> Dictionary:
	var best_cell := Vector2i(-1, -1)
	var best_elevation := 0.0
	var best_distance := INF
	for coordinates in cells:
		var cell: RoomCell = cells[coordinates]
		var top := _hover_surface_elevation(cell)
		for elevation in _hover_elevations(top):
			var center := grid.grid_to_screen_position(Vector2(coordinates), elevation)
			var distance := _diamond_distance(mouse_position, center)
			if distance > 1.0 + HOVER_TOLERANCE:
				continue
			var better := best_cell == Vector2i(-1, -1)
			if not better:
				if distance < best_distance - HOVER_EPSILON:
					better = true
				elif absf(distance - best_distance) <= HOVER_EPSILON and elevation > best_elevation:
					better = true
			if better:
				best_cell = coordinates
				best_elevation = elevation
				best_distance = distance
	return {"cell": best_cell, "elevation": best_elevation}

func _hover_surface_elevation(cell: RoomCell) -> float:
	var elevation := 0.0
	if cell != null:
		elevation = maxf(elevation, cell.tile_elevation)
		elevation = maxf(elevation, cell.carpet_elevation)
	if block_layer != null and cell != null:
		elevation = maxf(elevation, block_layer.get_top_z_at(cell.coordinates))
	return elevation

func _hover_elevations(top: float) -> Array[float]:
	if top <= HOVER_EPSILON:
		return [0.0]
	var elevations: Array[float] = [0.0]
	var elevation := 1.0
	while elevation < top - HOVER_EPSILON:
		elevations.append(elevation)
		elevation += 1.0
	if elevations.is_empty() or not is_equal_approx(elevations[elevations.size() - 1], top):
		elevations.append(top)
	return elevations

func _diamond_distance(mouse_position: Vector2, center: Vector2) -> float:
	var half := Vector2(grid.tile_width, grid.tile_height) * 0.5
	var delta := mouse_position - center
	return absf(delta.x) / half.x + absf(delta.y) / half.y

func get_neighbor_cells(coordinates: Vector2i) -> Array[RoomCell]:
	var neighbors: Array[RoomCell] = []
	if grid == null:
		return neighbors
	for neighbor_coordinates in grid.get_neighbors(coordinates):
		var cell := get_cell(neighbor_coordinates)
		if cell != null:
			neighbors.append(cell)
	return neighbors

func set_deemphasis(new_material: Material) -> void:
	clear_deemphasis()
	deemphasis_material = new_material
	if new_material == null:
		return
	var items: Array[CanvasItem] = []
	_gather_canvas_items(self, items)
	_apply_material_to_items(items, new_material)

func clear_deemphasis() -> void:
	for item in _deemphasis_nodes:
		if is_instance_valid(item):
			item.material = null
	_deemphasis_nodes.clear()
	deemphasis_material = null

func apply_deemphasis_to(node: Node) -> void:
	if deemphasis_material == null or node == null:
		return
	var items: Array[CanvasItem] = []
	_gather_canvas_items(node, items)
	_apply_material_to_items(items, deemphasis_material)

func _gather_canvas_items(node: Node, items: Array[CanvasItem]) -> void:
	if node is CanvasItem:
		items.append(node as CanvasItem)
	for child in node.get_children():
		_gather_canvas_items(child, items)

func _apply_material_to_items(items: Array[CanvasItem], new_material: Material) -> void:
	for item in items:
		if _deemphasis_nodes.has(item):
			continue
		item.material = new_material
		_deemphasis_nodes.append(item)

func _notify_changed() -> void:
	cells_changed.emit()
	if floor_renderer != null:
		floor_renderer.room = self
		floor_renderer.queue_redraw()
