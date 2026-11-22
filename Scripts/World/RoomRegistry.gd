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
