class_name PlacementGhost
extends Node2D

const ALPHA := 0.5
const VALID_COLOR := Color(1.0, 1.0, 1.0, ALPHA)
const INVALID_COLOR := Color(1.0, 0.35, 0.35, ALPHA)
const BLOCK_SPRITE_OFFSET := Vector2(0.0, -31.0)
const FURNITURE_SPRITE_OFFSET := Vector2(0.0, -32.0)

var _sprite: Sprite2D
var _controller: BlockPlacementController

func _ready() -> void:
	_sprite = Sprite2D.new()
	_sprite.position = BLOCK_SPRITE_OFFSET
	add_child(_sprite)
	z_index = 4096
	visible = false

func _process(_delta: float) -> void:
	if _controller == null:
		_controller = get_tree().get_first_node_in_group(&"block_placement_controller") as BlockPlacementController
		if _controller == null:
			visible = false
			return
	var definition := _controller.get_active_definition()
	var room := _controller.room
	var layer := _controller.block_layer
	if not _controller.construction_mode or FloorEditor.any_active(get_tree()) or definition == null or room == null or room.grid == null or layer == null:
		visible = false
		return
	var world_mouse := get_viewport().get_canvas_transform().affine_inverse() * get_viewport().get_mouse_position()
	var world_cell := room.grid.screen_to_grid(world_mouse)
	var cell := world_cell - room.cell_origin
	if not room.grid.is_valid(cell, room.size):
		visible = false
		return

	if definition is TileDefinition:
		_show_tile(definition, cell, room, layer)
		return
	if definition is CarpetDefinition:
		_show_carpet(definition, cell, room, layer)
		return

	var is_furniture := definition is FurnitureDefinition
	var rotation_deg := _controller.rotation_degrees if is_furniture else 0
	var footprint := definition.rotated_footprint(rotation_deg)
	var elevation := layer.get_top_z_at(cell)
	var valid := false
	if definition is FurnitureDefinition:
		valid = layer.can_place_furniture(definition, cell, elevation, rotation_deg)
	elif definition is BlockDefinition:
		valid = layer.can_place(definition, cell, elevation)
	var footprint_cells := _footprint_world_cells(cell, footprint, room)
	for world_foot in footprint_cells:
		if _world_cell_has_player(world_foot):
			valid = false
			break

	visible = true
	_sprite.scale = Vector2.ONE
	_sprite.texture = definition.sprite_texture
	if is_furniture:
		# Same anchor-cell bottom offset as Furniture._apply_sprite_offset.
		var texture_size := _sprite.texture.get_size() if _sprite.texture != null else Vector2.ZERO
		if texture_size.y > 0.0:
			var lift := room.grid.tile_height * (1.0 - float(footprint.x + footprint.y) * 0.5)
			_sprite.position = Vector2(0.0, lift - texture_size.y * 0.5)
		else:
			_sprite.position = FURNITURE_SPRITE_OFFSET
	else:
		_sprite.position = BLOCK_SPRITE_OFFSET
	_sprite.rotation_degrees = float(rotation_deg)
	_sprite.flip_h = _controller.flipped
	_sprite.modulate = VALID_COLOR if valid else INVALID_COLOR
	position = layer._footprint_screen_position(footprint, world_cell, elevation)

func _footprint_world_cells(cell: Vector2i, footprint: Vector2i, room: Room) -> Array[Vector2i]:
	var cells: Array[Vector2i] = []
	var origin := cell + room.cell_origin
	for x in footprint.x:
		for y in footprint.y:
			cells.append(origin + Vector2i(x, y))
	return cells

func _world_cell_has_player(world_cell: Vector2i) -> bool:
	for group_name in [&"player", &"net_avatar"]:
		for node in get_tree().get_nodes_in_group(group_name):
			var player := node as Player
			if player == null:
				continue
			var player_cell := player.grid_position
			if player.room != null:
				player_cell = player.room.world_cell_coordinates(player.grid_position)
			if player_cell == world_cell:
				return true
	return false

func _show_carpet(definition: CarpetDefinition, cell: Vector2i, room: Room, layer: BlockLayer) -> void:
	visible = true
	_sprite.texture = definition.sprite_texture
	_sprite.position = Vector2.ZERO
	var rotation_deg := _controller.rotation_degrees
	var footprint := definition.rotated_footprint(rotation_deg)
	_sprite.rotation_degrees = float(rotation_deg)
	_sprite.flip_h = _controller.flipped
	var texture := _sprite.texture
	if texture != null:
		var texture_size := texture.get_size()
		if texture_size.x > 0.0 and texture_size.y > 0.0:
			var tile_size := Vector2(room.grid.tile_width, room.grid.tile_height)
			var footprint_scale := float(footprint.x + footprint.y) * 0.5
			_sprite.scale = Vector2(tile_size.x / texture_size.x, tile_size.y / texture_size.y) * footprint_scale
		else:
			_sprite.scale = Vector2.ONE
	else:
		_sprite.scale = Vector2.ONE
	var elevation := layer.get_top_z_at(cell)
	var center := Vector2(cell + room.cell_origin) + Vector2(footprint - Vector2i.ONE) * 0.5
	position = room.grid.grid_to_screen_position(center, elevation)
	_sprite.modulate = VALID_COLOR if room.can_place_carpet(definition, cell, rotation_deg) else INVALID_COLOR

func _show_tile(definition: TileDefinition, cell: Vector2i, room: Room, layer: BlockLayer) -> void:
	visible = true
	_sprite.texture = definition.sprite_texture
	_sprite.position = Vector2.ZERO
	_sprite.rotation_degrees = 0.0
	_sprite.flip_h = false
	var texture := _sprite.texture
	_sprite.scale = Vector2.ONE
	if texture != null:
		var texture_size := texture.get_size()
		if texture_size.x > 0.0 and texture_size.y > 0.0:
			if texture_size.y > room.grid.tile_height + 0.001:
				# Tall tile: same convention as TileLayer — native scale,
				# bottom tile_height px form the cell diamond.
				if definition.sprite_anchor == 0:
					_sprite.position.y = room.grid.tile_height * 0.5 - texture_size.y * 0.5
			else:
				_sprite.scale = Vector2(room.grid.tile_width / texture_size.x, room.grid.tile_height / texture_size.y)
	_sprite.modulate = VALID_COLOR
	position = room.grid.grid_to_screen_position(Vector2(cell + room.cell_origin), layer.get_top_z_at(cell))
