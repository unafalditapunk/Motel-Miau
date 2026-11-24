class_name WorldSnapshot
extends RefCounted

## Server-authoritative world state transfer. The snapshot reuses the
## existing save formats verbatim — FloorSaveSystem.layout_data for
## room specs, RoomConnectionManager.serialize_all for the connection
## graph, and RoomSaveSystem.collect_room_state/apply_room_state for
## per-room contents — so there is exactly one serialization format
## for world data, shared by disk saves and the network.
##
## build() runs on the server against its live world; apply() runs on
## a client to reconstruct the same world in memory. Neither side
## touches user:// files: apply() never writes layout.json and clients
## never hydrate from local room saves.

const VERSION := 1

## Collects the authoritative world state into a JSON-safe Dictionary:
## {version, floor_id, floor_def, layout, connections, room_states}
## where room_states is an Array of {"room_id": [x, y], "state": {...}} —
## room ids are only unique per floor, so floor_id scopes them.
## floor_def is the floor_def.json-format definition so clients can
## register floors the server created at runtime; floor_def overrides
## active_floor when materializing a non-active runtime world.
static func build(floor_manager: FloorManager, room_world: RoomWorld,
		floor_def: Floor = null) -> Dictionary:
	if floor_manager == null or room_world == null:
		push_error("WorldSnapshot.build requires a FloorManager and a RoomWorld.")
		return {}
	var def := floor_def if floor_def != null else floor_manager.active_floor
	if def == null:
		push_error("WorldSnapshot.build requires a Floor to snapshot.")
		return {}
	var room_states: Array = []
	for room in room_world.get_rooms():
		if room == null or room.block_layer == null:
			continue
		# player=null: per-player position is NOT world state; each
		# client's own avatar is placed by the spawn handshake instead.
		room_states.append({
			"room_id": [room.room_coordinates.x, room.room_coordinates.y],
			"state": RoomSaveSystem.collect_room_state(room, room.block_layer),
		})
	return {
		"version": VERSION,
		"floor_id": String(def.floor_id),
		"floor_def": FloorSaveSystem.floor_definition_data(def),
		# Authoritative floor catalog: every registered floor's
		# floor_def.json-format definition. Clients reconcile their
		# replica registry against it, so joins and missed floor
		# create/delete broadcasts self-heal on the next snapshot.
		"floors": _floor_catalog(floor_manager),
		"layout": FloorSaveSystem.layout_data(def),
		"connections": room_world.connections.serialize_all(),
		"room_states": room_states,
	}

## floor_def.json-format definition for every registered floor —
## the catalog clients use to learn about floors they never visit.
static func _floor_catalog(floor_manager: FloorManager) -> Array:
	var catalog: Array = []
	for floor_def in floor_manager.floors:
		if floor_def != null:
			catalog.append(FloorSaveSystem.floor_definition_data(floor_def))
	return catalog

