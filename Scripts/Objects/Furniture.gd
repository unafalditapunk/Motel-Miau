class_name Furniture
extends Block

const SPRITE_OFFSET := Vector2(0.0, -32.0)

@export var furniture_id: StringName

var furniture_rotation_degrees := 0
var furniture_definition: FurnitureDefinition

func _ready() -> void:
	super()
	if sprite != null:
		sprite.position = SPRITE_OFFSET

func setup_furniture(definition: FurnitureDefinition, new_grid_position: Vector2i, new_elevation: float = 0.0, new_rotation_degrees: int = 0, grid_resource: IsometricGrid = null) -> void:
	if definition == null:
		push_error("Furniture.setup_furniture requires a FurnitureDefinition.")
		return
	furniture_definition = definition
	furniture_id = definition.object_id
	block_id = definition.object_id
	display_name = definition.display_name
	grid_position = new_grid_position
	elevation = new_elevation
	furniture_rotation_degrees = posmod(new_rotation_degrees, 360)
	footprint = definition.rotated_footprint(furniture_rotation_degrees)
	height = definition.height
	solid = definition.solid
	walkable = definition.walkable
	requires_support = definition.requires_support
	grid = grid_resource
	if sprite != null:
		sprite.texture = definition.sprite_texture
		sprite.rotation_degrees = float(posmod(furniture_rotation_degrees, 360))
		_apply_sprite_offset()
	_configure_collision()
	_update_position()

## Bottom-anchors the sprite to the ANCHOR cell's bottom vertex (the
## cell the player clicked), not the footprint's front vertex: the
## node origin sits at the footprint front for collision, so multi-cell
## pieces lift the sprite by tile_height*(1 - (fx+fy)/2). That lift is
## 0 for 1x1 (the classic -h/2 bottom anchor) and -tile_height for 2x2.
func _apply_sprite_offset() -> void:
	if sprite == null:
		return
	var texture := sprite.texture
	if texture != null:
		var texture_size := texture.get_size()
		if texture_size.y > 0.0:
			var span := float(footprint.x + footprint.y)
			var lift := _tile_size().y * (1.0 - span * 0.5)
			sprite.position = Vector2(0.0, lift - texture_size.y * 0.5)
			return
	sprite.position = SPRITE_OFFSET

func _update_position() -> void:
	if grid == null:
		return
	var center := Vector2(grid_position) + Vector2(footprint - Vector2i.ONE) * 0.5
	var front_offset := float(footprint.x + footprint.y) * _tile_size().y * 0.25
	position = grid.grid_to_screen_position(center, elevation) + Vector2(0.0, front_offset)
