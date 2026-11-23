class_name FloorManager
extends Node

## Owns the world's Floor definitions and materializes them into a
## runtime RoomWorld. One FloorManager per world; it holds no global
## state, so multiple worlds can each manage their own floors.
##
## Floors are data (Floor resources). Only the active floor's rooms are
## instantiated, inside the bound RoomWorld; switching floors clears and
## rebuilds that RoomWorld. Inactive floors persist as definitions plus
## their save data.
##
## Floor resources are auto-loaded from res://Resources/Floors/ on _ready
## (any .tres that loads as a Floor). Additional floors can be registered
## manually with register_floor().

const FLOORS_DIR := "res://Resources/Floors"

## Emitted after a floor has been fully materialized, its saved state
## loaded (when present), and the player placed — i.e. the world is
## ready for the new floor. The owning world uses this to rebind
## room-scoped references (bootstrap, placement UI).
signal floor_switched(floor_def: Floor)

## The RoomWorld that hosts the active floor's rooms. Assigned by the
## owning world before activate_floor() is called.
@export var room_world: RoomWorld
## Floor definitions, loaded from FLOORS_DIR when empty.
var floors: Array[Floor] = []
var active_floor: Floor

var _by_id := {}
var _hooked_world: RoomWorld
var _dirty := false

func _ready() -> void:
	# Always scan: register_floor() deduplicates, so floors registered
	# manually before _ready coexist with resource-loaded ones.
	_load_floor_resources()

func _load_floor_resources() -> void:
	var dir := DirAccess.open(FLOORS_DIR)
	if dir == null:
		return
	for file_name in dir.get_files():
		if not file_name.ends_with(".tres"):
			continue
		var resource := ResourceLoader.load(FLOORS_DIR.path_join(file_name))
		if resource is Floor:
			register_floor(resource)

# ------------------------------------------------------------------
# Floor registry
# ------------------------------------------------------------------

func register_floor(floor_def: Floor) -> bool:
	if floor_def == null:
		push_error("FloorManager.register_floor requires a Floor.")
		return false
	if floor_def.floor_id == &"":
		push_error("Floor '%s' has no floor_id." % floor_def.display_name)
		return false
	if _by_id.has(floor_def.floor_id):
		push_error("FloorManager already has floor '%s'." % floor_def.floor_id)
		return false
	var problems := validate_floor(floor_def)
	for problem in problems:
		push_warning("Floor '%s': %s" % [floor_def.floor_id, problem])
	_by_id[floor_def.floor_id] = floor_def
	floors.append(floor_def)
	return true

func get_floor(floor_id: StringName) -> Floor:
	var floor_def = _by_id.get(floor_id)
	return floor_def as Floor

func has_floor(floor_id: StringName) -> bool:
	return _by_id.has(floor_id)

func floor_ids() -> Array[StringName]:
	var ids: Array[StringName] = []
	for floor_def in floors:
		ids.append(floor_def.floor_id)
	return ids

func unregister_floor(floor_id: StringName) -> bool:
	var floor_def := get_floor(floor_id)
	if floor_def == null:
		return false
	_by_id.erase(floor_id)
	floors.erase(floor_def)
	if active_floor == floor_def:
		active_floor = null
	return true

## Human-readable layout problems for a floor definition. Empty means
## the floor can be materialized.
func validate_floor(floor_def: Floor) -> Array[String]:
	var problems: Array[String] = []
	if floor_def == null:
		return ["null floor"]
	var seen := {}
	for spec in floor_def.rooms:
		if spec == null:
			problems.append("null room spec")
			continue
		if seen.has(spec.room_id):
			problems.append("duplicate room id %s" % spec.room_id)
		seen[spec.room_id] = true
		var size := _resolved_spec_size(spec)
		if size == Vector2i.ZERO or size.x <= 0 or size.y <= 0:
			problems.append("room %s has no resolvable size" % spec.room_id)
		var own := _spec_sections(spec)
		for i in range(own.size()):
			for j in range(i + 1, own.size()):
				if own[i].intersects(own[j]):
					problems.append("room %s has overlapping shape sections" % spec.room_id)
	if floor_def.rooms.is_empty():
		problems.append("floor has no rooms")
	if not seen.has(floor_def.entry_room_id):
		problems.append("entry room %s is not a registered room" % floor_def.entry_room_id)
	var bounds := _spec_bounds(floor_def)
	for i in range(bounds.size()):
		for j in range(i + 1, bounds.size()):
			var spec_a: FloorRoomSpec = bounds[i][0]
			var spec_b: FloorRoomSpec = bounds[j][0]
			if _sections_overlap(_spec_sections(spec_a), _spec_sections(spec_b)):
				problems.append("room specs %s and %s have overlapping cells" % [
					_id_text(spec_a.room_id), _id_text(spec_b.room_id)])
	for connection in floor_def.connections:
		if connection == null:
			problems.append("null connection")
			continue
		if not seen.has(connection.source_room_id):
			problems.append("connection '%s' references missing source room %s" % [connection.connection_id, connection.source_room_id])
		if not seen.has(connection.destination_room_id):
			problems.append("connection '%s' references missing destination room %s" % [connection.connection_id, connection.destination_room_id])
	return problems

