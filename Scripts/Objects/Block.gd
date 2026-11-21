class_name Block
extends StaticBody2D

@export var block_id: StringName
@export var display_name: String
@export var grid_position := Vector2i.ZERO
@export var elevation := 0.0
@export var footprint := Vector2i(1, 1)
@export var height := 1.0
@export var solid := true
@export var walkable := false
@export var requires_support := true

var grid: IsometricGrid
var block_definition: BlockDefinition

const SPRITE_BASE_OFFSET := Vector2(0.0, -31.0)

@onready var collision_shape: CollisionShape2D = $CollisionShape2D
@onready var sprite: Sprite2D = $Sprite

func _ready() -> void:
	if sprite != null:
		sprite.position = SPRITE_BASE_OFFSET

func setup(definition: BlockDefinition, new_grid_position: Vector2i, new_elevation: float, grid_resource: IsometricGrid = null) -> void:
	if definition == null:
		push_error("Block.setup requires a BlockDefinition.")
		return
	block_definition = definition
	block_id = definition.object_id
	display_name = definition.display_name
	grid_position = new_grid_position
	elevation = new_elevation
	footprint = definition.footprint
	height = definition.height
	solid = definition.solid
	walkable = definition.walkable
	requires_support = definition.requires_support
	if sprite != null:
		sprite.texture = definition.sprite_texture
	grid = grid_resource
	_configure_collision()

func refresh() -> void:
	_configure_collision()

func occupied_cells() -> Array[Vector2i]:
	var cells: Array[Vector2i] = []
	for x in range(footprint.x):
		for y in range(footprint.y):
			cells.append(grid_position + Vector2i(x, y))
	return cells

func footprint_center_grid() -> Vector2:
	return Vector2(
		grid_position.x + (footprint.x - 1) * 0.5,
		grid_position.y + (footprint.y - 1) * 0.5
	)

func top_z() -> float:
	return elevation + height

func _configure_collision() -> void:
	if collision_shape == null:
		return
	if collision_shape.shape == null or not (collision_shape.shape is ConvexPolygonShape2D):
		collision_shape.shape = ConvexPolygonShape2D.new()
	var convex := collision_shape.shape as ConvexPolygonShape2D
	convex.points = _footprint_points()
	if solid:
		collision_layer = 1
		collision_mask = 1
		collision_shape.disabled = false
	else:
		collision_layer = 0
		collision_mask = 0
		collision_shape.disabled = true

func _tile_size() -> Vector2:
	if grid != null:
		return Vector2(grid.tile_width, grid.tile_height)
	return Vector2(IsoMath.TILE_WIDTH, IsoMath.TILE_HEIGHT)

func _footprint_points() -> PackedVector2Array:
	var tile_size := _tile_size()
	var tile_width := tile_size.x
	var tile_height := tile_size.y
	var fx := float(footprint.x)
	var fy := float(footprint.y)
	var front_offset := (fx + fy) * tile_height * 0.25
	return PackedVector2Array([
		Vector2((fy - fx) * tile_width * 0.25, -(fx + fy) * tile_height * 0.25 - front_offset),
		Vector2((fx + fy) * tile_width * 0.25, (fx - fy) * tile_height * 0.25 - front_offset),
		Vector2((fx - fy) * tile_width * 0.25, (fx + fy) * tile_height * 0.25 - front_offset),
		Vector2(-(fx + fy) * tile_width * 0.25, (fy - fx) * tile_height * 0.25 - front_offset),
	])
