class_name CombatGrid
extends RefCounted

## Tactical query layer for turn-based combat. Read-only view over an
## existing BlockLayer + Room: it never creates cells, never writes
## occupancy, and does not modify exploration movement.
##
## Coordinate spaces:
##   - Every public method takes and returns WORLD cells (the shared
##     world grid; room.cell_origin maps world -> room-local).
##   - BlockLayer stores cells in ROOM-LOCAL coordinates, so all layer
##     queries are converted internally via room.cell_origin (falling
##     back to block_layer.cell_origin / room_size when no Room is
##     supplied).
##
## Standing model (mirrors Player.can_move_to):
##   - A cell is standable when it is inside the room footprint,
##     can_actor_stand at the cell's surface elevation for the given
##     actor height, and is_standable_surface says the top solid is
##     walkable.
##   - Each cell therefore has exactly one standing elevation: its
##     surface elevation (top solid z). This matches exploration
##     movement, where elevation always equals the surface.
##
## Line of sight:
##   - Logical grid traversal (Amanatides-Woo style DDA over unit
##     cells), never pixel raycasts.
##   - Sight originates at EYE_LEVEL of each actor's height above its
##     elevation (top of head would make cover useless; feet would
##     make every floor crack block sight).
##   - For each intermediate cell the sightline's height span is
##     compared against that cell's solid z-intervals; any overlap
##     blocks sight. Endpoint cells never block their own LOS.
##   - Cells outside the room have no geometry and never block.

const EPSILON := 0.001
const EYE_LEVEL := 0.75
const CARDINAL_DIRECTIONS: Array[Vector2i] = [
	Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)
]

var _block_layer: BlockLayer
var _room: Room

func setup(block_layer: BlockLayer, room: Room = null) -> void:
	_block_layer = block_layer
	_room = room if room != null else (block_layer.room if block_layer != null else null)

func is_ready() -> bool:
	return _block_layer != null and _block_layer.grid != null

# ------------------------------------------------------------------
# Coordinate conversion and standability
# ------------------------------------------------------------------

func _cell_origin() -> Vector2i:
	if _room != null:
		return _room.cell_origin
	if _block_layer != null:
		return _block_layer.cell_origin
	return Vector2i.ZERO

func _to_local(world_cell: Vector2i) -> Vector2i:
	return world_cell - _cell_origin()

func _has_cell(world_cell: Vector2i) -> bool:
	var local := _to_local(world_cell)
	if _room != null:
		return _room.has_footprint_cell(local)
	if _block_layer != null:
		return local.x >= 0 and local.y >= 0 \
			and local.x < _block_layer.room_size.x and local.y < _block_layer.room_size.y
	return false

func stand_elevation_at(world_cell: Vector2i) -> float:
	if _block_layer == null or not _has_cell(world_cell):
		return 0.0
	return _block_layer.get_surface_elevation(_to_local(world_cell))

func can_stand(world_cell: Vector2i, actor_height: float) -> bool:
	if _block_layer == null or not _has_cell(world_cell):
		return false
	var local := _to_local(world_cell)
	var surface := _block_layer.get_surface_elevation(local)
	return _block_layer.can_actor_stand(local, surface, actor_height) \
		and _block_layer.is_standable_surface(local, surface)

# ------------------------------------------------------------------
# Reachable cells (cardinal BFS over standable cells)
# ------------------------------------------------------------------

## BFS over cardinal neighbors. Returns {world_cell: move_cost} for
## every standable cell reachable within move_budget steps, excluding
## the start cell. Step validity mirrors exploration: the surface
## elevation difference between consecutive cells must not exceed
## max_step_height. extra_blocked lists world cells a future
## CombatSession can mark as occupied (combatants, hazards) without
## this class knowing about them.
func get_reachable_cells(from_cell: Vector2i, from_elevation: float,
		move_budget: int, actor_height: float, max_step_height: float,
		extra_blocked: Array[Vector2i] = []) -> Dictionary:
	var costs := {}
	if not is_ready() or move_budget <= 0 or not _has_cell(from_cell):
		return costs
	var blocked := {}
	for cell in extra_blocked:
		blocked[cell] = true
	var queue: Array[Vector2i] = [from_cell]
	costs[from_cell] = 0
	var head := 0
	while head < queue.size():
		var cell: Vector2i = queue[head]
		head += 1
		var cost: int = costs[cell]
		if cost >= move_budget:
			continue
		var cell_elevation := from_elevation if cell == from_cell \
			else stand_elevation_at(cell)
		for direction in CARDINAL_DIRECTIONS:
			var next := cell + direction
			if costs.has(next) or blocked.has(next):
				continue
			if not can_stand(next, actor_height):
				continue
			var next_elevation := stand_elevation_at(next)
			if absf(next_elevation - cell_elevation) > max_step_height + EPSILON:
				continue
			costs[next] = cost + 1
			queue.append(next)
	costs.erase(from_cell)
	return costs

# ------------------------------------------------------------------
# Distance
# ------------------------------------------------------------------