## Specs with a resolvable footprint, paired with their union bounds
## Rect2i — used for pairwise overlap validation.
func _spec_bounds(floor_def: Floor) -> Array:
	var bounds: Array = []
	for spec in floor_def.rooms:
		if spec == null:
			continue
		var footprint := spec.bounds()
		if footprint.size == Vector2i.ZERO or footprint.size.x <= 0 or footprint.size.y <= 0:
			continue
		bounds.append([spec, footprint])
	return bounds

## Global cell rects that make up a spec's footprint: its stored
## shape_sections, or the single global_origin+size rectangle.
static func _spec_sections(spec: FloorRoomSpec) -> Array[Rect2i]:
	if spec == null:
		return []
	if not spec.shape_sections.is_empty():
		return spec.shape_sections.duplicate()
	var size := _resolved_spec_size(spec)
	if size == Vector2i.ZERO:
		return []
	return [Rect2i(spec.global_origin, size)]

## Union bounding box of a list of global cell rects.
static func _sections_bounds(sections: Array[Rect2i]) -> Rect2i:
	if sections.is_empty():
		return Rect2i()
	var result := sections[0]
	for section in sections.slice(1):
		result = result.merge(section)
	return result

## True when any section rect of A intersects any of B — exact for
## cell unions since rect intersection means shared cells.
static func _sections_overlap(a: Array[Rect2i], b: Array[Rect2i]) -> bool:
	for ra in a:
		for rb in b:
			if ra.intersects(rb):
				return true
	return false

## True when any section of A shares an edge segment with any section
## of B — exact for cell unions (a cell-edge adjacency always lies on
## a section boundary pair).
static func _sections_share_edge(a: Array[Rect2i], b: Array[Rect2i]) -> bool:
	for ra in a:
		for rb in b:
			if _specs_share_edge(ra, rb):
				return true
	return false

## True when the section union is one edge-connected piece: sections
## linked by overlap or shared edge form a single component.
static func _sections_connected(sections: Array[Rect2i]) -> bool:
	if sections.size() <= 1:
		return true
	var linked := {}
	for i in range(sections.size()):
		var neighbors: Array[int] = []
		for j in range(sections.size()):
			if i == j:
				continue
			if sections[i].intersects(sections[j]) or _specs_share_edge(sections[i], sections[j]):
				neighbors.append(j)
		linked[i] = neighbors
	var seen := {0: true}
	var frontier: Array[int] = [0]
	while not frontier.is_empty():
		var next: Array[int] = []
		for node in frontier:
			for other in linked[node]:
				if not seen.has(other):
					seen[other] = true
					next.append(other)
		frontier = next
	return seen.size() == sections.size()

static func _resolved_spec_size(spec: FloorRoomSpec) -> Vector2i:
	if spec == null:
		return Vector2i.ZERO
	if not spec.shape_sections.is_empty():
		return _sections_bounds(spec.shape_sections).size
	if spec.size != Vector2i.ZERO:
		return spec.size
	if spec.room_definition != null:
		return spec.room_definition.size
	return Vector2i.ZERO

## True when two cell rects share an edge segment — touching along a
## side with positive overlap on the perpendicular axis. Corner-only
## contact does not count (no door could be generated there).
static func _specs_share_edge(a: Rect2i, b: Rect2i) -> bool:
	var a_end := a.position + a.size
	var b_end := b.position + b.size
	var y_overlap := mini(a_end.y, b_end.y) - maxi(a.position.y, b.position.y)
	var x_overlap := mini(a_end.x, b_end.x) - maxi(a.position.x, b.position.x)
	var side_by_side := (a_end.x == b.position.x or b_end.x == a.position.x) and y_overlap > 0
	var stacked := (a_end.y == b.position.y or b_end.y == a.position.y) and x_overlap > 0
	return side_by_side or stacked

