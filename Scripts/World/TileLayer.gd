class_name TileLayer
extends Node2D

var grid: IsometricGrid
var room: Room

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
	if room == null or grid == null:
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
		sprite.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
		add_child(sprite)
		_tiles[coordinates] = sprite
	var texture := cell.tile.sprite_texture if cell.tile != null else null
	sprite.texture = texture
	sprite.visible = texture != null
	if texture != null:
		var texture_size := texture.get_size()
		if texture_size.x > 0.0 and texture_size.y > 0.0:
			sprite.scale = Vector2(grid.tile_width / texture_size.x, grid.tile_height / texture_size.y)
		else:
			sprite.scale = Vector2.ONE
	sprite.position = grid.grid_to_screen_position(Vector2(coordinates), cell.tile_elevation)
	# Floor tiles stay below blocks; elevated tiles use surface depth so they
	# render in front of the blocks supporting them.
	var depth := _depth_for_cell(coordinates, cell.tile_elevation)
	sprite.z_index = depth - 145 if cell.tile_elevation <= 0.001 else depth

func _depth_for_cell(cell: Vector2i, elevation: float) -> int:
	return (cell.x + cell.y) * 128 + cell.y * 16 + int(round(elevation))
