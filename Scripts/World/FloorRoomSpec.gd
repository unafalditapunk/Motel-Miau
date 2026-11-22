class_name FloorRoomSpec
extends Resource

## One room slot inside a Floor definition. Room IDs are only unique
## within their floor; global_origin positions the room's local (0,0)
## cell in the floor's shared world cell grid.

@export var room_id := Vector2i.ZERO
@export var global_origin := Vector2i.ZERO
## Room dimensions in cells. Vector2i.ZERO defers to room_definition's
## size, or the bound RoomWorld's default room_dimensions.
@export var size := Vector2i.ZERO
## Optional RoomDefinition supplying floor texture, default tile,
## furniture and carpet placements.
@export var room_definition: RoomDefinition
@export var floor_colors: Array[Color] = []
## Creation-Mode visibility options. show_from_outside=false hides the
## room unless the player is inside it; show_outside=false hides the
## block layers of edge-adjacent rooms while this room is primary.
@export var show_from_outside := true
@export var show_outside := true