# ------------------------------------------------------------------
# Materialization
# ------------------------------------------------------------------

## Builds the floor's rooms and connections inside room_world,
## replacing whatever rooms it currently hosts. Returns false when the
## floor or room_world is missing; partial failures are reported through
## RoomWorld's own error reporting.
func materialize_floor(floor_def: Floor, target_world: RoomWorld = null) -> bool:
	var world := target_world if target_world != null else room_world
	if floor_def == null or world == null:
		push_error("FloorManager.materialize_floor requires a Floor and a RoomWorld.")
		return false
	_clear_world_rooms(world)
	for spec in floor_def.rooms:
		if spec == null:
			continue
		_create_room(world, spec)
	for connection in floor_def.connections:
		if connection != null:
			world.register_connection(connection)
	if floor_def.auto_connect_adjacent:
		world.auto_connect_adjacent_rooms()
	# Saved-state hydration is keyed by room id; rebuilt rooms must be
	# allowed to load their own saves again.
	for room in world.registry.get_rooms():
		world.reset_room_state(room)
	if world.has_room(floor_def.entry_room_id):
		world.set_primary_room(floor_def.entry_room_id)
	return true

## Convenience wrapper: materializes the floor into the bound
## room_world and marks it active. Does not load saved state; use
## load_floor()/switch_floor() for the persistence-aware path.
func activate_floor(floor_id: StringName) -> bool:
	var floor_def := get_floor(floor_id)
	if floor_def == null:
		push_error("FloorManager has no floor '%s'." % floor_id)
		return false
	_apply_layout_override(floor_def)
	if not materialize_floor(floor_def):
		return false
	_hook_world(room_world)
	room_world.save_directory = floor_save_dir(floor_def.floor_id)
	active_floor = floor_def
	_dirty = true
	return true

# ------------------------------------------------------------------
# Persistence & switching
# ------------------------------------------------------------------

## Directory holding this floor's saves (user://floors/<id>/).
func floor_save_dir(floor_id: StringName) -> String:
	return FloorSaveSystem.floor_dir(floor_id)

## True when the floor has a valid saved state on disk.
func has_floor_save(floor_id: StringName) -> bool:
	return FloorSaveSystem.has_save(floor_id)

## Advisory dirty flag: true while the active floor may have changes
## not yet written to its save directory. Saves are eager (on floor
## switch, F5, and exit), so this mainly serves a future floor UI.
func is_floor_dirty() -> bool:
	return _dirty

func mark_floor_dirty() -> void:
	_dirty = true

## Saves the active floor: every room's contents, the connection graph,
## and the player's room/position — all under the floor's own save
## directory via the existing RoomSaveSystem. The floor manifest is
## written last as the commit marker. Returns false (with the world
## untouched) when any file cannot be written.
func save_active_floor() -> bool:
	var floor_def := active_floor
	if floor_def == null or room_world == null:
		push_error("FloorManager.save_active_floor requires an active floor and a bound RoomWorld.")
		return false
	var dir := floor_save_dir(floor_def.floor_id)
	if dir.is_empty():
		push_error("FloorManager: floor id '%s' cannot be used as a save directory." % floor_def.floor_id)
		return false
	room_world.save_directory = dir
	var ok: bool = room_world.save_all_rooms()
	if ok:
		# Room specs + entry/spawn ride in layout.json; write it before
		# the manifest so the commit marker still comes last.
		var layout_error := save_floor_layout()
		if layout_error != OK:
			ok = false
			push_error("FloorManager failed to write layout for floor '%s' (error %d)." % [floor_def.floor_id, layout_error])
	if ok:
		var error := FloorSaveSystem.save_manifest(floor_def)
		if error != OK:
			ok = false
			push_error("FloorManager failed to write manifest for floor '%s' (error %d)." % [floor_def.floor_id, error])
	if ok:
		_dirty = false
	else:
		push_error("FloorManager failed to save floor '%s'; existing save data was left in place." % floor_def.floor_id)
	return ok

