class_name DebugOverlay
extends Node2D

@export var grid: IsometricGrid
@export var block_layer: BlockLayer
@export var player: Player
@export var room_size := Vector2i(8, 8)
@export var toggle_key := KEY_F3

const OVERLAY_Z_INDEX := 4096

var enabled := false
var _font: Font

func _ready() -> void:
	z_as_relative = false
	z_index = OVERLAY_Z_INDEX
	visible = false
	_font = ThemeDB.fallback_font

func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventKey):
		return
	var key_event := event as InputEventKey
	if not key_event.pressed or key_event.echo:
		return
	if key_event.physical_keycode == toggle_key:
		enabled = not enabled
		visible = enabled
		queue_redraw()
		get_viewport().set_input_as_handled()

func _process(_delta: float) -> void:
	if enabled:
		queue_redraw()

func _draw() -> void:
	if grid == null:
		return
	_draw_grid_coordinates()
	_draw_occupied_cells()
	_draw_blocks()
	_draw_player()
	_draw_hud()

func _cell_center(cell: Vector2i) -> Vector2:
	return grid.grid_to_screen_position(Vector2(cell.x, cell.y), 0.0)

func _cell_diamond(center: Vector2) -> PackedVector2Array:
	var half_width := grid.tile_width * 0.5
	var half_height := grid.tile_height * 0.5
	return PackedVector2Array([
		center + Vector2(0.0, -half_height),
		center + Vector2(half_width, 0.0),
		center + Vector2(0.0, half_height),
		center + Vector2(-half_width, 0.0),
	])

func _draw_grid_coordinates() -> void:
	if _font == null:
		return
	for x in range(room_size.x):
		for y in range(room_size.y):
			var cell := Vector2i(x, y)
			var center := _cell_center(cell)
			var label := str(x) + "," + str(y)
			draw_string(_font, center + Vector2(-10.0, -2.0), label, HORIZONTAL_ALIGNMENT_LEFT, -1.0, 8, Color(1.0, 1.0, 1.0, 0.35))

func _draw_occupied_cells() -> void:
	if block_layer == null:
		return
	for cell in block_layer._occupancy.keys():
		var center := _cell_center(cell)
		var points := _cell_diamond(center)
		draw_colored_polygon(points, Color(1.0, 0.55, 0.15, 0.18))
		draw_polyline(PackedVector2Array([points[0], points[1], points[2], points[3], points[0]]), Color(1.0, 0.65, 0.20, 0.9), 1.0)

func _draw_blocks() -> void:
	if block_layer == null or _font == null:
		return
	for block in block_layer.blocks:
		if not is_instance_valid(block):
			continue
		var center := block.position
		var label := "%s (%d,%d) z=%.1f-%.1f" % [block.block_id, block.grid_position.x, block.grid_position.y, block.elevation, block.top_z()]
		draw_string(_font, center + Vector2(-24.0, -block.height * grid.height_pixels_per_unit - 6.0), label, HORIZONTAL_ALIGNMENT_LEFT, -1.0, 8, Color(0.55, 0.9, 1.0, 0.95))

func _draw_player() -> void:
	if player == null or _font == null:
		return
	var cell := player.grid_position
	var center := _cell_center(cell)
	var points := _cell_diamond(center)
	draw_colored_polygon(points, Color(0.35, 1.0, 0.55, 0.22))
	draw_polyline(PackedVector2Array([points[0], points[1], points[2], points[3], points[0]]), Color(0.45, 1.0, 0.6, 1.0), 2.0)

	var target := player.next_move_target()
	if target != cell:
		var target_center := _cell_center(target)
		var target_points := _cell_diamond(target_center)
		draw_colored_polygon(target_points, Color(1.0, 0.35, 0.85, 0.25))
		draw_polyline(PackedVector2Array([target_points[0], target_points[1], target_points[2], target_points[3], target_points[0]]), Color(1.0, 0.4, 0.9, 1.0), 2.0)
		draw_string(_font, target_center + Vector2(-12.0, -4.0), "dest", HORIZONTAL_ALIGNMENT_LEFT, -1.0, 8, Color(1.0, 0.5, 0.95, 1.0))

func _draw_hud() -> void:
	if player == null or _font == null:
		return
	var lines := [
		"Player cell: (%d, %d)  elev: %.2f" % [player.grid_position.x, player.grid_position.y, player.elevation],
		"Facing: %s  moving: %s" % [str(player.facing_direction), str(player._is_moving)],
		"Next target: %s" % str(player.next_move_target()),
		"Blocks: %d  Occupied cells: %d" % [block_layer.blocks.size() if block_layer != null else 0, block_layer._occupancy.size() if block_layer != null else 0],
	]
	for i in range(lines.size()):
		draw_string(_font, Vector2(8.0, 16.0 + i * 12.0), lines[i], HORIZONTAL_ALIGNMENT_LEFT, -1.0, 10, Color(1.0, 1.0, 1.0, 0.95))
