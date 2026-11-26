class_name TileLayer
extends Node2D

var grid: IsometricGrid
var room: Room
var cell_origin := Vector2i.ZERO
var compact_depth := false

var _tiles: Dictionary = {}
var _resync_queued := false

func _ready() -> void:
	y_sort_enabled = false
	if room != null and not room.cells_changed.is_connected(_on_cells_changed):
		room.cells_changed.connect(_on_cells_changed)
	_resync_tiles()

func _on_cells_changed() -> void:
	if _resync_queued:
		return
	_resync_queued = true
	_resync_tiles.call_deferred()

func _resync_tiles() -> void:
	_resync_queued = false
	# Rooms pending deletion (floor switches) still receive deferred
	# resyncs; their cells would sort against the NEW floor's depth
	# center and overflow the z_index range.
	if room == null or not is_instance_valid(room) or room.is_queued_for_deletion() or grid == null:
		return
	var wanted := {}
	for coordinates in room.cells:
		var cell: RoomCell = room.cells[coordinates]
		if cell.tile != null:
			wanted[coordinates] = cell
	for coordinates in _tiles.keys():
		if not wanted.has(coordinates):
			var stale: Sprite2D = _tiles[coordinates]
			if is_instance_valid(stale):
				stale.queue_free()
			_tiles.erase(coordinates)
	for coordinates in wanted:
		_update_tile_sprite(coordinates, wanted[coordinates])

func _update_tile_sprite(coordinates: Vector2i, cell: RoomCell) -> void:
	var sprite: Sprite2D = _tiles.get(coordinates)
	if sprite == null or not is_instance_valid(sprite):
		sprite = Sprite2D.new()
		sprite.centered = true
		sprite.texture_filter = CanvasItem.TEXTURE_FILTER_PARENT_NODE
		add_child(sprite)
		_tiles[coordinates] = sprite
	var texture := cell.tile.sprite_texture if cell.tile != null else null
	sprite.texture = texture
	sprite.visible = texture != null
	var is_tall := false
	if texture != null:
		var texture_size := texture.get_size()
		is_tall = texture_size.y > grid.tile_height + 0.001
		if is_tall:
			# Tall tile: native scale, anchored so the texture's bottom
			# tile_height pixels form the cell diamond (or centered when
			# the definition asks for it). Decoration overflows upward.
			sprite.scale = Vector2.ONE
			var anchor_y := 0.0
			if cell.tile.sprite_anchor == 0:
				anchor_y = grid.tile_height * 0.5 - texture_size.y * 0.5
			sprite.position = grid.grid_to_screen_position(Vector2(coordinates), cell.tile_elevation) + Vector2(0.0, anchor_y)
		elif texture_size.x > 0.0 and texture_size.y > 0.0:
			var tile_size := Vector2(grid.tile_width, grid.tile_height)
			sprite.scale = Vector2(tile_size.x / texture_size.x, tile_size.y / texture_size.y)
			sprite.position = grid.grid_to_screen_position(Vector2(coordinates), cell.tile_elevation)
		else:
			sprite.scale = Vector2.ONE
			sprite.position = grid.grid_to_screen_position(Vector2(coordinates), cell.tile_elevation)
	else:
		sprite.scale = Vector2.ONE
		sprite.position = grid.grid_to_screen_position(Vector2(coordinates), cell.tile_elevation)
	if room != null:
		room.apply_deemphasis_to(sprite)
	# Floor tiles stay below blocks; elevated and tall tiles use surface
	# depth so they render in front of the blocks supporting them and
	# their upward decoration sorts by the cell's own depth.
	var depth := _depth_for_cell(coordinates, cell.tile_elevation)
	var depth_offset := -54 if compact_depth else -145
	sprite.z_index = depth if cell.tile_elevation > 0.001 or is_tall else depth + depth_offset

func refresh_depths() -> void:
	_resync_tiles()

func _depth_for_cell(cell: Vector2i, elevation: float) -> int:
	var world_cell := cell + cell_origin
	if grid != null:
		world_cell = grid.depth_cell(world_cell)
	if compact_depth:
		return (world_cell.x + world_cell.y) * 48 + world_cell.y * 6 + int(round(elevation))
	return (world_cell.x + world_cell.y) * 128 + world_cell.y * 16 + int(round(elevation))