## Materializes a floor into the bound room_world (or target_world when
## given), then hydrates it from its save directory when a valid save
## exists. With no save the floor loads fresh from its definition and
## the player is placed at the entry room/spawn. A corrupt manifest
## aborts before anything is torn down. Returns false on any failure;
## when the bound world was already hosting another floor the caller
## (switch_floor) is responsible for rollback — load_floor itself only
## mutates the world after validation passes.
func load_floor(floor_id: StringName, target_world: RoomWorld = null) -> bool:
	var floor_def := get_floor(floor_id)
	var world := target_world if target_world != null else room_world
	if floor_def == null or world == null:
		push_error("FloorManager.load_floor requires a registered floor and a RoomWorld.")
		return false
	# User-created layout edits (user://floors/<id>/layout.json) override
	# the res:// resource specs before validation/materialization. The
	# override mutates floor_def.rooms, so snapshot it: a refused load
	# must not leave invalid specs behind in memory.
	var saved_specs := floor_def.rooms
	var saved_entry := floor_def.entry_room_id
	var saved_spawn := floor_def.spawn_position
	_apply_layout_override(floor_def)
	var problems := validate_floor(floor_def)
	if not problems.is_empty():
		floor_def.rooms = saved_specs
		floor_def.entry_room_id = saved_entry
		floor_def.spawn_position = saved_spawn
		push_error("FloorManager.load_floor: floor '%s' is invalid: %s" % [floor_id, ", ".join(problems)])
		return false
	var check := FloorSaveSystem.check_save(floor_id)
	var status := String(check["status"])
	if status == "corrupt":
		push_error("FloorManager.load_floor: floor '%s' has a corrupt save; refusing to load or overwrite it: %s" % [
			floor_id, ", ".join(check["reasons"])])
		return false
	var dir := floor_save_dir(floor_id)
	world.save_directory = dir
	if not materialize_floor(floor_def, world):
		return false
	var expected := 0
	for spec in floor_def.rooms:
		if spec != null:
			expected += 1
	if world.registry.get_rooms().size() != expected:
		push_error("FloorManager.load_floor: floor '%s' materialized %d rooms, expected %d." % [
			floor_id, world.registry.get_rooms().size(), expected])
		return false
	_hook_world(world)
	if status == "ok":
		world.load_all_rooms()
		# load_connections replaces the whole graph with the saved one —
		# including empty/stale files — so re-run auto-connect afterwards
		# (idempotent by connection id) to restore generated doors, same
		# as the legacy boot order did.
		if floor_def.auto_connect_adjacent:
			world.auto_connect_adjacent_rooms()
	_ensure_player_placement(world, floor_def)
	if world == room_world:
		active_floor = floor_def
		_dirty = false
		floor_switched.emit(floor_def)
	return true

## Switches the bound world to another floor. Order of operations is
## deliberately fail-safe:
##   1. The outgoing floor is saved first; if saving fails the switch
##      aborts and the current floor is completely untouched.
##   2. The destination is validated (definition + save manifest)
##      before any room is removed.
##   3. Only then is the world rebuilt; a failed load triggers a
##      rollback attempt back to the previous floor.
## Switching to the already-active floor reloads it (save + load).
func switch_floor(floor_id: StringName) -> bool:
	var dest := get_floor(floor_id)
	if dest == null:
		push_error("FloorManager has no floor '%s'." % floor_id)
		return false
	if room_world == null:
		push_error("FloorManager.switch_floor requires a bound RoomWorld.")
		return false
	var source := active_floor
	if source != null:
		if not save_active_floor():
			push_error("Floor switch to '%s' aborted: could not save floor '%s'; current floor preserved." % [
				floor_id, source.floor_id])
			return false
	if not load_floor(floor_id):
		if source != null:
			push_warning("FloorManager: switch to '%s' failed; restoring floor '%s'." % [floor_id, source.floor_id])
			if not load_floor(source.floor_id):
				push_error("FloorManager: rollback to floor '%s' also failed; world may be inconsistent." % source.floor_id)
		return false
	return true

