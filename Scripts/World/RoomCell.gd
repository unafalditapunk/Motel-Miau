class_name RoomCell
extends RefCounted

var coordinates := Vector2i.ZERO
var walkable := true
var occupied := false
var height_level := 0
var occupant: Node = null
var tile: TileDefinition = null
var tile_elevation := 0.0
var carpet: CarpetDefinition = null
var carpet_anchor := Vector2i(-1, -1)
var carpet_rotation_degrees := 0
var carpet_flip := false
var carpet_elevation := 0.0

func _init(cell_coordinates: Vector2i = Vector2i.ZERO, is_walkable: bool = true) -> void:
	coordinates = cell_coordinates
	walkable = is_walkable

func occupy(node: Node) -> void:
	occupant = node
	occupied = occupant != null

func vacate() -> void:
	occupant = null
	occupied = false
