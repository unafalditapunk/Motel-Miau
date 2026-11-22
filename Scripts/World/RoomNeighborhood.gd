class_name RoomNeighborhood
extends RefCounted

## Computes the visible room neighborhood for a RoomWorld: rooms within
## spatial_neighborhood_depth bounds-adjacency hops UNION rooms within
## connection_neighborhood_depth connection-graph hops of the primary room.
##
## Distances are computed once per layout/connection state and cached;
## callers must invoke invalidate() whenever rooms, connections, or the
## primary room change. Config (depths, padding) is read live from the
## owning RoomWorld so export changes take effect on the next query.

var _room_world: RoomWorld

var _connection_distances := {}
var _spatial_distances := {}
var _cache_valid := false
var _cache_signature: Array = []

func _init(room_world: RoomWorld) -> void:
	_room_world = room_world

## Drops the cached BFS results; they are rebuilt on the next query.
func invalidate() -> void:
	_cache_valid = false

## True when room_coordinates is inside the visible neighborhood: within
## spatial or connection distance of the primary room. The primary room
## itself is never its own neighbor.
func is_neighbor(room_coordinates: Vector2i) -> bool:
	if room_coordinates == _room_world.primary_room_coordinates:
		return false
	_ensure_cache()
	return int(_spatial_distances.get(room_coordinates, -1)) > 0 \
		or int(_connection_distances.get(room_coordinates, -1)) > 0

## Connection-graph distance (BFS hops) from the primary room to
## room_coordinates, or -1 when unreachable / depth disabled.
func connection_distance(room_coordinates: Vector2i) -> int:
	_ensure_cache()
	return int(_connection_distances.get(room_coordinates, -1))

## Spatial distance (bounds-adjacency BFS hops) from the primary room to
## room_coordinates, or -1 when out of range / depth disabled.
func spatial_distance(room_coordinates: Vector2i) -> int:
	_ensure_cache()
	return int(_spatial_distances.get(room_coordinates, -1))

## Room ids whose global bounds intersect room_id's bounds grown by
## neighborhood_padding — i.e. rooms physically touching or overlapping
## the given room, regardless of room ids or dimensions.
func spatial_neighbors(room_id: Vector2i) -> Array[Vector2i]:
	var room := _room_world.get_room(room_id)
	if room == null:
		return []
	var grown := room.global_bounds().grow(_room_world.neighborhood_padding)
	var result: Array[Vector2i] = []
	for other in _room_world.registry.get_rooms():
		if other == null or other == room:
			continue
		if grown.intersects(other.global_bounds()):
			result.append(other.room_coordinates)
	return result

func _ensure_cache() -> void:
	# The signature covers the primary room and every config value the BFS
	# depends on, so direct export assignment is picked up automatically.
	# Room/connection membership changes still require invalidate().
	var signature := [
		_room_world.primary_room_coordinates,
		_room_world.connection_neighborhood_depth,
		_room_world.spatial_neighborhood_depth,
		_room_world.neighborhood_padding,
	]
	if _cache_valid and signature == _cache_signature:
		return
	_cache_valid = true
	_cache_signature = signature
	_connection_distances = _bfs_connection_distances()
	_spatial_distances = _bfs_spatial_distances()

func _bfs_connection_distances() -> Dictionary:
	var distances := {_room_world.primary_room_coordinates: 0}
	if _room_world.connection_neighborhood_depth <= 0:
		return distances
	var frontier: Array[Vector2i] = [_room_world.primary_room_coordinates]
	while not frontier.is_empty():
		var next: Array[Vector2i] = []
		for room_id in frontier:
			var step := int(distances[room_id]) + 1
			if step > _room_world.connection_neighborhood_depth:
				continue
			for other in _room_world.get_connected_room_ids(room_id):
				if distances.has(other):
					continue
				distances[other] = step
				next.append(other)
		frontier = next
	return distances

func _bfs_spatial_distances() -> Dictionary:
	var distances := {_room_world.primary_room_coordinates: 0}
	if _room_world.spatial_neighborhood_depth <= 0:
		return distances
	var frontier: Array[Vector2i] = [_room_world.primary_room_coordinates]
	while not frontier.is_empty():
		var next: Array[Vector2i] = []
		for room_id in frontier:
			var step := int(distances[room_id]) + 1
			if step > _room_world.spatial_neighborhood_depth:
				continue
			for other in spatial_neighbors(room_id):
				if distances.has(other):
					continue
				distances[other] = step
				next.append(other)
		frontier = next
	return distances