## Incrementally adds one room spec to the active floor and materializes
## just that room, without rebuilding the floor (Creation Mode tool).
## Validates id uniqueness, resolvable size, and bounds overlap before
## touching the world; register_room_at rejects overlaps a second time
## at the registry level. On success the spec is appended to
## floor_def.rooms, adjacent auto-connections run (idempotent), the
## floor is marked dirty, and the layout override is written to
## user://floors/<id>/layout.json. Returns the created Room, or null.
func add_room_to_active_floor(spec: FloorRoomSpec) -> Room:
	var floor_def := active_floor
	var world := room_world
	if floor_def == null or world == null or spec == null:
		push_error("FloorManager.add_room_to_active_floor requires an active floor, a RoomWorld, and a spec.")
		return null
	var sections := _spec_sections(spec)
	if sections.is_empty():
		push_error("FloorManager.add_room_to_active_floor: room %s has no resolvable size." % spec.room_id)
		return null
	var bounds := _sections_bounds(sections)
	if bounds.size.x < Floor.MIN_ROOM_DIMENSION or bounds.size.y < Floor.MIN_ROOM_DIMENSION:
		push_error("FloorManager.add_room_to_active_floor: room %s bounds %s are below the %dx%d minimum." % [
			spec.room_id, bounds.size, Floor.MIN_ROOM_DIMENSION, Floor.MIN_ROOM_DIMENSION])
		return null
	for section in sections:
		if section.size.x < Floor.MIN_ROOM_DIMENSION or section.size.y < Floor.MIN_ROOM_DIMENSION:
			push_error("FloorManager.add_room_to_active_floor: room %s section %s is below the %dx%d minimum." % [
				spec.room_id, section, Floor.MIN_ROOM_DIMENSION, Floor.MIN_ROOM_DIMENSION])
			return null
	for i in range(sections.size()):
		for j in range(i + 1, sections.size()):
			if sections[i].intersects(sections[j]):
				push_error("FloorManager.add_room_to_active_floor: room %s has overlapping shape sections." % spec.room_id)
				return null
	if not _sections_connected(sections):
		push_error("FloorManager.add_room_to_active_floor: room %s sections do not form one connected shape." % spec.room_id)
		return null
	for other in floor_def.rooms:
		if other == null:
			continue
		if other.room_id == spec.room_id:
			push_error("FloorManager.add_room_to_active_floor: room id %s is already used by this floor." % spec.room_id)
			return null
		if _sections_overlap(sections, _spec_sections(other)):
			push_error("FloorManager.add_room_to_active_floor: room %s at %s overlaps room %s." % [
				spec.room_id, bounds.position, other.room_id])
			return null
	# No orphan rooms: a new room must share an edge with an existing
	# spec. An empty floor accepts its first room (it becomes entry).
	if not floor_def.rooms.is_empty():
		var touches := false
		for other in floor_def.rooms:
			if other == null:
				continue
			if _sections_share_edge(sections, _spec_sections(other)):
				touches = true
				break
		if not touches:
			push_error("FloorManager.add_room_to_active_floor: room %s at %s does not share an edge with any room on floor '%s'." % [
				spec.room_id, bounds.position, floor_def.floor_id])
			return null
	# Normalize: global_origin/size become the footprint's bounding box
	# so every rect-based consumer (bounds, saves, layout) stays exact.
	spec.global_origin = bounds.position
	spec.size = bounds.size
	var was_empty := floor_def.rooms.is_empty()
	var room := _create_room(world, spec)
	if room == null:
		return null
	floor_def.rooms.append(spec)
	if was_empty:
		# First room on an empty floor becomes the entry/spawn so the
		# floor stays loadable and valid.
		floor_def.entry_room_id = spec.room_id
		floor_def.spawn_position = Vector2i(bounds.size.x >> 1, bounds.size.y >> 1)
	if floor_def.auto_connect_adjacent:
		world.auto_connect_adjacent_rooms()
	_dirty = true
	var error := save_floor_layout()
	if error != OK:
		push_warning("FloorManager.add_room_to_active_floor: room created but layout save failed (error %d)." % error)
	return room