## Centralized combat range metric: Chebyshev distance on world cells.
## Change here to retune every range check in the game.
static func get_distance(a: Vector2i, b: Vector2i) -> int:
	return maxi(absi(a.x - b.x), absi(a.y - b.y))

# ------------------------------------------------------------------
# Line of sight
# ------------------------------------------------------------------

## True when no solid geometry blocks the sightline between two world
## cells. Elevations are the actors' feet heights; from_height /
## to_height are their full heights. See the class doc for the eye
## level and overlap rules.
func has_line_of_sight(from_cell: Vector2i, from_elevation: float, from_height: float,
		to_cell: Vector2i, to_elevation: float, to_height: float) -> bool:
	if not is_ready() or from_cell == to_cell:
		return from_cell == to_cell
	var eye_from := from_elevation + from_height * EYE_LEVEL
	var eye_to := to_elevation + to_height * EYE_LEVEL
	var trace := _trace_cells(from_cell, to_cell)
	var cells: Array = trace["cells"]
	var entries: Array = trace["entries"]
	for i in range(1, cells.size() - 1):
		var world_cell: Vector2i = cells[i]
		var local := _to_local(world_cell)
		var intervals := _block_layer.get_solid_intervals(local)
		if intervals.is_empty():
			continue
		var t_enter: float = entries[i]
		var t_exit: float = entries[i + 1] if i + 1 < entries.size() else 1.0
		var h_enter := lerpf(eye_from, eye_to, t_enter)
		var h_exit := lerpf(eye_from, eye_to, t_exit)
		var h_lo := minf(h_enter, h_exit)
		var h_hi := maxf(h_enter, h_exit)
		for interval in intervals:
			# Closed-interval overlap: a sightline grazing a solid's top
			# face still counts as blocked.
			if interval.x <= h_hi + EPSILON and interval.y >= h_lo - EPSILON:
				return false
	return true

## Ordered list of world cells the segment between two cell centers
## passes through, plus the ray parameter at which each cell is
## entered. Deterministic: ties at exact corner crossings resolve
## x-first, producing the conservative supercover path.
func _trace_cells(from_cell: Vector2i, to_cell: Vector2i) -> Dictionary:
	var cells: Array[Vector2i] = [from_cell]
	var entries: Array[float] = [0.0]
	var cx := from_cell.x
	var cy := from_cell.y
	var dx := to_cell.x - from_cell.x
	var dy := to_cell.y - from_cell.y
	var step_x := signi(dx)
	var step_y := signi(dy)
	var t_max_x := INF
	var t_max_y := INF
	var t_delta_x := INF
	var t_delta_y := INF
	if step_x != 0:
		# Cells are unit squares centered on integer coords, so the
		# first x boundary is half a cell ahead.
		t_max_x = (0.5 * step_x) / float(dx)
		t_delta_x = 1.0 / absf(float(dx))
	if step_y != 0:
		t_max_y = (0.5 * step_y) / float(dy)
		t_delta_y = 1.0 / absf(float(dy))
	while cx != to_cell.x or cy != to_cell.y:
		if t_max_x <= t_max_y:
			cx += step_x
			entries.append(t_max_x)
			t_max_x += t_delta_x
		else:
			cy += step_y
			entries.append(t_max_y)
			t_max_y += t_delta_y
		cells.append(Vector2i(cx, cy))
	return {"cells": cells, "entries": entries}

# ------------------------------------------------------------------
# Area-of-effect helpers (cell sets only, clipped to the room)
# ------------------------------------------------------------------

## All footprint cells within Chebyshev radius of center.
func get_radius_cells(center: Vector2i, radius: int) -> Array[Vector2i]:
	var result: Array[Vector2i] = []
	if radius < 0 or not is_ready():
		return result
	for x in range(center.x - radius, center.x + radius + 1):
		for y in range(center.y - radius, center.y + radius + 1):
			var cell := Vector2i(x, y)
			if get_distance(center, cell) <= radius and _has_cell(cell):
				result.append(cell)
	result.sort()
	return result

## Cardinal line of cells starting at origin (inclusive) and extending
## length steps along direction. direction must be one of the four
## cardinal vectors; anything else returns an empty array.
func get_line_cells(origin: Vector2i, direction: Vector2i, length: int) -> Array[Vector2i]:
	var result: Array[Vector2i] = []
	if length < 0 or not CARDINAL_DIRECTIONS.has(direction) or not is_ready():
		return result
	for i in range(length + 1):
		var cell := origin + direction * i
		if _has_cell(cell):
			result.append(cell)
	return result

## Union of the four cardinal lines of the given radius around
## center (a plus shape, including center).
func get_cross_cells(center: Vector2i, radius: int) -> Array[Vector2i]:
	var result: Array[Vector2i] = []
	if radius < 0 or not is_ready():
		return result
	var seen := {}
	for direction in CARDINAL_DIRECTIONS:
		for cell in get_line_cells(center, direction, radius):
			if not seen.has(cell):
				seen[cell] = true
				result.append(cell)
	result.sort()
	return result
