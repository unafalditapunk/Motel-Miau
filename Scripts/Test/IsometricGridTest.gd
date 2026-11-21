class_name IsometricGridTest
extends Node2D

@export var grid: IsometricGrid
@export var grid_size: Vector2i = Vector2i(10, 10)

var hovered_grid := Vector2i(-1, -1)

func _ready() -> void:
	if grid == null:
		push_error("IsometricGridTest requires a grid resource.")
		set_process(false)
		return
	_verify_conversions()
	queue_redraw()

func _process(_delta: float) -> void:
	var mouse_grid := grid.mouse_to_grid(get_global_mouse_position())
	if mouse_grid != hovered_grid:
		hovered_grid = mouse_grid
		queue_redraw()

func _verify_conversions() -> void:
	var ok := true
	if grid.grid_to_screen(grid.origin) != grid.screen_offset:
		push_error("grid_to_screen(origin) did not return screen_offset.")
		ok = false
	if grid.screen_to_grid(grid.screen_offset) != grid.origin:
		push_error("screen_to_grid(screen_offset) did not return origin.")
		ok = false
	for x in range(grid_size.x):
		for y in range(grid_size.y):
			var cell := Vector2i(x, y)
			var returned := grid.screen_to_grid(grid.grid_to_screen(cell))
			if returned != cell:
				push_error("Round-trip failed for " + str(cell) + " -> " + str(returned))
				ok = false
	var center := Vector2i(int(grid_size.x / 2.0), int(grid_size.y / 2.0))
	if grid.get_neighbors(center).size() != 4:
		push_error("get_neighbors did not return 4 cells.")
		ok = false
	if grid.is_valid(Vector2i(-1, 0), grid_size) or grid.is_valid(Vector2i(0, -1), grid_size):
		push_error("is_valid accepted an out-of-bounds cell.")
		ok = false
	if not grid.is_valid(Vector2i.ZERO, grid_size):
		push_error("is_valid rejected the origin cell.")
		ok = false
	if grid.is_valid(Vector2i(grid_size.x, 0), grid_size) or grid.is_valid(Vector2i(0, grid_size.y), grid_size):
		push_error("is_valid accepted a cell beyond room_size.")
		ok = false
	for cell in [Vector2i.ZERO, Vector2i(grid_size.x - 1, 0), Vector2i(0, grid_size.y - 1), Vector2i(grid_size.x - 1, grid_size.y - 1)]:
		var center_screen := grid.grid_to_screen(cell)
		if grid.screen_to_grid(center_screen) != cell:
			push_error("Corner/edge cell " + str(cell) + " did not round-trip.")
			ok = false
		var probes := [
			center_screen + Vector2(0.0, -grid.tile_height * 0.5),
			center_screen + Vector2(0.0, grid.tile_height * 0.5),
			center_screen + Vector2(-grid.tile_width * 0.5, 0.0),
			center_screen + Vector2(grid.tile_width * 0.5, 0.0),
		]
		for probe in probes:
			var hit := grid.screen_to_grid(probe)
			if not grid.is_valid(hit, grid_size):
				push_error("Diamond vertex probe for " + str(cell) + " produced out-of-bounds " + str(hit))
				ok = false
	if ok:
		print("IsometricGridTest: coordinate round-trip OK for " + str(grid_size))

func _draw() -> void:
	if grid == null:
		return
	for x in range(grid_size.x):
		for y in range(grid_size.y):
			_draw_cell(Vector2i(x, y))
	if grid.is_valid(hovered_grid, grid_size):
		_draw_highlight(grid.grid_to_screen(hovered_grid))

func _cell_points(center: Vector2) -> PackedVector2Array:
	var half_width := grid.tile_width * 0.5
	var half_height := grid.tile_height * 0.5
	return PackedVector2Array([
		center + Vector2(0.0, -half_height),
		center + Vector2(half_width, 0.0),
		center + Vector2(0.0, half_height),
		center + Vector2(-half_width, 0.0),
	])

func _draw_cell(cell: Vector2i) -> void:
	var center := grid.grid_to_screen(cell)
	var points := _cell_points(center)
	var even := (cell.x + cell.y) % 2 == 0
	var fill := Color(0.30, 0.50, 0.70, 0.28) if even else Color(0.38, 0.58, 0.78, 0.28)
	if cell == grid.origin:
		fill = Color(0.90, 0.55, 0.20, 0.35)
	draw_colored_polygon(points, fill)
	draw_polyline(PackedVector2Array([points[0], points[1], points[2], points[3], points[0]]), Color(1.0, 1.0, 1.0, 0.75), 1.0)

func _draw_highlight(center: Vector2) -> void:
	var points := _cell_points(center)
	draw_colored_polygon(points, Color(1.0, 0.85, 0.20, 0.25))
	draw_polyline(PackedVector2Array([points[0], points[1], points[2], points[3], points[0]]), Color(1.0, 0.90, 0.20, 1.0), 2.0)
