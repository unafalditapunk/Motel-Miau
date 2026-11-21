class_name RoomDefinition
extends Resource

@export var room_id: StringName
@export var display_name: String
@export var grid: IsometricGrid
@export var size: Vector2i = Vector2i(8, 8)
@export var floor_texture: Texture2D
@export var default_tile_id: StringName
@export var spawn_position: Vector2i = Vector2i(1, 1)
@export var carpet_placements: Array[Resource] = []
@export var furniture_placements: Array[Resource] = []
