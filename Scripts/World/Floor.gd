class_name Floor
extends Resource

## A Floor is an independent environment: a named collection of rooms
## (FloorRoomSpec), explicit RoomConnection links, a default entry room,
## and a default player spawn. Floors are pure data — a FloorManager
## materializes them into a runtime RoomWorld on demand, so inactive
## floors cost nothing but their definition and save data.
##
## The 3x3 example floors are only initial content; nothing here assumes
## a fixed room count, room size, or grid arrangement.

@export var floor_id: StringName
@export var display_name := ""
## Room id (FloorRoomSpec.room_id) the player enters when this floor
## becomes active.
@export var entry_room_id := Vector2i.ZERO
## Default spawn cell in local coordinates of the entry room.
@export var spawn_position := Vector2i.ZERO
## When true, materialization generates door connections between every
## pair of rooms sharing a world-cell edge (existing RoomWorld
## mechanism). Explicit connections in `connections` are added on top.
@export var auto_connect_adjacent := true
@export var rooms: Array[FloorRoomSpec] = []
@export var connections: Array[RoomConnection] = []
## Free-form metadata for future expansion (theme, music, unlock
## requirements, ...). Not interpreted by the engine.
@export var metadata := {}

## Minimum room size in world cells: rooms must be at least this many
## cells on BOTH axes.
const MIN_ROOM_DIMENSION := 2

func room_ids() -> Array[Vector2i]:
	var ids: Array[Vector2i] = []
	for spec in rooms:
		if spec != null:
			ids.append(spec.room_id)
	return ids

func find_room_spec(room_id: Vector2i) -> FloorRoomSpec:
	for spec in rooms:
		if spec != null and spec.room_id == room_id:
			return spec
	return null
