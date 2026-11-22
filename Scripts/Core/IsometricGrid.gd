class_name IsometricGrid
extends Resource

@export var tile_width := 64.0
@export var tile_height := 32.0
@export var height_pixels_per_unit := 32.0
@export var origin := Vector2i.ZERO
@export var screen_offset := Vector2.ZERO

## World cell subtracted from global cells before z_index depth sorting.
## RoomWorld recenters this from the registered room bounds so depth
## values stay inside Godot's +/-4096 canvas range no matter where rooms
## sit in the world grid. Zero means raw world-cell depth (small worlds).
var depth_cell_center := Vector2i.ZERO

## Global cell shifted into normalized depth space.
func depth_cell(global_cell: Vector2i) -> Vector2i:
	return global_cell - depth_cell_center

func grid_to_screen(grid_position: Vector2i, elevation: float = 0.0) -> Vector2:
	return grid_to_screen_position(Vector2(grid_position.x, grid_position.y), elevation)

func grid_to_screen_position(grid_position: Vector2, elevation: float = 0.0) -> Vector2:
	var relative := grid_position - Vector2(origin.x, origin.y)
	return screen_offset + Vector2(
		(relative.x - relative.y) * tile_width * 0.5,
		(relative.x + relative.y) * tile_height * 0.5 - elevation * height_pixels_per_unit
	)

func screen_to_grid(screen_position: Vector2) -> Vector2i:
	var local := screen_position - screen_offset
	var x := local.x / (tile_width * 0.5)
	var y := local.y / (tile_height * 0.5)
	var relative := Vector2i(floori((x + y) * 0.5 + 0.5), floori((y - x) * 0.5 + 0.5))
	return relative + origin

func mouse_to_grid(mouse_position: Vector2) -> Vector2i:
	return screen_to_grid(mouse_position)

func get_neighbors(grid_position: Vector2i) -> Array[Vector2i]:
	var neighbors: Array[Vector2i] = []
	neighbors.append(grid_position + Vector2i(1, 0))
	neighbors.append(grid_position + Vector2i(-1, 0))
	neighbors.append(grid_position + Vector2i(0, 1))
	neighbors.append(grid_position + Vector2i(0, -1))
	return neighbors

func is_valid(grid_position: Vector2i, size: Vector2i) -> bool:
	return grid_position.x >= 0 and grid_position.y >= 0 and grid_position.x < size.x and grid_position.y < size.y
