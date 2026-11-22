class_name RoomConnection
extends Resource

## Explicit link between two rooms in a RoomWorld's connection graph.
##
## Spatial connections (interactive == false) trigger when the player
## steps out of the room through one of source_cells (or destination_cells
## when traversed in reverse and bidirectional is set). The player lands
## on the paired entry cell in the other room.
##
## Interactive connections (interactive == true) trigger when the player
## steps ONTO one of the connection's cells in that room; they may link
## rooms that are not physically adjacent (doors, portals, stairways).
##
## source_cells and destination_cells are parallel arrays in each room's
## LOCAL coordinates; index i of one side pairs with index i of the other.

enum ConnectionType { DOOR, CORRIDOR, STAIRWAY, PORTAL }

const TYPE_KEYS := {
	ConnectionType.DOOR: "door",
	ConnectionType.CORRIDOR: "corridor",
	ConnectionType.STAIRWAY: "stairway",
	ConnectionType.PORTAL: "portal",
}
const KEY_TYPES := {
	"door": ConnectionType.DOOR,
	"corridor": ConnectionType.CORRIDOR,
	"stairway": ConnectionType.STAIRWAY,
	"portal": ConnectionType.PORTAL,
}

@export var connection_id: StringName
@export var connection_type: ConnectionType = ConnectionType.DOOR
@export var source_room_id := Vector2i.ZERO
@export var destination_room_id := Vector2i.ZERO
@export var source_cells: Array[Vector2i] = []
@export var destination_cells: Array[Vector2i] = []
@export var interactive := false
@export var bidirectional := true

static func type_key(type: int) -> String:
	return TYPE_KEYS.get(type, "door")

static func type_from_key(key: String) -> int:
	return KEY_TYPES.get(key, ConnectionType.DOOR)

## Cells that act as exits/entries when traveling from room_id toward the
## other side, and the paired cells on the far side. Returns a Dictionary
## {"exits": Array[Vector2i], "entries": Array[Vector2i], "room_id": Vector2i}
## or an empty Dictionary when room_id does not participate.
func traversal_for(room_id: Vector2i) -> Dictionary:
	if room_id == source_room_id:
		return {"exits": source_cells, "entries": destination_cells, "room_id": destination_room_id, "reversed": false}
	if bidirectional and room_id == destination_room_id:
		return {"exits": destination_cells, "entries": source_cells, "room_id": source_room_id, "reversed": true}
	return {}

## Entry cell paired with the given exit/trigger cell. Falls back to the
## last entry when the parallel arrays differ in length.
func entry_for(exits: Array[Vector2i], entries: Array[Vector2i], cell: Vector2i) -> Vector2i:
	if entries.is_empty():
		return Vector2i(-1, -1)
	var index := exits.find(cell)
	if index < 0:
		index = 0
	return entries[mini(index, entries.size() - 1)]
