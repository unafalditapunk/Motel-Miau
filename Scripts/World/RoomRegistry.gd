class_name RoomRegistry
extends RefCounted

var _rooms := {}

func register(room: Room, room_coordinates: Vector2i) -> bool:
	if room == null:
		push_error("RoomRegistry.register requires a Room.")
		return false
	if has_room(room_coordinates):
		push_warning("RoomRegistry already has a room at %s." % room_coordinates)
		return false
	if has_room_instance(room):
		push_warning("RoomRegistry already contains room instance '%s'." % room.name)
		return false
	_rooms[room_coordinates] = room
	return true

func unregister(room_coordinates: Vector2i) -> bool:
	if not _rooms.has(room_coordinates):
		return false
	_rooms.erase(room_coordinates)
	return true

func unregister_room(room: Room) -> bool:
	if room == null:
		return false
	for coordinates in _rooms.keys():
		if _rooms[coordinates] == room:
			return unregister(coordinates)
	return false

func get_room(room_coordinates: Vector2i) -> Room:
	var room = _rooms.get(room_coordinates)
	if room == null or not is_instance_valid(room):
		return null
	return room as Room

func has_room(room_coordinates: Vector2i) -> bool:
	return get_room(room_coordinates) != null

func has_room_instance(room: Room) -> bool:
	if room == null:
		return false
	for coordinates in _rooms.keys():
		var registered = _rooms[coordinates]
		if registered == room and is_instance_valid(registered):
			return true
	return false

func get_room_coordinates(room: Room) -> Vector2i:
	if room == null:
		return Vector2i.ZERO
	for coordinates in _rooms.keys():
		if _rooms[coordinates] == room:
			return coordinates
	return Vector2i.ZERO

func get_rooms() -> Array[Room]:
	var rooms: Array[Room] = []
	for coordinates in _rooms.keys():
		var room := get_room(coordinates)
		if room != null:
			rooms.append(room)
	return rooms

func clear() -> void:
	_rooms.clear()

# ------------------------------------------------------------------
# World layout queries
# ------------------------------------------------------------------
# Rooms are keyed by their unique room_coordinates ID; their position in
# the shared world grid is the room's cell_origin (global_origin) plus
# its own size. Rooms may have different sizes and arbitrary origins.

## Global cell bounds of a room: [cell_origin, cell_origin + size).
func global_bounds(room: Room) -> Rect2i:
	if room == null:
		return Rect2i()
	return Rect2i(room.cell_origin, room.size)

## Returns the registered room whose footprint contains the given
## world-grid cell, or null when no room covers it. Shape-aware: only
## real footprint cells match, not a room's bounding box.
func get_room_at_global_cell(global_cell: Vector2i) -> Room:
	for room in get_rooms():
		if room.has_footprint_cell(global_cell - room.cell_origin):
			return room
	return null

## True when the two rooms' footprints share at least one cell. Rooms
## that merely touch along an edge or corner do not overlap. Section
## pairs are tested as rects, which is exact for cell unions.
func rooms_overlap(first: Room, second: Room) -> bool:
	if first == null or second == null or first == second:
		return false
	if not global_bounds(first).intersects(global_bounds(second)):
		return false
	for section in first.global_sections():
		for other in second.global_sections():
			if section.intersects(other):
				return true
	return false

## Returns the first registered room whose bounds overlap the given
## room's bounds, or null when the layout is clear.
func find_overlap(room: Room) -> Room:
	if room == null:
		return null
	for other in get_rooms():
		if rooms_overlap(room, other):
			return other
	return null

## Human-readable layout problems (overlapping rooms). Empty means the
## layout is valid.
func validate_layout() -> Array[String]:
	var problems: Array[String] = []
	var rooms := get_rooms()
	for i in range(rooms.size()):
		for j in range(i + 1, rooms.size()):
			if rooms_overlap(rooms[i], rooms[j]):
				problems.append("rooms '%s' (%s) and '%s' (%s) overlap" % [
					rooms[i].name, rooms[i].room_coordinates,
					rooms[j].name, rooms[j].room_coordinates])
	return problems
