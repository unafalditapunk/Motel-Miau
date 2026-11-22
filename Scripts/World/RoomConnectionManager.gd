class_name RoomConnectionManager
extends RefCounted

## Central registry for RoomConnection resources. Owned by RoomWorld;
## validates connections against the registered rooms and answers the
## spatial/interactive transition queries used by Player movement.

var room_world: RoomWorld
var _connections := {}

func _init(world: RoomWorld = null) -> void:
	room_world = world

func set_room_world(world: RoomWorld) -> void:
	room_world = world

func _room(room_id: Vector2i) -> Room:
	if room_world == null:
		return null
	return room_world.get_room(room_id)

# ------------------------------------------------------------------
# Registration
# ------------------------------------------------------------------

func register(connection: RoomConnection) -> bool:
	if connection == null:
		push_error("RoomConnectionManager.register requires a RoomConnection.")
		return false
	if connection.connection_id == &"":
		push_error("RoomConnection has no connection_id.")
		return false
	if _connections.has(connection.connection_id):
		push_error("RoomConnectionManager already has connection '%s'." % connection.connection_id)
		return false
	if connection.source_room_id == connection.destination_room_id:
		push_error("RoomConnection '%s' links a room to itself." % connection.connection_id)
		return false
	var source := _room(connection.source_room_id)
	var destination := _room(connection.destination_room_id)
	if source == null:
		push_error("RoomConnection '%s' references missing source room %s." % [connection.connection_id, connection.source_room_id])
		return false
	if destination == null:
		push_error("RoomConnection '%s' references missing destination room %s." % [connection.connection_id, connection.destination_room_id])
		return false
	if connection.source_cells.is_empty() or connection.destination_cells.is_empty():
		push_error("RoomConnection '%s' needs at least one cell on each side." % connection.connection_id)
		return false
	for cell in connection.source_cells:
		if not _in_bounds(cell, source.size):
			push_error("RoomConnection '%s' source cell %s is outside room %s bounds %s." % [connection.connection_id, cell, connection.source_room_id, source.size])
			return false
	for cell in connection.destination_cells:
		if not _in_bounds(cell, destination.size):
			push_error("RoomConnection '%s' destination cell %s is outside room %s bounds %s." % [connection.connection_id, cell, connection.destination_room_id, destination.size])
			return false
	if _is_duplicate(connection):
		push_warning("RoomConnection '%s' duplicates an existing connection (same rooms, type and cells)." % connection.connection_id)
		return false
	_connections[connection.connection_id] = connection
	return true

## True when another connection already links the same rooms with the
## same type, interactivity and cell sets (ids ignored).
func _is_duplicate(candidate: RoomConnection) -> bool:
	for other in _connections.values():
		if other == candidate:
			continue
		if other.source_room_id != candidate.source_room_id:
			continue
		if other.destination_room_id != candidate.destination_room_id:
			continue
		if other.connection_type != candidate.connection_type:
			continue
		if other.interactive != candidate.interactive:
			continue
		if other.source_cells == candidate.source_cells and other.destination_cells == candidate.destination_cells:
			return true
	return false

func unregister(connection_id: StringName) -> bool:
	if not _connections.has(connection_id):
		return false
	_connections.erase(connection_id)
	return true

func get_connection(connection_id: StringName) -> RoomConnection:
	var connection = _connections.get(connection_id)
	if connection == null or not is_instance_valid(connection):
		return null
	return connection as RoomConnection

func has_connection(connection_id: StringName) -> bool:
	return get_connection(connection_id) != null

func get_connections_for_room(room_id: Vector2i) -> Array[RoomConnection]:
	var result: Array[RoomConnection] = []
	for connection in _connections.values():
		if connection == null or not is_instance_valid(connection):
			continue
		if connection.source_room_id == room_id or connection.destination_room_id == room_id:
			result.append(connection)
	return result

func get_all_connections() -> Array[RoomConnection]:
	var result: Array[RoomConnection] = []
	for connection in _connections.values():
		if connection != null and is_instance_valid(connection):
			result.append(connection)
	return result

func clear() -> void:
	_connections.clear()

func size() -> int:
	return _connections.size()

# ------------------------------------------------------------------
# Transition queries
# ------------------------------------------------------------------

## Spatial exit lookup: the player is standing on local_cell inside room
## and stepped out of bounds. When direction is non-zero, only connections
## whose destination room contains the neighboring world cell in that
## direction are considered — a cell on a room corner can be a covered
## exit for two different connections. Returns {"connection", "room_id",
## "cell"} for the paired entry, or {} when nothing covers the cell.
func find_exit(room: Room, local_cell: Vector2i, direction := Vector2i.ZERO) -> Dictionary:
	if room == null:
		return {}
	var room_id := room.room_coordinates
	var fallback := {}
	var neighbor_world := Vector2i.ZERO
	if direction != Vector2i.ZERO:
		neighbor_world = room.world_cell_coordinates(local_cell) + direction
	for connection in get_all_connections():
		if connection.interactive:
			continue
		var traversal := connection.traversal_for(room_id)
		if traversal.is_empty():
			continue
		var exits: Array[Vector2i] = traversal["exits"]
		if not exits.has(local_cell):
			continue
		var entries: Array[Vector2i] = traversal["entries"]
		var result := {
			"connection": connection,
			"room_id": traversal["room_id"],
			"cell": connection.entry_for(exits, entries, local_cell),
			"reversed": traversal["reversed"],
		}
		if direction == Vector2i.ZERO:
			return result
		if fallback.is_empty():
			fallback = result
		var dest_room := _room(traversal["room_id"])
		if dest_room != null and dest_room.global_bounds().has_point(neighbor_world):
			return result
	return fallback

