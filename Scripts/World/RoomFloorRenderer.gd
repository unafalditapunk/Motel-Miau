class_name RoomFloorRenderer
extends Node2D

var room: Room:
	set(value):
		room = value
		refresh_depth()

func _ready() -> void:
	refresh_depth()

## The floor is one flat draw pass for the whole room, so it gets a
## single z_index at the bottom of the canvas. It must sit below EVERY
## room's tiles/blocks/player, not just its own cells: "min cell depth
## - 1024" breaks once rooms sit far from depth_cell_center (depth
## values clamp at +/-4096 and the margin is smaller than the world
## depth range), letting bare-cell floor quads draw over actors.
## Floors never need ordering among themselves — ties resolve by tree
## order and only matter while rooms overlap mid-slide.
func refresh_depth() -> void:
	z_index = -4096

func _draw() -> void:
	if room == null or room.grid == null:
		return
	for x in range(room.size.x):
		for y in range(room.size.y):
			var cell := room.get_cell(Vector2i(x, y))
			if cell != null:
				_draw_cell(cell)

func _draw_cell(cell: RoomCell) -> void:
	var center := room.cell_to_screen(cell.coordinates)
	if cell.tile != null and cell.tile.sprite_texture != null:
		if room.debug_coordinates:
			_draw_coordinate_label(center, cell.coordinates)
		return
	var texture := _cell_texture(cell)
	if texture != null:
		var tile_size := Vector2(room.grid.tile_width, room.grid.tile_height)
		draw_texture_rect(texture, Rect2(center - tile_size * 0.5, tile_size), false)
	else:
		draw_colored_polygon(_cell_points(center), _cell_color(cell))
	draw_polyline(_cell_outline(center), _cell_border_color(cell), 1.0)
	if room.debug_coordinates:
		_draw_coordinate_label(center, cell.coordinates)

func _cell_texture(cell: RoomCell) -> Texture2D:
	if cell.tile != null or room.default_tile != null:
		return null
	return room.floor_texture

func _is_bare_cell(cell: RoomCell) -> bool:
	return room.default_tile != null and cell.tile == null

func _cell_points(center: Vector2) -> PackedVector2Array:
	var half_width := room.grid.tile_width * 0.5
	var half_height := room.grid.tile_height * 0.5
	return PackedVector2Array([
		center + Vector2(0.0, -half_height),
		center + Vector2(half_width, 0.0),
		center + Vector2(0.0, half_height),
		center + Vector2(-half_width, 0.0),
	])

func _cell_outline(center: Vector2) -> PackedVector2Array:
	var points := _cell_points(center)
	return PackedVector2Array([points[0], points[1], points[2], points[3], points[0]])

func _cell_color(cell: RoomCell) -> Color:
	if _is_bare_cell(cell):
		var shade := 0.15 + 0.03 * float((cell.coordinates.x + cell.coordinates.y) % 2)
		return Color(shade, shade * 0.85, shade * 0.70, 0.6)
	var color := Color(0.35, 0.55, 0.75, 0.35)
	if room.floor_colors.size() > 0:
		color = room.floor_colors[(cell.coordinates.x + cell.coordinates.y) % room.floor_colors.size()]
	if not cell.walkable:
		color = color.darkened(0.5)
	if cell.occupied:
		color = color.lerp(Color(1.0, 0.55, 0.15, 0.45), 0.45)
	if cell.height_level > 0:
		color = color.lightened(min(cell.height_level * 0.06, 0.3))
	return color

func _cell_border_color(cell: RoomCell) -> Color:
	if _is_bare_cell(cell):
		return Color(0.0, 0.0, 0.0, 0.45)
	if not cell.walkable:
		return Color(1.0, 0.35, 0.35, 0.85)
	if cell.occupied:
		return Color(1.0, 0.65, 0.20, 0.85)
	return Color(1.0, 1.0, 1.0, 0.55)

func _draw_coordinate_label(center: Vector2, coordinates: Vector2i) -> void:
	var font := ThemeDB.fallback_font
	if font == null:
		return
	var label := str(coordinates.x) + "," + str(coordinates.y)
	draw_string(font, center + Vector2(-12.0, 4.0), label, HORIZONTAL_ALIGNMENT_LEFT, -1.0, 8, Color(1.0, 1.0, 1.0, 0.9))