## Reconstructs the server's world on a client: applies the received
## layout to the floor definition, re-materializes every room,
## restores the connection graph, then applies each room's contents.
## The local player is re-placed at the floor entry/spawn and
## floor_switched is emitted so the owning world rebinds room-scoped
## references (block layer, placement controller, camera follow).
## Returns false on any validation failure — the caller must NOT mark
## the client world-ready.
static func apply(floor_manager: FloorManager, room_world: RoomWorld,
		player: Player, data: Dictionary) -> bool:
	if floor_manager == null or room_world == null:
		push_error("WorldSnapshot.apply requires a FloorManager and a RoomWorld.")
		return false
	if int(data.get("version", -1)) != VERSION:
		push_error("WorldSnapshot.apply: unsupported snapshot version %s." % str(data.get("version")))
		return false
	# Catalog reconcile, part 1: register every floor the server knows
	# that this client lacks (server-created floors arrive here even
	# when their create broadcast was missed). Part 2 (unregistering
	# floors absent from the catalog) runs after active_floor is set
	# below, so the floor being activated is never a candidate.
	var catalog: Variant = data.get("floors")
	var catalog_ids := {}
	if catalog is Array:
		for entry in catalog:
			if not (entry is Dictionary):
				continue
			var catalog_id := StringName(str((entry as Dictionary).get("floor_id", "")))
			if catalog_id == &"":
				continue
			catalog_ids[catalog_id] = true
			if floor_manager.get_floor(catalog_id) == null:
				var catalog_floor := floor_manager._floor_from_saved_data(entry)
				if catalog_floor != null:
					floor_manager.register_floor_replica(catalog_floor)
	var floor_id := StringName(str(data.get("floor_id", "")))
	var floor_def := floor_manager.get_floor(floor_id)
	if floor_def == null:
		# The server may run floors the client never registered
		# (runtime-created definitions). The snapshot carries the
		# floor_def.json-format definition; rebuild and register it as
		# replica state — never a local structural edit.
		var def_data: Variant = data.get("floor_def")
		if def_data is Dictionary:
			var rebuilt := floor_manager._floor_from_saved_data(def_data)
			if rebuilt != null and rebuilt.floor_id == floor_id:
				floor_manager.register_floor_replica(rebuilt)
				floor_def = rebuilt
	if floor_def == null:
		push_error("WorldSnapshot.apply: unknown floor '%s'." % floor_id)
		return false
	var layout: Variant = data.get("layout")
	if not (layout is Dictionary) \
			or not floor_manager.apply_layout_data(floor_def, layout):
		push_error("WorldSnapshot.apply: floor '%s' layout is missing or unusable." % floor_id)
		return false
	var problems := floor_manager.validate_floor(floor_def)
	if not problems.is_empty():
		push_error("WorldSnapshot.apply: floor '%s' layout is invalid: %s" % [
			floor_id, ", ".join(problems)])
		return false
	# Detach the player before the rebuild so no dangling room ref
	# survives materialize_floor's room teardown.
	if player != null:
		player.room = null
	if not floor_manager.materialize_floor(floor_def, room_world):
		return false
	floor_manager.active_floor = floor_def
	# Catalog reconcile, part 2: floors the server no longer knows
	# (deleted while this client wasn't looking, or stale local
	# user:// definitions) leave the replica registry — unless one is
	# the floor we just activated, which would be a protocol divergence.
	if catalog is Array:
		for replica_floor in floor_manager.floors.duplicate():
			if replica_floor == null or catalog_ids.has(replica_floor.floor_id):
				continue
			floor_manager.unregister_floor_replica(replica_floor.floor_id)
	room_world.save_directory = floor_manager.floor_save_dir(floor_id)
	# The materialize pass already ran auto-connect; the snapshot graph
	# replaces it wholesale so the client matches the server exactly.
	room_world.connections.deserialize_all(data.get("connections", []))
	var applied := 0
	for entry in data.get("room_states", []):
		if not (entry is Dictionary):
			continue
		var room_id := _read_room_id(entry.get("room_id"))
		var room := room_world.get_room(room_id)
		if room == null:
			push_warning("WorldSnapshot.apply: state for unknown room %s skipped." % room_id)
			continue
		var state: Variant = entry.get("state")
		if state is Dictionary \
				and RoomSaveSystem.apply_room_state(room_world, room, state):
			applied += 1
		else:
			push_warning("WorldSnapshot.apply: room %s state failed compatibility; left empty." % room_id)
	floor_manager._ensure_player_placement(room_world, floor_def)
	floor_manager.floor_switched.emit(floor_def)
	print("WorldSnapshot.apply: floor '%s' reconstructed (%d room state(s) applied)." % [
		floor_id, applied])
	return true

static func _read_room_id(value: Variant) -> Vector2i:
	if value is Array and (value as Array).size() == 2:
		return Vector2i(int(value[0]), int(value[1]))
	return Vector2i(-2147483648, -2147483648)