## Interactive entry lookup: returns the transition info when the player
## steps onto local_cell inside the room with room_id, or {}.
func find_entry(room_id: Vector2i, local_cell: Vector2i) -> Dictionary:
	for connection in get_all_connections():
		if not connection.interactive:
			continue
		var traversal := connection.traversal_for(room_id)
		if traversal.is_empty():
			continue
		var exits: Array[Vector2i] = traversal["exits"]
		if not exits.has(local_cell):
			continue
		var entries: Array[Vector2i] = traversal["entries"]
		return {
			"connection": connection,
			"room_id": traversal["room_id"],
			"cell": connection.entry_for(exits, entries, local_cell),
			"reversed": traversal["reversed"],
		}
	return {}

# ------------------------------------------------------------------
# Validation & persistence
# ------------------------------------------------------------------

## Re-checks every connection against the current room layout.
## Returns human-readable problems; empty means all connections are valid.
func validate() -> Array[String]:
	var problems: Array[String] = []
	for connection in get_all_connections():
		var id := str(connection.connection_id)
		var source := _room(connection.source_room_id)
		var destination := _room(connection.destination_room_id)
		if source == null:
			problems.append("connection '%s' references missing source room %s" % [id, connection.source_room_id])
			continue
		if destination == null:
			problems.append("connection '%s' references missing destination room %s" % [id, connection.destination_room_id])
			continue
		for cell in connection.source_cells:
			if not _in_bounds(cell, source.size):
				problems.append("connection '%s' source cell %s outside room %s" % [id, cell, connection.source_room_id])
		for cell in connection.destination_cells:
			if not _in_bounds(cell, destination.size):
				problems.append("connection '%s' destination cell %s outside room %s" % [id, cell, connection.destination_room_id])
		if not connection.interactive:
			for cell in connection.source_cells:
				if not _on_boundary(cell, source.size):
					problems.append("connection '%s' spatial source cell %s is not on room %s boundary" % [id, cell, connection.source_room_id])
			if connection.bidirectional:
				for cell in connection.destination_cells:
					if not _on_boundary(cell, destination.size):
						problems.append("connection '%s' bidirectional spatial entry %s is not on room %s boundary" % [id, cell, connection.destination_room_id])
	return problems

func _in_bounds(cell: Vector2i, room_size: Vector2i) -> bool:
	return cell.x >= 0 and cell.y >= 0 and cell.x < room_size.x and cell.y < room_size.y

func _on_boundary(cell: Vector2i, room_size: Vector2i) -> bool:
	return cell.x == 0 or cell.y == 0 or cell.x == room_size.x - 1 or cell.y == room_size.y - 1

func serialize_all() -> Array:
	var data: Array = []
	for connection in get_all_connections():
		data.append({
			"id": String(connection.connection_id),
			"type": RoomConnection.type_key(connection.connection_type),
			"interactive": connection.interactive,
			"bidirectional": connection.bidirectional,
			"source_room": [connection.source_room_id.x, connection.source_room_id.y],
			"destination_room": [connection.destination_room_id.x, connection.destination_room_id.y],
			"source_cells": _serialize_cells(connection.source_cells),
			"destination_cells": _serialize_cells(connection.destination_cells),
		})
	return data

func _serialize_cells(cells: Array[Vector2i]) -> Array:
	var result: Array = []
	for cell in cells:
		result.append([cell.x, cell.y])
	return result

## Replaces the graph with connections deserialized from save data.
## Entries referencing missing rooms or invalid cells are skipped with a
## warning. Returns the number of connections successfully registered.
func deserialize_all(data: Variant) -> int:
	clear()
	if not (data is Array):
		push_error("RoomConnectionManager.deserialize_all expects an array.")
		return 0
	var loaded := 0
	for entry in data:
		if not (entry is Dictionary):
			push_warning("RoomConnectionManager: skipping non-object connection entry.")
			continue
		var connection := _deserialize(entry)
		if connection == null:
			continue
		if register(connection):
			loaded += 1
	return loaded

func _deserialize(entry: Dictionary) -> RoomConnection:
	var connection := RoomConnection.new()
	connection.connection_id = StringName(str(entry.get("id", "")))
	if connection.connection_id == &"":
		push_warning("RoomConnectionManager: connection entry missing id; skipped.")
		return null
	connection.connection_type = RoomConnection.type_from_key(str(entry.get("type", "door"))) as RoomConnection.ConnectionType
	connection.interactive = bool(entry.get("interactive", false))
	connection.bidirectional = bool(entry.get("bidirectional", true))
	connection.source_room_id = _read_id(entry.get("source_room"))
	connection.destination_room_id = _read_id(entry.get("destination_room"))
	connection.source_cells = _read_cells(entry.get("source_cells"))
	connection.destination_cells = _read_cells(entry.get("destination_cells"))
	return connection

func _read_id(value: Variant) -> Vector2i:
	if not (value is Array) or (value as Array).size() != 2:
		return Vector2i(-2147483648, -2147483648)
	var array: Array = value
	return Vector2i(int(array[0]), int(array[1]))

func _read_cells(value: Variant) -> Array[Vector2i]:
	var cells: Array[Vector2i] = []
	if not (value is Array):
		return cells
	for item in value:
		if item is Array and (item as Array).size() == 2:
			cells.append(Vector2i(int(item[0]), int(item[1])))
	return cells
