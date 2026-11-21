class_name IsoMath
extends RefCounted

const TILE_WIDTH := 64.0
const TILE_HEIGHT := 32.0

static func grid_to_screen(grid_position: Vector2i) -> Vector2:
	return Vector2(
		(grid_position.x - grid_position.y) * TILE_WIDTH * 0.5,
		(grid_position.x + grid_position.y) * TILE_HEIGHT * 0.5
	)

static func screen_to_grid(screen_position: Vector2) -> Vector2i:
	var x := screen_position.x / (TILE_WIDTH * 0.5)
	var y := screen_position.y / (TILE_HEIGHT * 0.5)
	return Vector2i(roundi((x + y) * 0.5), roundi((y - x) * 0.5))