## Reports whether a room may be deleted from the active floor.
## Returns {"allowed": bool, "reason": String}. A room is deletable
## only when it holds no placed contents, the player is not inside it,
## it is not the floor's last room, it has no explicit floor
## connections, and every edge-adjacent room keeps at least one other
## adjacent room afterwards.
func can_delete_room(room_id: Vector2i) -> Dictionary:
	var refuse := func(reason: String) -> Dictionary:
		return {"allowed": false, "reason": reason}
	var floor_def := active_floor
	var world := room_world
	if floor_def == null or world == null:
		return refuse.call("No active floor.")
	var room := world.get_room(room_id)
	if room == null:
		return refuse.call("Room is not instantiated.")
	if room.has_placed_contents():
		return refuse.call("Room has placed contents.")
	var player := _player()
	if player != null and player.room == room:
		return refuse.call("Player is inside the room.")
	var bounds := _floor_spec_bounds()
	if bounds.size() <= 1:
		return refuse.call("Cannot delete the last room on the floor.")
	for connection in floor_def.connections:
		if connection != null and (connection.source_room_id == room_id \
				or connection.destination_room_id == room_id):
			return refuse.call("Room has explicit floor connections.")
	var all_sections := _floor_spec_sections()
	var target_sections: Array[Rect2i] = all_sections.get(room_id, [])
	for other_id in all_sections:
		if other_id == room_id:
			continue
		if not _sections_share_edge(target_sections, all_sections[other_id]):
			continue
		# `other_id` is a neighbor: it must keep another neighbor.
		var keeps_neighbor := false
		for third_id in all_sections:
			if third_id == room_id or third_id == other_id:
				continue
			if _sections_share_edge(all_sections[other_id], all_sections[third_id]):
				keeps_neighbor = true
				break
		if not keeps_neighbor:
			return refuse.call("Deleting would isolate adjacent room %s." % _id_text(other_id))
	return {"allowed": true, "reason": ""}

## Deletes a room from the active floor: unregisters it, removes every
## runtime connection touching it, repairs entry/spawn when needed,
## drops the spec, and persists the layout. Returns false (with the
## reason pushed to the console) when can_delete_room refuses.
func remove_room_from_active_floor(room_id: Vector2i) -> bool:
	var floor_def := active_floor
	var world := room_world
	if floor_def == null or world == null:
		push_error("FloorManager.remove_room_from_active_floor requires an active floor and a RoomWorld.")
		return false
	var verdict := can_delete_room(room_id)
	if not verdict.get("allowed", false):
		push_error("FloorManager.remove_room_from_active_floor: %s" % verdict.get("reason", "refused"))
		return false
	var all_sections := _floor_spec_sections()
	var target_sections: Array[Rect2i] = all_sections.get(room_id, [])
	# Runtime connections (auto + saved graph) touching the room go.
	for connection in world.get_room_connections(room_id).duplicate():
		world.unregister_connection(connection.connection_id)
	# First remaining edge-adjacent spec becomes the fallback entry.
	var fallback_id := Vector2i.ZERO
	var fallback_found := false
	for other_id in all_sections:
		if other_id != room_id and _sections_share_edge(target_sections, all_sections[other_id]):
			fallback_id = other_id
			fallback_found = true
			break
	if floor_def.entry_room_id == room_id:
		if fallback_found:
			floor_def.entry_room_id = fallback_id
		else:
			# No adjacent room (isolated spec): any remaining room works.
			for other_id in all_sections:
				if other_id != room_id:
					floor_def.entry_room_id = other_id
					fallback_found = true
					break
		var entry_spec := floor_def.find_room_spec(floor_def.entry_room_id)
		if entry_spec != null:
			var entry_size := _resolved_spec_size(entry_spec)
			floor_def.spawn_position = Vector2i(entry_size.x >> 1, entry_size.y >> 1)
	for i in range(floor_def.rooms.size() - 1, -1, -1):
		var spec: FloorRoomSpec = floor_def.rooms[i]
		if spec != null and spec.room_id == room_id:
			floor_def.rooms.remove_at(i)
	world.unregister_room(room_id)
	# Persist the pruned connection graph immediately — otherwise the
	# stale connections.json would resurrect doors to the deleted room
	# on the next load.
	var conn_error := RoomSaveSystem.save_connections(world)
	if conn_error != OK:
		push_warning("FloorManager.remove_room_from_active_floor: connection save failed (error %d)." % conn_error)
	_dirty = true
	var error := save_floor_layout()
	if error != OK:
		push_warning("FloorManager.remove_room_from_active_floor: room deleted but layout save failed (error %d)." % error)
	return true

## room_id -> global bounds Rect2i for every spec with a resolvable
## size on the active floor.
func _floor_spec_bounds() -> Dictionary:
	var bounds := {}
	var floor_def := active_floor
	if floor_def == null:
		return bounds
	for spec in floor_def.rooms:
		if spec == null:
			continue
		var footprint := spec.bounds()
		if footprint.size == Vector2i.ZERO or footprint.size.x <= 0 or footprint.size.y <= 0:
			continue
		bounds[spec.room_id] = footprint
	return bounds

