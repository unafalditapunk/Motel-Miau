class_name PlaceableDefinition
extends Resource

@export var object_id: StringName
@export var display_name: String
@export var footprint := Vector2i(1, 1)
@export var height := 1.0
@export var solid := true
@export var walkable := false
@export var requires_support := true
@export var sprite_texture: Texture2D

func rotated_footprint(rotation_degrees: int) -> Vector2i:
	var normalized := posmod(rotation_degrees, 360)
	if normalized == 90 or normalized == 270:
		return Vector2i(footprint.y, footprint.x)
	return footprint
