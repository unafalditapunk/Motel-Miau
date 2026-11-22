class_name CarpetLayer
extends Node2D

const DEPTH_OFFSET := -144
const EPSILON := 0.001

var grid: IsometricGrid
var room: Room
var cell_origin := Vector2i.ZERO
var compact_depth := false

var _carpets := {}
var _resync_queued := false

func _ready() -> void:
	y_sort_enabled = false
	if room != null and not room.cells_changed.is_connected(_on_cells_changed):
		room.cells_changed.connect(_on_cells_changed)
	_resync_carpets()

func _on_cells_changed() -> void:
	if _resync_queued:
		return
	_resync_queued = true
	_resync_carpets.call_deferred()

func _resync_carpets() -> void:
	_resync_queued = false
	if room == null or grid == null:
		return
	var wanted := {}
	for coordinates in room.cells:
		var cell: RoomCell = room.cells[coordinates]
		if cell.carpet != null and cell.carpet_anchor == coordinates:
			wanted[coordinates] = cell
	for coordinates in _carpets.keys():
		if not wanted.has(coordinates):
			var stale: Sprite2D = _carpets[coordinates]
			if is_instance_valid(stale):
				stale.queue_free()
			_carpets.erase(coordinates)
	for coordinates in wanted:
		_update_carpet_sprite(coordinates, wanted[coordinates])

func _update_carpet_sprite(coordinates: Vector2i, cell: RoomCell) -> void:
	var carpet := cell.carpet
	var sprite: Sprite2D = _carpets.get(coordinates)
	if sprite == null or not is_instance_valid(sprite):
		sprite = Sprite2D.new()
		sprite.centered = true
		sprite.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
		add_child(sprite)
		_carpets[coordinates] = sprite
	var texture := carpet.sprite_texture
	var footprint := carpet.rotated_footprint(cell.carpet_rotation_degrees)
	sprite.texture = texture
	sprite.visible = texture != null
	if texture != null:
		var texture_size := texture.get_size()
		if texture_size.x > 0.0 and texture_size.y > 0.0:
			var tile_size := Vector2(grid.tile_width, grid.tile_height)
			var footprint_scale := float(footprint.x + footprint.y) * 0.5
			sprite.scale = Vector2(tile_size.x / texture_size.x, tile_size.y / texture_size.y) * footprint_scale
		else:
			sprite.scale = Vector2.ONE
	else:
		sprite.scale = Vector2.ONE
	sprite.rotation_degrees = float(cell.carpet_rotation_degrees)
	sprite.flip_h = cell.carpet_flip
	sprite.position = grid.grid_to_screen_position(_carpet_center(coordinates, footprint), cell.carpet_elevation)
	if room != null:
		room.apply_deemphasis_to(sprite)
	var front_cell := coordinates + footprint - Vector2i.ONE
	var depth := _depth_for_cell(front_cell, cell.carpet_elevation)
	var depth_offset := -54 if compact_depth else DEPTH_OFFSET
	sprite.z_index = depth + depth_offset if cell.carpet_elevation <= EPSILON else depth

func _carpet_center(anchor: Vector2i, footprint: Vector2i) -> Vector2:
	return Vector2(anchor) + Vector2(footprint - Vector2i.ONE) * 0.5

func _depth_for_cell(cell: Vector2i, elevation: float) -> int:
	var world_cell := cell + cell_origin
	if compact_depth:
		return (world_cell.x + world_cell.y) * 48 + world_cell.y * 6 + int(round(elevation))
	return (world_cell.x + world_cell.y) * 128 + world_cell.y * 16 + int(round(elevation))