## room_id -> Array[Rect2i] of global footprint sections for every
## spec on the active floor. Cell-exact adjacency for shaped rooms.
func _floor_spec_sections() -> Dictionary:
	var sections := {}
	var floor_def := active_floor
	if floor_def == null:
		return sections
	for spec in floor_def.rooms:
		if spec == null:
			continue
		var footprint := _spec_sections(spec)
		if footprint.is_empty():
			continue
		sections[spec.room_id] = footprint
	return sections

static func _id_text(room_id: Vector2i) -> String:
	return "(%d, %d)" % [room_id.x, room_id.y]

## Persists the active floor's current room specs as its user:// layout
## override (Creation Mode edits). Room contents are unaffected — they
## keep saving through save_active_floor(). Returns the write Error.
func save_floor_layout() -> Error:
	var floor_def := active_floor
	if floor_def == null:
		push_error("FloorManager.save_floor_layout requires an active floor.")
		return ERR_INVALID_PARAMETER
	return FloorSaveSystem.save_layout(floor_def)

## Replaces floor_def.rooms with the specs stored in the floor's
## user:// layout.json when one exists. Resource specs stay untouched;
## the override only lives in memory for this session. Entries that
## fail to parse are skipped with a warning.
func _apply_layout_override(floor_def: Floor) -> void:
	var data := FloorSaveSystem.load_layout(floor_def.floor_id)
	var entries: Array = data.get("rooms", [])
	if entries.is_empty():
		return
	var specs: Array[FloorRoomSpec] = []
	for entry in entries:
		if not (entry is Dictionary):
			push_warning("FloorManager: skipping malformed layout entry in floor '%s'." % floor_def.floor_id)
			continue
		var spec := FloorRoomSpec.new()
		spec.room_id = _layout_vec2i(entry.get("room_id"))
		spec.global_origin = _layout_vec2i(entry.get("global_origin"))
		spec.size = _layout_vec2i(entry.get("size"))
		var definition_path := str(entry.get("definition", ""))
		if not definition_path.is_empty() and ResourceLoader.exists(definition_path):
			spec.room_definition = ResourceLoader.load(definition_path) as RoomDefinition
		var colors: Array[Color] = []
		for color_text in entry.get("floor_colors", []):
			colors.append(Color.html(str(color_text)))
		spec.floor_colors = colors
		# Missing keys (older layout.json) default to visible.
		spec.show_from_outside = bool(entry.get("show_from_outside", true))
		spec.show_outside = bool(entry.get("show_outside", true))
		var sections: Array[Rect2i] = []
		for raw in entry.get("sections", []):
			if raw is Array and (raw as Array).size() == 4:
				sections.append(Rect2i(int(raw[0]), int(raw[1]), int(raw[2]), int(raw[3])))
		spec.shape_sections = sections
		# Shaped specs normalize origin/size to the footprint bbox.
		if not sections.is_empty():
			var footprint := spec.bounds()
			if footprint.size != Vector2i.ZERO:
				spec.global_origin = footprint.position
				spec.size = footprint.size
		specs.append(spec)
	if specs.is_empty():
		return
	floor_def.rooms = specs
	# Entry/spawn ride along with the layout so floors whose entry room
	# was created at runtime (empty-floor first room) survive restarts.
	var entry_raw: Variant = data.get("entry_room_id")
	if entry_raw is Array and entry_raw.size() == 2:
		floor_def.entry_room_id = _layout_vec2i(entry_raw)
	var spawn_raw: Variant = data.get("spawn_position")
	if spawn_raw is Array and spawn_raw.size() == 2:
		floor_def.spawn_position = _layout_vec2i(spawn_raw)
	print("FloorManager: floor '%s' layout override applied (%d room spec(s))." % [
		floor_def.floor_id, specs.size()])

static func _layout_vec2i(value: Variant) -> Vector2i:
	if value is Array and (value as Array).size() >= 2:
		return Vector2i(int(value[0]), int(value[1]))
	return Vector2i.ZERO

func _player() -> Player:
	if not is_inside_tree():
		return null
	return get_tree().get_first_node_in_group(&"player") as Player

## Connects the world's content-change signal once so room edits mark
## the active floor dirty.
func _hook_world(world: RoomWorld) -> void:
	if world == null or _hooked_world == world:
		return
	_hooked_world = world
	if not world.room_content_changed.is_connected(_on_room_content_changed):
		world.room_content_changed.connect(_on_room_content_changed)

func _on_room_content_changed() -> void:
	if active_floor != null:
		_dirty = true

## Places the player on the floor's entry room after a load/materialize.
## When the floor's saved player state was already applied by
## RoomWorld.load_all_rooms this is a no-op; otherwise the player is
## bound to the entry room (or the first room as a fallback) at the
## floor's spawn position, clamped into the room's bounds.
func _ensure_player_placement(world: RoomWorld, floor_def: Floor) -> void:
	var player := _player()
	if player == null:
		return
	var current: Room = null
	if player.room != null and is_instance_valid(player.room):
		current = world.get_room(player.room.room_coordinates)
	if current != null and current == player.room and player.room.is_inside_tree():
		return
	var entry := world.get_room(floor_def.entry_room_id)
	if entry == null:
		var rooms := world.registry.get_rooms()
		if not rooms.is_empty():
			entry = rooms[0]
	if entry == null:
		push_warning("FloorManager: floor '%s' has no rooms; player left unplaced." % floor_def.floor_id)
		return
	var spawn := floor_def.spawn_position
	if spawn.x < 0 or spawn.y < 0 or spawn.x >= entry.size.x or spawn.y >= entry.size.y:
		spawn = Vector2i(entry.size.x >> 1, entry.size.y >> 1)
	# Shaped rooms can have holes inside their bounding box; snap the
	# spawn to the nearest real footprint cell so the player never
	# lands somewhere they cannot move.
	if not entry.has_cell(spawn):
		spawn = _nearest_room_cell(entry, spawn)
	player.room = entry
	player.block_layer = entry.block_layer
	player.room_size = entry.size
	player.place_at(spawn, player.stand_elevation_at(spawn))
	world.set_primary_room(entry.room_coordinates)

## Closest cell (by squared distance) present in the room's footprint
## to the given local coordinate. Falls back to (0,0)-scan order.
static func _nearest_room_cell(room: Room, target: Vector2i) -> Vector2i:
	var best := Vector2i.ZERO
	var best_dist := -1
	for coordinates: Vector2i in room.cells:
		var delta := coordinates - target
		var dist: int = delta.x * delta.x + delta.y * delta.y
		if best_dist < 0 or dist < best_dist:
			best_dist = dist
			best = coordinates
	return best

func _clear_world_rooms(world: RoomWorld) -> void:
	for room in world.registry.get_rooms().duplicate():
		world.unregister_room(room.room_coordinates)

func _create_room(world: RoomWorld, spec: FloorRoomSpec) -> Room:
	var definition := spec.room_definition
	var spec_size := spec.size
	if spec_size == Vector2i.ZERO and definition != null:
		spec_size = definition.size
	var shaped := not spec.shape_sections.is_empty()
	if shaped and definition != null:
		push_warning("Floor room %s has shape sections; ignoring its RoomDefinition." % spec.room_id)
		definition = null
	if definition != null and spec_size == definition.size:
		var defined_room := world.create_room_from_definition(spec.room_id, spec.global_origin, definition)
		if defined_room != null:
			defined_room.show_from_outside = spec.show_from_outside
			defined_room.show_outside = spec.show_outside
			if not spec.floor_colors.is_empty():
				defined_room.floor_colors = spec.floor_colors
				if defined_room.floor_renderer != null:
					defined_room.floor_renderer.queue_redraw()
		return defined_room
	if definition != null and spec_size != Vector2i.ZERO:
		push_warning("Floor room %s overrides definition size %s with spec size %s." % [spec.room_id, definition.size, spec_size])
	# Spec sections are global; the room's local sections are relative
	# to the footprint's bounding-box origin. Derive it from the
	# sections themselves so authored specs don't need normalized
	# global_origin/size to materialize correctly.
	var origin := spec.global_origin
	if shaped:
		var footprint := _sections_bounds(spec.shape_sections)
		if footprint.size != Vector2i.ZERO:
			origin = footprint.position
			spec_size = footprint.size
	var local_sections: Array[Rect2i] = []
	if shaped:
		for section in spec.shape_sections:
			local_sections.append(Rect2i(section.position - origin, section.size))
	var room := world.create_room_at(spec.room_id, origin, spec_size, spec.floor_colors, local_sections)
	if room != null:
		room.show_from_outside = spec.show_from_outside
		room.show_outside = spec.show_outside
	return room
