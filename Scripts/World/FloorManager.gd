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

## Ground-cover tiles randomly scattered over bare cells when a spec
## asks for it (FloorRoomSpec.scatter_ground — Creation Mode rooms).
## Deterministic per room id + global origin, so every client and
## every reload generates the identical layout; never persisted
## (patched cells are tracked in room.auto_tiles and skipped by room
## saves and placed-content counts).
const GROUND_SCATTER_PATCH_IDS: Array[StringName] = [
	&"floor_iso", &"simple_grass_iso",
]
## bushy_grass is NOT part of the blob pool — it rolls independently
## on every bare cell with GROUND_SCATTER_BUSHY_CHANCE probability.
const GROUND_SCATTER_BUSHY_ID := &"bushy_grass"
const GROUND_SCATTER_BUSHY_CHANCE := 0.1

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
## RoomWorld -> floor_id for every hooked world, so content-change
## signals can be attributed to the floor that actually changed.
var _world_floor := {}
## Floor ids with unsaved authoritative changes (Phase D dirty
## tracking). Keyed by floor_id so a mutation on Floor A never marks
## Floor B. Cleared per-floor only after that floor saves cleanly.
var _dirty_floors := {}
## While true, room_content_changed signals are ignored — floor
## materialization/hydration emits the same signals as real edits and
## must not count as dirty.
var _persist_paused := false
## Runtime RoomWorld instances hosting floors OTHER than the bound
## room_world — multiplayer floor transitions give each occupied floor
## its own world so players can stand on different floors at once.
## Keys are floor_id; the bound world always serves active_floor.
var runtime_worlds := {}

## True while this manager must refuse local structural mutations:
## the local peer is a multiplayer CLIENT whose world is rebuilt only
## by authoritative snapshots/ops (Phase C). Server and single-player
## return false. Internal replica paths — WorldSnapshot.apply,
## load_floor_without_save, materialize_floor, apply_layout_data —
## deliberately bypass the guarded mutators below.
func structural_edits_readonly() -> bool:
	return is_inside_tree() and MultiplayerManager.is_client(get_tree())

func _refuse_readonly(what: String) -> void:
	push_warning("FloorManager.%s refused: structural edits are read-only for multiplayer clients." % what)

func _ready() -> void:
	add_to_group(&"floor_managers")
	# Always scan: register_floor() deduplicates, so floors registered
	# manually before _ready coexist with resource-loaded ones.
	_load_floor_resources()
	_load_saved_floor_definitions()

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

## Registers floors created at runtime in a previous session. Their
## definitions live in user://floors/<id>/floor_def.json; res://
## resources are never written. A saved definition whose id collides
## with a shipped floor is rejected by register_floor — user data can
## never shadow built-in content.
func _load_saved_floor_definitions() -> void:
	for data in FloorSaveSystem.load_floor_definitions():
		var floor_def := _floor_from_saved_data(data)
		if floor_def != null:
			register_floor(floor_def)

## Rebuilds a Floor resource from a parsed floor_def.json dictionary.
## Room specs/entry/spawn reuse the layout-entry parser; connections
## come back through FloorSaveSystem.connection_from_dict.
func _floor_from_saved_data(data: Dictionary) -> Floor:
	var floor_id := StringName(str(data.get("floor_id", "")))
	if floor_id == &"":
		push_warning("FloorManager: saved floor definition has no floor_id; ignoring.")
		return null
	var floor_def := Floor.new()
	floor_def.floor_id = floor_id
	floor_def.display_name = str(data.get("display_name", ""))
	floor_def.auto_connect_adjacent = bool(data.get("auto_connect_adjacent", true))
	var metadata: Variant = data.get("metadata")
	if metadata is Dictionary:
		floor_def.metadata = metadata
	_apply_layout_entries(floor_def, data)
	for raw in data.get("connections", []):
		var connection := FloorSaveSystem.connection_from_dict(raw)
		if connection != null:
			floor_def.connections.append(connection)
	return floor_def

# ------------------------------------------------------------------
# Floor registry
# ------------------------------------------------------------------

func register_floor(floor_def: Floor) -> bool:
	if structural_edits_readonly():
		_refuse_readonly("register_floor")
		return false
	return _register_floor(floor_def)

## Registers a Floor rebuilt from network data (WorldSnapshot floor
## definitions, floor transitions). Bypasses the readonly guard: this
## is replica state arriving from the server, not a local structural
## edit — clients must be able to learn floors they did not create.
func register_floor_replica(floor_def: Floor) -> bool:
	return _register_floor(floor_def)

func _register_floor(floor_def: Floor) -> bool:
	if floor_def == null:
		push_error("FloorManager.register_floor requires a Floor.")
		return false
	if floor_def.floor_id == &"":
		push_error("Floor '%s' has no floor_id." % floor_def.display_name)
		return false
	if _by_id.has(floor_def.floor_id):
		push_error("FloorManager already has floor '%s'." % floor_def.floor_id)
		return false
	_normalize_spawn_points(floor_def)
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
	if structural_edits_readonly():
		_refuse_readonly("unregister_floor")
		return false
	return _unregister_floor(floor_id)

## Unguarded unregister for replica state arriving from the server
## (floor-delete broadcasts, snapshot catalog reconcile). Mirrors
## register_floor_replica: never touches disk. Refuses to drop the
## active floor — a client standing on a floor the server deleted is
## a protocol divergence the caller must surface, not paper over.
func unregister_floor_replica(floor_id: StringName) -> bool:
	var floor_def := get_floor(floor_id)
	if floor_def == null:
		return false
	if active_floor == floor_def:
		push_warning("FloorManager.unregister_floor_replica: '%s' is the active floor; kept (divergence)." % floor_id)
		return false
	return _unregister_floor(floor_id)

func _unregister_floor(floor_id: StringName) -> bool:
	var floor_def := get_floor(floor_id)
	if floor_def == null:
		return false
	_by_id.erase(floor_id)
	floors.erase(floor_def)
	_dirty_floors.erase(floor_id)
	# Drop world->floor attribution for any world still hosting it;
	# the world itself is released separately by the caller.
	for world in _world_floor.keys():
		if _world_floor[world] == floor_id:
			_world_floor.erase(world)
	if active_floor == floor_def:
		active_floor = null
	return true

## Creates a new floor: unique id, display name, initial room specs,
## and its own user:// save directory (floor_def.json — res:// is
## never written). An empty spec list gets a single default 8x8 room
## so the floor is immediately enterable. Entry/spawn default to the
## first spec's room center. Returns the Floor, or null when the id
## is unusable/duplicate or the layout fails validation.
func create_floor(floor_id: StringName, display_name := "", room_specs: Array[FloorRoomSpec] = [], auto_connect := true) -> Floor:
	if structural_edits_readonly():
		_refuse_readonly("create_floor")
		return null
	if FloorSaveSystem.floor_dir(floor_id).is_empty():
		push_error("FloorManager.create_floor: id '%s' cannot be used as a save directory." % floor_id)
		return null
	if has_floor(floor_id):
		push_error("FloorManager already has floor '%s'." % floor_id)
		return null
	var specs: Array[FloorRoomSpec] = []
	for spec in room_specs:
		if spec != null:
			specs.append(spec)
	if specs.is_empty():
		var spec := FloorRoomSpec.new()
		spec.room_id = Vector2i.ZERO
		spec.global_origin = Vector2i.ZERO
		spec.size = Vector2i(8, 8)
		specs.append(spec)
	var floor_def := Floor.new()
	floor_def.floor_id = floor_id
	floor_def.display_name = display_name if not display_name.is_empty() else String(floor_id)
	floor_def.auto_connect_adjacent = auto_connect
	floor_def.rooms = specs
	var first := specs[0]
	floor_def.entry_room_id = first.room_id
	var first_size := _resolved_spec_size(first)
	floor_def.spawn_position = Vector2i(first_size.x >> 1, first_size.y >> 1) \
		if first_size != Vector2i.ZERO else Vector2i.ZERO
	# Derive the floor's first spawn point from entry/spawn before
	# validation — register_floor would do it anyway, but create_floor
	# validates first.
	_normalize_spawn_points(floor_def)
	var problems := validate_floor(floor_def)
	if not problems.is_empty():
		push_error("FloorManager.create_floor: floor '%s' is invalid: %s" % [floor_id, ", ".join(problems)])
		return null
	if not register_floor(floor_def):
		return null
	var error := FloorSaveSystem.save_floor_definition(floor_def)
	if error != OK:
		push_error("FloorManager.create_floor: floor registered but definition save failed (error %d)." % error)
		unregister_floor(floor_id)
		return null
	# floor_def.json is already durable; dirty ensures the manifest +
	# layout are written by the next autosave/shutdown save.
	mark_floor_dirty(floor_id)
	return floor_def

## Reports whether a floor may be deleted. Returns
## {"allowed": bool, "reason": String}. A floor is deletable when it is
## registered and is not the last remaining floor; deleting the active
## floor is allowed — delete_floor() travels elsewhere first.
func can_delete_floor(floor_id: StringName) -> Dictionary:
	var refuse := func(reason: String) -> Dictionary:
		return {"allowed": false, "reason": reason}
	if get_floor(floor_id) == null:
		return refuse.call("Floor is not registered.")
	if floors.size() <= 1:
		return refuse.call("Cannot delete the last floor.")
	return {"allowed": true, "reason": ""}

## Deletes a floor: when it is active the manager first travels to
## another floor (saving the outgoing state and rebuilding the world,
## so no stale room/player references remain), then unregisters the
## definition and removes its entire save directory. A failed switch
## aborts the delete with everything untouched.
func delete_floor(floor_id: StringName) -> bool:
	if structural_edits_readonly():
		_refuse_readonly("delete_floor")
		return false
	var verdict := can_delete_floor(floor_id)
	if not verdict.get("allowed", false):
		push_error("FloorManager.delete_floor: %s" % verdict.get("reason", "refused"))
		return false
	var floor_def := get_floor(floor_id)
	if active_floor == floor_def:
		var fallback: Floor = null
		for other in floors:
			if other != floor_def:
				fallback = other
				break
		if fallback == null or not switch_floor(fallback.floor_id):
			push_error("FloorManager.delete_floor: could not leave floor '%s'; delete aborted." % floor_id)
			return false
	unregister_floor(floor_id)
	# Portals on OTHER floors pointing at the deleted floor must not
	# dangle: prune them and persist each affected floor's layout so
	# the next load doesn't resurrect them. The trigger path also
	# guards on get_floor(), so a missed prune degrades to "normal
	# movement", never an invalid transition.
	for other in floors.duplicate():
		if other == null or other.portals.is_empty():
			continue
		var kept_portals: Array[FloorPortal] = []
		var changed := false
		for portal in other.portals:
			if portal != null and portal.destination_floor_id == floor_id:
				changed = true
				continue
			kept_portals.append(portal)
		if changed:
			other.portals = kept_portals
			_persist_room_layout(other)
			mark_floor_dirty(other.floor_id)
	var error := FloorSaveSystem.delete_floor_save(floor_id)
	if error != OK:
		push_warning("FloorManager.delete_floor: floor unregistered but save data removal failed (error %d)." % error)
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
	# Spawn points are meaningless on a roomless floor — the first
	# room added derives one (_normalize_spawn_points in
	# _add_room_to_floor). Skip the checks until rooms exist.
	if not floor_def.rooms.is_empty():
		if floor_def.spawn_points.is_empty():
			problems.append("floor has no spawn points")
		elif floor_def.spawn_points.size() > Floor.MAX_SPAWN_POINTS:
			problems.append("floor has %d spawn points (max %d)" % [
				floor_def.spawn_points.size(), Floor.MAX_SPAWN_POINTS])
		else:
			for cell in floor_def.spawn_points:
				if spawn_cell_room(floor_def, cell) == null:
					problems.append("spawn point %s is not inside a room" % _id_text(cell))
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
	# Portals: unique ids and cells, owning room must contain the cell,
	# destination must be another registered floor. A portal whose
	# destination was deleted is reported here — delete_floor prunes
	# those eagerly, so reaching this means hand-edited/corrupt data.
	var portal_ids := {}
	var portal_cells := {}
	for portal in floor_def.portals:
		if portal == null:
			problems.append("null portal")
			continue
		if portal.portal_id == &"":
			problems.append("portal has no id")
		elif portal_ids.has(portal.portal_id):
			problems.append("duplicate portal id '%s'" % portal.portal_id)
		portal_ids[portal.portal_id] = true
		if portal_cells.has(portal.world_cell):
			problems.append("duplicate portal cell %s" % _id_text(portal.world_cell))
		portal_cells[portal.world_cell] = true
		var portal_spec := spawn_cell_room(floor_def, portal.world_cell)
		if portal_spec == null:
			problems.append("portal '%s' cell %s is not inside a room" % [portal.portal_id, _id_text(portal.world_cell)])
		elif portal_spec.room_id != portal.room_id:
			problems.append("portal '%s' room_id %s does not match cell room %s" % [
				portal.portal_id, _id_text(portal.room_id), _id_text(portal_spec.room_id)])
		if portal.destination_floor_id == floor_def.floor_id:
			problems.append("portal '%s' targets its own floor" % portal.portal_id)
		elif get_floor(portal.destination_floor_id) == null:
			problems.append("portal '%s' destination floor '%s' is not registered" % [
				portal.portal_id, portal.destination_floor_id])
		if portal.has_destination_cell():
			# The arrival override must land inside a room footprint
			# of the DESTINATION floor — checked against that floor's
			# specs, not this one (room ids collide across floors).
			# Warn only, never a hard problem: the destination floor's
			# layout can change after this portal was authored (e.g. the
			# arrival room gets deleted), and a stale arrival cell is
			# safe — arrival_placement_for_cell falls back to spawn
			# placement at travel time. Failing validation here would
			# make the whole SOURCE floor unloadable.
			var dest_def := get_floor(portal.destination_floor_id)
			if dest_def != null \
					and not _arrival_cell_valid_on_floor(
						portal.destination_floor_id, dest_def,
						portal.destination_world_cell):
				push_warning("FloorManager.validate_floor: portal '%s' arrival cell %s is not inside a room on floor '%s'; spawn fallback applies." % [
					portal.portal_id, _id_text(portal.destination_world_cell),
					portal.destination_floor_id])
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

## True when a global world cell lies inside any of the section rects.
static func _cell_in_sections(cell: Vector2i, sections: Array[Rect2i]) -> bool:
	for section in sections:
		if section.has_point(cell):
			return true
	return false

## Cell inside `sections` nearest to `target` (squared distance). Each
## rect is convex, so clamping into it yields that rect's nearest
## point; the closest candidate across sections wins. Used to snap
## derived spawn points into shaped-room footprints.
static func _nearest_section_cell(sections: Array[Rect2i], target: Vector2i) -> Vector2i:
	var best := target
	var best_dist := -1
	for section in sections:
		var clamped := target.clamp(section.position, section.end - Vector2i.ONE)
		var delta := clamped - target
		var dist: int = delta.x * delta.x + delta.y * delta.y
		if best_dist < 0 or dist < best_dist:
			best_dist = dist
			best = clamped
	return best

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
	if structural_edits_readonly():
		_refuse_readonly("activate_floor")
		return false
	var floor_def := get_floor(floor_id)
	if floor_def == null:
		push_error("FloorManager has no floor '%s'." % floor_id)
		return false
	_apply_layout_override(floor_def)
	_persist_paused = true
	var materialized := materialize_floor(floor_def)
	_persist_paused = false
	if not materialized:
		return false
	_hook_world(room_world, floor_def.floor_id)
	room_world.save_directory = floor_save_dir(floor_def.floor_id)
	active_floor = floor_def
	mark_floor_dirty()
	return true

# ------------------------------------------------------------------
# Runtime floor instances (multiplayer)
# ------------------------------------------------------------------

## The RoomWorld currently hosting a floor: the bound room_world for
## the active floor, a runtime_worlds entry for any other materialized
## floor, or null when the floor has never been instantiated.
func world_for_floor(floor_id: StringName) -> RoomWorld:
	var floor_def := get_floor(floor_id)
	if floor_def == null:
		return null
	if active_floor == floor_def and room_world != null:
		return room_world
	var world: Variant = runtime_worlds.get(floor_id)
	return world as RoomWorld

## Materializes a floor into a caller-provided RoomWorld and hydrates
## its saved room contents/connections — the multiplayer counterpart
## of load_floor for floors that are NOT the bound world. Unlike
## load_floor it never touches active_floor, never emits
## floor_switched, and hydrates via load_room_states so no
## player_state.json is read or written (the local player does not
## live in secondary worlds). On success the world is recorded in
## runtime_worlds. Returns false on any validation failure.
func materialize_runtime_floor(floor_id: StringName, world: RoomWorld) -> bool:
	if structural_edits_readonly():
		_refuse_readonly("materialize_runtime_floor")
		return false
	var floor_def := get_floor(floor_id)
	if floor_def == null or world == null:
		push_error("FloorManager.materialize_runtime_floor requires a registered floor and a RoomWorld.")
		return false
	# Same layout-override discipline as load_floor: snapshot the specs
	# so a refused load cannot poison the in-memory Floor.
	var saved_specs := floor_def.rooms
	var saved_entry := floor_def.entry_room_id
	var saved_spawn := floor_def.spawn_position
	var saved_spawn_points := floor_def.spawn_points.duplicate()
	var saved_portals := floor_def.portals.duplicate()
	_apply_layout_override(floor_def)
	var problems := validate_floor(floor_def)
	if not problems.is_empty():
		floor_def.rooms = saved_specs
		floor_def.entry_room_id = saved_entry
		floor_def.spawn_position = saved_spawn
		floor_def.spawn_points = saved_spawn_points
		floor_def.portals = saved_portals
		push_error("FloorManager.materialize_runtime_floor: floor '%s' is invalid: %s" % [
			floor_id, ", ".join(problems)])
		return false
	world.save_directory = floor_save_dir(floor_id)
	_persist_paused = true
	var materialized := materialize_floor(floor_def, world)
	_persist_paused = false
	if not materialized:
		return false
	var expected := 0
	for spec in floor_def.rooms:
		if spec != null:
			expected += 1
	if world.registry.get_rooms().size() != expected:
		push_error("FloorManager.materialize_runtime_floor: floor '%s' materialized %d rooms, expected %d." % [
			floor_id, world.registry.get_rooms().size(), expected])
		return false
	_hook_world(world, floor_id)
	_persist_paused = true
	world.load_room_states()
	_persist_paused = false
	# load_room_states replaces the graph with the saved one; re-run
	# auto-connect afterwards, same as load_floor.
	if floor_def.auto_connect_adjacent:
		world.auto_connect_adjacent_rooms()
	runtime_worlds[floor_id] = world
	return true

## Tears down a floor's runtime world: removes the dict entry and
## frees the RoomWorld node. The CALLER must guarantee the world is
## empty — no player bodies parented inside, no pending transition
## targeting it (MultiplayerManager checks occupancy before calling).
## Safe retention alternative: callers may simply leave the entry in
## place; an unvisited floor's world costs one materialized RoomWorld.
## Returns false when the floor had no runtime world.
func release_runtime_world(floor_id: StringName) -> bool:
	var world: Variant = runtime_worlds.get(floor_id)
	if world == null:
		return false
	runtime_worlds.erase(floor_id)
	if is_instance_valid(world):
		_world_floor.erase(world)
		(world as Node).queue_free()
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

## Floor ids with unsaved authoritative changes, for autosave/shutdown
## reporting. Read-only snapshot — mutate via mark/save paths only.
func dirty_floor_ids() -> Array:
	return _dirty_floors.keys()

## Advisory dirty flag: true while the ACTIVE floor has changes not
## yet written to its save directory. Other materialized floors are
## tracked individually — see dirty_floor_ids()/save_all_dirty().
func is_floor_dirty() -> bool:
	return active_floor != null and _dirty_floors.has(active_floor.floor_id)

## Marks a floor dirty. Defaults to the active floor; pass an explicit
## floor_id for runtime worlds. No-op on multiplayer clients — replica
## state is never "dirty" because clients never persist.
func mark_floor_dirty(floor_id: StringName = &"") -> void:
	if floor_id == &"":
		if active_floor == null:
			return
		floor_id = active_floor.floor_id
	if structural_edits_readonly():
		return
	_dirty_floors[floor_id] = true

## Floor-scoped save used by autosave/shutdown (Phase D): persists the
## floor's room contents + connections + layout + manifest through the
## existing save format, for whichever world hosts it — bound world or
## runtime_worlds entry. Uses save_room_states (no player_state.json):
## player bodies are transient session state, never shared content.
## Floors with no materialized world still get layout+manifest so a
## created-but-unvisited floor survives restart. On success only THIS
## floor's dirty flag clears; a failed save keeps it dirty.
func save_floor_state(floor_id: StringName) -> bool:
	var floor_def := get_floor(floor_id)
	if floor_def == null:
		return false
	var dir := floor_save_dir(floor_id)
	if dir.is_empty():
		push_error("FloorManager: floor id '%s' cannot be used as a save directory." % floor_id)
		return false
	var world := world_for_floor(floor_id)
	var ok := true
	if world != null:
		world.save_directory = dir
		ok = world.save_room_states()
	if ok:
		var layout_error := FloorSaveSystem.save_layout(floor_def)
		if layout_error != OK:
			ok = false
			push_error("FloorManager failed to write layout for floor '%s' (error %d)." % [floor_id, layout_error])
	if ok:
		var error := FloorSaveSystem.save_manifest(floor_def)
		if error != OK:
			ok = false
			push_error("FloorManager failed to write manifest for floor '%s' (error %d)." % [floor_id, error])
	if ok:
		_dirty_floors.erase(floor_id)
	else:
		push_error("FloorManager failed to save floor '%s'; it stays dirty for the next autosave." % floor_id)
	return ok

## Saves every dirty floor independently (Phase D autosave/shutdown).
## Dirty ids whose floor was unregistered are pruned. Returns
## {"saved": [ids], "failed": [ids]}; failed floors remain dirty.
func save_all_dirty() -> Dictionary:
	var saved: Array = []
	var failed: Array = []
	for floor_id in _dirty_floors.keys():
		if get_floor(floor_id) == null:
			_dirty_floors.erase(floor_id)
			continue
		if save_floor_state(floor_id):
			saved.append(floor_id)
		else:
			failed.append(floor_id)
	return {"saved": saved, "failed": failed}

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
		_dirty_floors.erase(floor_def.floor_id)
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
	if structural_edits_readonly():
		_refuse_readonly("load_floor")
		return false
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
	var saved_spawn_points := floor_def.spawn_points.duplicate()
	var saved_portals := floor_def.portals.duplicate()
	_apply_layout_override(floor_def)
	var problems := validate_floor(floor_def)
	if not problems.is_empty():
		floor_def.rooms = saved_specs
		floor_def.entry_room_id = saved_entry
		floor_def.spawn_position = saved_spawn
		floor_def.spawn_points = saved_spawn_points
		floor_def.portals = saved_portals
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
	_persist_paused = true
	if not materialize_floor(floor_def, world):
		_persist_paused = false
		return false
	var expected := 0
	for spec in floor_def.rooms:
		if spec != null:
			expected += 1
	if world.registry.get_rooms().size() != expected:
		_persist_paused = false
		push_error("FloorManager.load_floor: floor '%s' materialized %d rooms, expected %d." % [
			floor_id, world.registry.get_rooms().size(), expected])
		return false
	_hook_world(world, floor_id)
	if status == "ok":
		world.load_all_rooms()
		# load_connections replaces the whole graph with the saved one —
		# including empty/stale files — so re-run auto-connect afterwards
		# (idempotent by connection id) to restore generated doors, same
		# as the legacy boot order did.
		if floor_def.auto_connect_adjacent:
			world.auto_connect_adjacent_rooms()
	_persist_paused = false
	_ensure_player_placement(world, floor_def)
	# A successful load replaced in-memory state with disk state —
	# the floor is clean regardless of which world hosts it.
	_dirty_floors.erase(floor_id)
	if world == room_world:
		active_floor = floor_def
		floor_switched.emit(floor_def)
	return true

## Materializes a floor from its res:// definition ONLY: no layout
## override, no save-manifest check, no room-state hydration, no
## player-state restore. Multiplayer clients use this for their
## pre-snapshot boot — the authoritative layout and contents arrive
## later via WorldSnapshot.apply. The result is a valid but empty
## world; it is NOT save-compatible state.
func load_floor_without_save(floor_id: StringName, target_world: RoomWorld = null) -> bool:
	var floor_def := get_floor(floor_id)
	var world := target_world if target_world != null else room_world
	if floor_def == null or world == null:
		push_error("FloorManager.load_floor_without_save requires a registered floor and a RoomWorld.")
		return false
	var problems := validate_floor(floor_def)
	if not problems.is_empty():
		push_error("FloorManager.load_floor_without_save: floor '%s' is invalid: %s" % [floor_id, ", ".join(problems)])
		return false
	_persist_paused = true
	var materialized := materialize_floor(floor_def, world)
	_persist_paused = false
	if not materialized:
		return false
	_hook_world(world, floor_id)
	world.save_directory = floor_save_dir(floor_id)
	_dirty_floors.erase(floor_id)
	if world == room_world:
		active_floor = floor_def
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
## One-shot arrival override for the NEXT floor materialization:
## portal travel sets this to land the player on a specific cell
## (e.g. another portal) instead of a random spawn point. Consumed
## and cleared by _ensure_player_placement.
var _arrival_override_cell := FloorPortal.NO_DESTINATION_CELL

## switch_floor variant for portal travel: lands the player on
## world_cell of the destination floor when it resolves to a room
## cell, falling back to normal spawn placement otherwise.
func switch_floor_at(floor_id: StringName, world_cell: Vector2i) -> bool:
	_arrival_override_cell = world_cell
	var ok := switch_floor(floor_id)
	_arrival_override_cell = FloorPortal.NO_DESTINATION_CELL
	return ok

func switch_floor(floor_id: StringName) -> bool:
	if structural_edits_readonly():
		_refuse_readonly("switch_floor")
		return false
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
	if structural_edits_readonly():
		_refuse_readonly("add_room_to_active_floor")
		return null
	var floor_def := active_floor
	var world := room_world
	if floor_def == null or world == null or spec == null:
		push_error("FloorManager.add_room_to_active_floor requires an active floor, a RoomWorld, and a spec.")
		return null
	var result := _add_room_to_floor(floor_def, world, spec)
	if not result.get("ok", false):
		return null
	_persist_room_layout(floor_def)
	return result["room"]

## Floor-scoped counterpart of add_room_to_active_floor for floors
## hosted by a runtime world (multiplayer structural ops). Same
## validation and persistence; resolves the world via world_for_floor
## so room ids are never looked up globally. Returns the created Room
## or null.
func add_room_to_floor(floor_id: StringName, spec: FloorRoomSpec) -> Room:
	if structural_edits_readonly():
		_refuse_readonly("add_room_to_floor")
		return null
	var floor_def := get_floor(floor_id)
	var world := world_for_floor(floor_id)
	if floor_def == null or world == null or spec == null:
		push_error("FloorManager.add_room_to_floor requires a registered floor with a runtime world and a spec.")
		return null
	var result := _add_room_to_floor(floor_def, world, spec)
	if not result.get("ok", false):
		return null
	_persist_room_layout(floor_def)
	return result["room"]

## Validation + materialization half of room creation, floor-scoped
## and persistence-free: callers decide whether to write layout.json.
## Returns {"ok": bool, "room": Room, "spec": FloorRoomSpec,
## "reason": String} — spec is the normalized spec actually appended
## (origin/size rewritten to the footprint bbox), so broadcast
## payloads carry exactly what was registered.
func _add_room_to_floor(floor_def: Floor, world: RoomWorld, spec: FloorRoomSpec) -> Dictionary:
	var refuse := func(reason: String) -> Dictionary:
		push_error("FloorManager.add_room: %s" % reason)
		return {"ok": false, "room": null, "spec": null, "reason": reason}
	if floor_def == null or world == null or spec == null:
		return refuse.call("requires a floor, a RoomWorld, and a spec.")
	var sections := _spec_sections(spec)
	if sections.is_empty():
		return refuse.call("room %s has no resolvable size." % spec.room_id)
	var bounds := _sections_bounds(sections)
	if bounds.size.x < Floor.MIN_ROOM_DIMENSION or bounds.size.y < Floor.MIN_ROOM_DIMENSION:
		return refuse.call("room %s bounds %s are below the %dx%d minimum." % [
			spec.room_id, bounds.size, Floor.MIN_ROOM_DIMENSION, Floor.MIN_ROOM_DIMENSION])
	for section in sections:
		if section.size.x < Floor.MIN_ROOM_DIMENSION or section.size.y < Floor.MIN_ROOM_DIMENSION:
			return refuse.call("room %s section %s is below the %dx%d minimum." % [
				spec.room_id, section, Floor.MIN_ROOM_DIMENSION, Floor.MIN_ROOM_DIMENSION])
	for i in range(sections.size()):
		for j in range(i + 1, sections.size()):
			if sections[i].intersects(sections[j]):
				return refuse.call("room %s has overlapping shape sections." % spec.room_id)
	if not _sections_connected(sections):
		return refuse.call("room %s sections do not form one connected shape." % spec.room_id)
	for other in floor_def.rooms:
		if other == null:
			continue
		if other.room_id == spec.room_id:
			return refuse.call("room id %s is already used by this floor." % spec.room_id)
		if _sections_overlap(sections, _spec_sections(other)):
			return refuse.call("room %s at %s overlaps room %s." % [
				spec.room_id, bounds.position, other.room_id])
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
			return refuse.call("room %s at %s does not share an edge with any room on floor '%s'." % [
				spec.room_id, bounds.position, floor_def.floor_id])
	# Normalize: global_origin/size become the footprint's bounding box
	# so every rect-based consumer (bounds, saves, layout) stays exact.
	spec.global_origin = bounds.position
	spec.size = bounds.size
	var was_empty := floor_def.rooms.is_empty()
	var room := _create_room(world, spec)
	if room == null:
		return refuse.call("room %s failed to materialize." % spec.room_id)
	floor_def.rooms.append(spec)
	if was_empty:
		# First room on an empty floor becomes the entry/spawn so the
		# floor stays loadable and valid.
		floor_def.entry_room_id = spec.room_id
		floor_def.spawn_position = Vector2i(bounds.size.x >> 1, bounds.size.y >> 1)
		# ...and the floor's first spawn point.
		_normalize_spawn_points(floor_def)
	if floor_def.auto_connect_adjacent:
		world.auto_connect_adjacent_rooms()
	mark_floor_dirty(floor_def.floor_id)
	return {"ok": true, "room": room, "spec": spec, "reason": ""}

## Reports whether a room may be deleted from the active floor.
## Returns {"allowed": bool, "reason": String}. A room is deletable
## only when it holds no placed contents, the player is not inside it,
## it is not the floor's last room, it has no explicit floor
## connections, and every edge-adjacent room keeps at least one other
## adjacent room afterwards.
func can_delete_room(room_id: Vector2i) -> Dictionary:
	return _can_delete_room(active_floor, room_world, room_id, {})

## Floor-scoped counterpart for runtime worlds (multiplayer). occupied
## maps room_id -> true for every authoritative body standing in that
## room on this floor — the local "player" group only sees the server's
## own avatar, so remote occupants must be passed in explicitly.
func can_delete_room_on_floor(floor_id: StringName, room_id: Vector2i,
		occupied: Dictionary = {}) -> Dictionary:
	return _can_delete_room(get_floor(floor_id), world_for_floor(floor_id), room_id, occupied)

func _can_delete_room(floor_def: Floor, world: RoomWorld, room_id: Vector2i,
		occupied: Dictionary) -> Dictionary:
	var refuse := func(reason: String) -> Dictionary:
		return {"allowed": false, "reason": reason}
	if floor_def == null or world == null:
		return refuse.call("No floor world.")
	var room := world.get_room(room_id)
	if room == null:
		return refuse.call("Room is not instantiated.")
	if room.has_placed_contents():
		return refuse.call("Room has placed contents.")
	if occupied.has(room_id):
		return refuse.call("A player occupies the room.")
	var player := _player()
	if player != null and player.room == room:
		return refuse.call("Player is inside the room.")
	var bounds := _floor_spec_bounds_for(floor_def)
	if bounds.size() <= 1:
		return refuse.call("Cannot delete the last room on the floor.")
	for connection in floor_def.connections:
		if connection != null and (connection.source_room_id == room_id \
				or connection.destination_room_id == room_id):
			return refuse.call("Room has explicit floor connections.")
	var all_sections := _floor_spec_sections_for(floor_def)
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
	# Spawn points: deleting a room removes every spawn point inside
	# it — allowed only while the floor keeps MIN_SPAWN_POINTS.
	var spawns := floor_spawn_points(floor_def)
	if not spawns.is_empty():
		var inside := 0
		for cell in spawns:
			if _cell_in_sections(cell, target_sections):
				inside += 1
		if inside > 0 and spawns.size() - inside < Floor.MIN_SPAWN_POINTS:
			return refuse.call("Room contains spawn point(s); the floor must keep at least %d." % Floor.MIN_SPAWN_POINTS)
	return {"allowed": true, "reason": ""}

## Deletes a room from the active floor: unregisters it, removes every
## runtime connection touching it, repairs entry/spawn when needed,
## drops the spec, and persists the layout. Returns false (with the
## reason pushed to the console) when can_delete_room refuses.
func remove_room_from_active_floor(room_id: Vector2i) -> bool:
	if structural_edits_readonly():
		_refuse_readonly("remove_room_from_active_floor")
		return false
	var floor_def := active_floor
	var world := room_world
	if floor_def == null or world == null:
		push_error("FloorManager.remove_room_from_active_floor requires an active floor and a RoomWorld.")
		return false
	return _remove_room_from_floor(floor_def, world, room_id, {}, true)

## Floor-scoped counterpart for runtime worlds (multiplayer structural
## ops). occupied maps room_id -> true for authoritative bodies on this
## floor; pass {} for the single-player/local-player check only.
func remove_room_from_floor(floor_id: StringName, room_id: Vector2i,
		occupied: Dictionary = {}) -> bool:
	if structural_edits_readonly():
		_refuse_readonly("remove_room_from_floor")
		return false
	var floor_def := get_floor(floor_id)
	var world := world_for_floor(floor_id)
	if floor_def == null or world == null:
		push_error("FloorManager.remove_room_from_floor requires a registered floor with a runtime world.")
		return false
	return _remove_room_from_floor(floor_def, world, room_id, occupied, true)

## Validation + mechanical removal shared by every delete path.
## persist=true writes connections.json + layout.json (server/SP);
## persist=false is the client replica path — the authoritative graph
## arrives via broadcasts/snapshots, never local disk.
func _remove_room_from_floor(floor_def: Floor, world: RoomWorld, room_id: Vector2i,
		occupied: Dictionary, persist: bool) -> bool:
	var verdict := _can_delete_room(floor_def, world, room_id, occupied)
	if not verdict.get("allowed", false):
		push_error("FloorManager.remove_room: %s" % verdict.get("reason", "refused"))
		return false
	var all_sections := _floor_spec_sections_for(floor_def)
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
	# Spawn points inside the deleted room go with it; entry/spawn
	# resync to the first remaining point.
	if not floor_def.spawn_points.is_empty():
		var kept: Array[Vector2i] = []
		for cell in floor_def.spawn_points:
			if not _cell_in_sections(cell, target_sections):
				kept.append(cell)
		floor_def.spawn_points = kept
		_sync_entry_from_spawns(floor_def)
	# Portals inside the deleted room go with it (no minimum — unlike
	# spawn points a floor may end up with zero portals).
	if not floor_def.portals.is_empty():
		var kept_portals: Array[FloorPortal] = []
		for portal in floor_def.portals:
			if portal != null and portal.room_id != room_id:
				kept_portals.append(portal)
		floor_def.portals = kept_portals
	if persist:
		# Persist the pruned connection graph immediately — otherwise
		# the stale connections.json would resurrect doors to the
		# deleted room on the next load.
		var conn_error := RoomSaveSystem.save_connections(world)
		if conn_error != OK:
			push_warning("FloorManager.remove_room: connection save failed (error %d)." % conn_error)
		_persist_room_layout(floor_def)
	mark_floor_dirty(floor_def.floor_id)
	return true

## Sets both visibility flags on a room and its floor spec, optionally
## persisting layout.json. Returns false when the room or spec is
## missing on the given floor.
func _set_room_visibility(floor_def: Floor, world: RoomWorld, room_id: Vector2i,
		show_from_outside: bool, show_outside: bool, persist: bool) -> bool:
	if floor_def == null or world == null:
		return false
	var room := world.get_room(room_id)
	var spec := floor_def.find_room_spec(room_id)
	if room == null or spec == null:
		return false
	room.show_from_outside = show_from_outside
	room.show_outside = show_outside
	spec.show_from_outside = show_from_outside
	spec.show_outside = show_outside
	if persist:
		_persist_room_layout(floor_def)
	mark_floor_dirty(floor_def.floor_id)
	return true

## Server/SP entry point: visibility change on any floor with a
## runtime world. Floor-scoped so room ids never resolve globally.
func set_room_visibility_on_floor(floor_id: StringName, room_id: Vector2i,
		show_from_outside: bool, show_outside: bool) -> bool:
	if structural_edits_readonly():
		_refuse_readonly("set_room_visibility_on_floor")
		return false
	return _set_room_visibility(get_floor(floor_id), world_for_floor(floor_id),
		room_id, show_from_outside, show_outside, true)

# ------------------------------------------------------------------
# Spawn points
# ------------------------------------------------------------------
##
## Spawn points are global world cells marking a floor's natural
## entries (future teleport targets). Invariants: 1..Floor.
## MAX_SPAWN_POINTS points, each inside a room's footprint, and the
## FIRST point mirrors entry_room_id/spawn_position so every existing
## spawn path (load_floor, _ensure_player_placement, floor
## transitions) keeps working unchanged. Floors registered before the
## field existed derive one point from entry/spawn
## (_normalize_spawn_points); layout.json/floor_def.json/snapshots
## carry the explicit list.

## The floor's spawn points as global world cells. Derives the
## legacy entry/spawn point on the fly when the list is empty so
## callers never special-case unnormalized floors.
func floor_spawn_points(floor_def: Floor) -> Array[Vector2i]:
	if floor_def == null:
		return []
	if not floor_def.spawn_points.is_empty():
		return floor_def.spawn_points
	var derived: Variant = _derive_spawn_point(floor_def)
	return [derived] if derived is Vector2i else []

## The spec whose footprint contains the global world cell, or null.
## Cell-exact: shaped rooms only own their section cells.
func spawn_cell_room(floor_def: Floor, world_cell: Vector2i) -> FloorRoomSpec:
	if floor_def == null:
		return null
	for spec in floor_def.rooms:
		if spec != null and _cell_in_sections(world_cell, _spec_sections(spec)):
			return spec
	return null

## True when world_cell sits inside a room footprint of the floor as
## it will actually materialize. The on-disk layout.json wins over
## the in-memory specs: a floor that has not been loaded yet this
## session still carries its registration-time floor_def.json specs,
## which can predate later layout edits — checking those produces
## false "arrival cell outside rooms" warnings for valid portals.
## Floors without a layout override (res:// content, MP replicas)
## fall back to the live specs.
func _arrival_cell_valid_on_floor(floor_id: StringName, floor_def: Floor,
		world_cell: Vector2i) -> bool:
	var layout := FloorSaveSystem.load_layout(floor_id)
	var entries: Variant = layout.get("rooms")
	if entries is Array and not (entries as Array).is_empty():
		for entry in entries:
			if not (entry is Dictionary):
				continue
			var spec := spec_from_layout_entry(entry)
			if spec != null \
					and _cell_in_sections(world_cell, _spec_sections(spec)):
				return true
		return false
	return spawn_cell_room(floor_def, world_cell) != null

## Populates spawn_points from entry_room_id/spawn_position when the
## floor has none — the migration path for .tres floors and old saves.
## Idempotent; explicit lists are never touched.
func _normalize_spawn_points(floor_def: Floor) -> void:
	if floor_def == null or not floor_def.spawn_points.is_empty():
		return
	var derived: Variant = _derive_spawn_point(floor_def)
	if derived is Vector2i:
		floor_def.spawn_points = [derived]

## Global cell for the legacy entry/spawn: the entry spec's
## global_origin + spawn_position (clamped into the spec's bounds and
## snapped inside shaped-room sections), or the first room as
## fallback. Returns null when the floor has no usable room.
func _derive_spawn_point(floor_def: Floor) -> Variant:
	var spec := floor_def.find_room_spec(floor_def.entry_room_id)
	if spec == null and not floor_def.rooms.is_empty():
		spec = floor_def.rooms[0]
	if spec == null:
		return null
	var size := _resolved_spec_size(spec)
	var local := floor_def.spawn_position
	if size != Vector2i.ZERO:
		local = local.clamp(Vector2i.ZERO, size - Vector2i.ONE)
	var global := spec.global_origin + local
	var sections := _spec_sections(spec)
	if sections.is_empty():
		return null
	if not _cell_in_sections(global, sections):
		global = _nearest_section_cell(sections, global)
	return global

## Rewrites entry_room_id/spawn_position to mirror spawn_points[0]:
## the entry room becomes the spec containing that cell and
## spawn_position its local coordinate. No-op when the floor has no
## resolvable spawn point.
func _sync_entry_from_spawns(floor_def: Floor) -> void:
	var spawns := floor_spawn_points(floor_def)
	if spawns.is_empty():
		return
	var cell: Vector2i = spawns[0]
	var spec := spawn_cell_room(floor_def, cell)
	if spec == null:
		return
	floor_def.entry_room_id = spec.room_id
	floor_def.spawn_position = cell - spec.global_origin

## Reports whether a global world cell may host a new spawn point.
## Core verdict shared by the active-floor and floor-scoped entry
## points; persist/dirty marking stays in the callers.
func _can_place_spawn_point(floor_def: Floor, world_cell: Vector2i) -> Dictionary:
	var refuse := func(reason: String) -> Dictionary:
		return {"allowed": false, "reason": reason}
	if floor_def == null:
		return refuse.call("No floor.")
	if spawn_cell_room(floor_def, world_cell) == null:
		return refuse.call("Spawn points must be inside a room.")
	var spawns := floor_spawn_points(floor_def)
	if spawns.has(world_cell):
		return refuse.call("A spawn point already occupies that cell.")
	if spawns.size() >= Floor.MAX_SPAWN_POINTS:
		return refuse.call("Maximum %d spawn points per floor." % Floor.MAX_SPAWN_POINTS)
	return {"allowed": true, "reason": ""}

## Reports whether a global world cell may host a new spawn point on
## the ACTIVE floor. Mirrors can_delete_room's verdict shape.
func can_place_spawn_point(world_cell: Vector2i) -> Dictionary:
	if structural_edits_readonly():
		return {"allowed": false, "reason": "Multiplayer client: edits are server-authoritative."}
	if active_floor == null:
		return {"allowed": false, "reason": "No active floor."}
	return _can_place_spawn_point(active_floor, world_cell)

## Floor-scoped counterpart for runtime worlds (multiplayer structural
## ops). No readonly guard — callers decide (server validates, replica
## applies through replica_apply_spawn instead).
func can_place_spawn_point_on_floor(floor_id: StringName, world_cell: Vector2i) -> Dictionary:
	return _can_place_spawn_point(get_floor(floor_id), world_cell)

## Places a spawn point at a global world cell. Core mutation shared
## by every entry point; persist=true writes layout.json.
func _place_spawn_point(floor_def: Floor, world_cell: Vector2i, persist: bool) -> bool:
	if not bool(_can_place_spawn_point(floor_def, world_cell).get("allowed", false)):
		return false
	floor_def.spawn_points.append(world_cell)
	_sync_entry_from_spawns(floor_def)
	if persist:
		_persist_room_layout(floor_def)
		mark_floor_dirty(floor_def.floor_id)
	return true

## Places a spawn point on the active floor at a global world cell.
## Persists layout.json and marks the floor dirty.
func place_spawn_point(world_cell: Vector2i) -> bool:
	if structural_edits_readonly():
		_refuse_readonly("place_spawn_point")
		return false
	if active_floor == null:
		push_error("FloorManager.place_spawn_point requires an active floor.")
		return false
	var verdict := can_place_spawn_point(world_cell)
	if not bool(verdict.get("allowed", false)):
		push_error("FloorManager.place_spawn_point: %s" % verdict.get("reason", "refused"))
		return false
	return _place_spawn_point(active_floor, world_cell, true)

## Floor-scoped counterpart for runtime worlds (multiplayer). Server
## path: validates, mutates, persists, marks dirty.
func place_spawn_point_on_floor(floor_id: StringName, world_cell: Vector2i) -> bool:
	if structural_edits_readonly():
		_refuse_readonly("place_spawn_point_on_floor")
		return false
	var floor_def := get_floor(floor_id)
	if floor_def == null:
		push_error("FloorManager.place_spawn_point_on_floor: unknown floor '%s'." % floor_id)
		return false
	var verdict := _can_place_spawn_point(floor_def, world_cell)
	if not bool(verdict.get("allowed", false)):
		push_error("FloorManager.place_spawn_point_on_floor: %s" % verdict.get("reason", "refused"))
		return false
	return _place_spawn_point(floor_def, world_cell, true)

## Reports whether the spawn point at a global world cell may be
## removed: it must exist and the floor must keep at least
## Floor.MIN_SPAWN_POINTS afterwards.
func _can_remove_spawn_point(floor_def: Floor, world_cell: Vector2i) -> Dictionary:
	var refuse := func(reason: String) -> Dictionary:
		return {"allowed": false, "reason": reason}
	if floor_def == null:
		return refuse.call("No floor.")
	var spawns := floor_spawn_points(floor_def)
	if not spawns.has(world_cell):
		return refuse.call("No spawn point on that cell.")
	if spawns.size() <= Floor.MIN_SPAWN_POINTS:
		return refuse.call("A floor must keep at least %d spawn point." % Floor.MIN_SPAWN_POINTS)
	return {"allowed": true, "reason": ""}

func can_remove_spawn_point(world_cell: Vector2i) -> Dictionary:
	if structural_edits_readonly():
		return {"allowed": false, "reason": "Multiplayer client: edits are server-authoritative."}
	if active_floor == null:
		return {"allowed": false, "reason": "No active floor."}
	return _can_remove_spawn_point(active_floor, world_cell)

func can_remove_spawn_point_on_floor(floor_id: StringName, world_cell: Vector2i) -> Dictionary:
	return _can_remove_spawn_point(get_floor(floor_id), world_cell)

## Removes the spawn point at a global world cell. Core mutation;
## persist=true writes layout.json and marks the floor dirty.
func _remove_spawn_point(floor_def: Floor, world_cell: Vector2i, persist: bool) -> bool:
	if not bool(_can_remove_spawn_point(floor_def, world_cell).get("allowed", false)):
		return false
	floor_def.spawn_points.erase(world_cell)
	_sync_entry_from_spawns(floor_def)
	if persist:
		_persist_room_layout(floor_def)
		mark_floor_dirty(floor_def.floor_id)
	return true

## Removes the spawn point at a global world cell from the active
## floor, resyncs entry/spawn to the first remaining point, persists
## layout.json, and marks the floor dirty.
func remove_spawn_point(world_cell: Vector2i) -> bool:
	if structural_edits_readonly():
		_refuse_readonly("remove_spawn_point")
		return false
	if active_floor == null:
		push_error("FloorManager.remove_spawn_point requires an active floor.")
		return false
	var verdict := can_remove_spawn_point(world_cell)
	if not bool(verdict.get("allowed", false)):
		push_error("FloorManager.remove_spawn_point: %s" % verdict.get("reason", "refused"))
		return false
	return _remove_spawn_point(active_floor, world_cell, true)

## Floor-scoped counterpart for runtime worlds (multiplayer). Server
## path: validates, mutates, persists, marks dirty.
func remove_spawn_point_on_floor(floor_id: StringName, world_cell: Vector2i) -> bool:
	if structural_edits_readonly():
		_refuse_readonly("remove_spawn_point_on_floor")
		return false
	var floor_def := get_floor(floor_id)
	if floor_def == null:
		push_error("FloorManager.remove_spawn_point_on_floor: unknown floor '%s'." % floor_id)
		return false
	var verdict := _can_remove_spawn_point(floor_def, world_cell)
	if not bool(verdict.get("allowed", false)):
		push_error("FloorManager.remove_spawn_point_on_floor: %s" % verdict.get("reason", "refused"))
		return false
	return _remove_spawn_point(floor_def, world_cell, true)

## Replica apply (multiplayer clients): applies an accepted spawn op
## to the floor's in-memory spec list — no validation verdicts, no
## persistence, no dirty marking; the authoritative result already
## happened on the server. Deterministic: place appends, remove
## erases, both resync entry/spawn to the first point.
func replica_apply_spawn(floor_id: StringName, world_cell: Vector2i, place: bool) -> bool:
	var floor_def := get_floor(floor_id)
	if floor_def == null:
		return false
	var ok := false
	if place:
		ok = _place_spawn_point(floor_def, world_cell, false)
	else:
		ok = _remove_spawn_point(floor_def, world_cell, false)
	return ok

# ------------------------------------------------------------------
# Floor portals (Phase P1): FloorPortal resources on Floor.portals —
# global world cells that transition the player to another Floor.
# Independent from RoomConnection (which stays intra-floor). Portals
# are floor data: they persist in layout.json/floor_def.json, ride
# world snapshots, and need no runtime world reference.
# ------------------------------------------------------------------

## The floor's portals (empty list when none or no floor).
func floor_portals(floor_def: Floor) -> Array[FloorPortal]:
	if floor_def == null:
		return []
	return floor_def.portals

## The portal occupying a global world cell on the ACTIVE floor, or
## null. At most one portal may occupy a cell (placement enforces it).
func portal_at(world_cell: Vector2i) -> FloorPortal:
	return portal_at_on_floor(active_floor.floor_id if active_floor != null else &"", world_cell)

## Floor-scoped lookup: the portal at a global world cell on the given
## floor, or null. Works for unmaterialized floors — portals are spec
## data, not world state.
func portal_at_on_floor(floor_id: StringName, world_cell: Vector2i) -> FloorPortal:
	var floor_def := get_floor(floor_id)
	if floor_def == null:
		return null
	for portal in floor_def.portals:
		if portal != null and portal.world_cell == world_cell:
			return portal
	return null

## Cell-only verdict for the Creation Mode ghost: the cell must be
## inside a room footprint, host no portal yet, and not be covered by
## an interactive RoomConnection (which would make stepping onto it
## ambiguous). Destination checks live in can_place_portal.
func portal_cell_status(world_cell: Vector2i) -> Dictionary:
	if structural_edits_readonly():
		return {"free": false, "reason": "Multiplayer client: edits are server-authoritative."}
	if active_floor == null:
		return {"free": false, "reason": "No active floor."}
	return _portal_cell_status_for(active_floor, room_world, world_cell, null)

func _portal_cell_status_for(floor_def: Floor, world: RoomWorld,
		world_cell: Vector2i, exclude: FloorPortal) -> Dictionary:
	var refuse := func(reason: String) -> Dictionary:
		return {"free": false, "reason": reason}
	if floor_def == null:
		return refuse.call("No floor.")
	var spec := spawn_cell_room(floor_def, world_cell)
	if spec == null:
		return refuse.call("Portals must be inside a room.")
	for portal in floor_def.portals:
		if portal != null and portal != exclude and portal.world_cell == world_cell:
			return refuse.call("A portal already occupies that cell.")
	# An interactive connection covering this cell already triggers a
	# room transition on entry — a portal there would be ambiguous.
	var local_cell := world_cell - spec.global_origin
	for connection in _portal_scan_connections(floor_def, world):
		if connection == null or not connection.interactive:
			continue
		var traversal: Dictionary = connection.traversal_for(spec.room_id)
		if traversal.is_empty():
			continue
		if (traversal["exits"] as Array).has(local_cell):
			return refuse.call("Cell is covered by interactive connection '%s'." % connection.connection_id)
	return {"free": true, "reason": ""}

## Connections to scan for interactive coverage: the live world graph
## when the floor is materialized (includes restored/saved links),
## else the floor's authored connection list.
func _portal_scan_connections(floor_def: Floor, world: RoomWorld) -> Array:
	if world != null and world.connections != null:
		return world.connections.get_all_connections()
	return floor_def.connections

## Reports whether a portal may be placed at a global world cell on
## the ACTIVE floor leading to destination_floor_id. Cell rules come
## from portal_cell_status; the destination must be another registered
## floor.
func can_place_portal(world_cell: Vector2i, destination_floor_id: StringName,
		arrival_cell: Vector2i = FloorPortal.NO_DESTINATION_CELL) -> Dictionary:
	if structural_edits_readonly():
		return {"allowed": false, "reason": "Multiplayer client: edits are server-authoritative."}
	if active_floor == null:
		return {"allowed": false, "reason": "No active floor."}
	return _can_place_portal(active_floor, room_world, world_cell,
		destination_floor_id, null, arrival_cell)

func _can_place_portal(floor_def: Floor, world: RoomWorld, world_cell: Vector2i,
		destination_floor_id: StringName, exclude: FloorPortal,
		arrival_cell: Vector2i = FloorPortal.NO_DESTINATION_CELL) -> Dictionary:
	var cell_status := _portal_cell_status_for(floor_def, world, world_cell, exclude)
	if not bool(cell_status.get("free", false)):
		return {"allowed": false, "reason": cell_status.get("reason", "refused")}
	if destination_floor_id == &"":
		return {"allowed": false, "reason": "No destination floor selected."}
	if destination_floor_id == floor_def.floor_id:
		return {"allowed": false, "reason": "A portal cannot target its own floor."}
	var dest_def := get_floor(destination_floor_id)
	if dest_def == null:
		return {"allowed": false, "reason": "Destination floor '%s' is not registered." % destination_floor_id}
	if arrival_cell != FloorPortal.NO_DESTINATION_CELL \
			and not _arrival_cell_valid_on_floor(destination_floor_id,
				dest_def, arrival_cell):
		return {"allowed": false, "reason": "Arrival cell %s is not inside a room on floor '%s'." % [
			_id_text(arrival_cell), destination_floor_id]}
	return {"allowed": true, "reason": ""}

## Places a portal at a global world cell on the active floor. The id
## derives deterministically from the cell — unique because one portal
## per cell is enforced. Persists layout.json and marks the floor dirty.
func place_portal(world_cell: Vector2i, destination_floor_id: StringName,
		arrival_cell: Vector2i = FloorPortal.NO_DESTINATION_CELL) -> bool:
	if structural_edits_readonly():
		_refuse_readonly("place_portal")
		return false
	if active_floor == null:
		push_error("FloorManager.place_portal requires an active floor.")
		return false
	var verdict := can_place_portal(world_cell, destination_floor_id, arrival_cell)
	if not bool(verdict.get("allowed", false)):
		push_error("FloorManager.place_portal: %s" % verdict.get("reason", "refused"))
		return false
	return _place_portal(active_floor, world_cell, destination_floor_id, true, arrival_cell)

## Floor-scoped counterpart for runtime worlds (multiplayer). Server
## path: validates, mutates, persists, marks dirty.
func place_portal_on_floor(floor_id: StringName, world_cell: Vector2i,
		destination_floor_id: StringName,
		arrival_cell: Vector2i = FloorPortal.NO_DESTINATION_CELL) -> bool:
	if structural_edits_readonly():
		_refuse_readonly("place_portal_on_floor")
		return false
	var floor_def := get_floor(floor_id)
	if floor_def == null:
		push_error("FloorManager.place_portal_on_floor: unknown floor '%s'." % floor_id)
		return false
	var verdict := _can_place_portal(floor_def, world_for_floor(floor_id),
		world_cell, destination_floor_id, null, arrival_cell)
	if not bool(verdict.get("allowed", false)):
		push_error("FloorManager.place_portal_on_floor: %s" % verdict.get("reason", "refused"))
		return false
	return _place_portal(floor_def, world_cell, destination_floor_id, true, arrival_cell)

func _place_portal(floor_def: Floor, world_cell: Vector2i,
		destination_floor_id: StringName, persist: bool,
		arrival_cell: Vector2i = FloorPortal.NO_DESTINATION_CELL) -> bool:
	var spec := spawn_cell_room(floor_def, world_cell)
	if spec == null:
		return false
	var portal := FloorPortal.new()
	portal.portal_id = StringName("portal_%d_%d" % [world_cell.x, world_cell.y])
	portal.room_id = spec.room_id
	portal.world_cell = world_cell
	portal.destination_floor_id = destination_floor_id
	portal.destination_world_cell = arrival_cell
	floor_def.portals.append(portal)
	if persist:
		_persist_room_layout(floor_def)
		mark_floor_dirty(floor_def.floor_id)
	return true

## Reports whether the portal at a global world cell may be removed.
func can_remove_portal(world_cell: Vector2i) -> Dictionary:
	if structural_edits_readonly():
		return {"allowed": false, "reason": "Multiplayer client: edits are server-authoritative."}
	if active_floor == null:
		return {"allowed": false, "reason": "No active floor."}
	if portal_at(world_cell) == null:
		return {"allowed": false, "reason": "No portal on that cell."}
	return {"allowed": true, "reason": ""}

## Removes the portal at a global world cell from the active floor.
## Persists layout.json and marks the floor dirty.
func remove_portal(world_cell: Vector2i) -> bool:
	if structural_edits_readonly():
		_refuse_readonly("remove_portal")
		return false
	if active_floor == null:
		push_error("FloorManager.remove_portal requires an active floor.")
		return false
	var verdict := can_remove_portal(world_cell)
	if not bool(verdict.get("allowed", false)):
		push_error("FloorManager.remove_portal: %s" % verdict.get("reason", "refused"))
		return false
	return _remove_portal(active_floor, world_cell, true)

## Floor-scoped counterpart for runtime worlds (multiplayer). Server
## path: validates, mutates, persists, marks dirty.
func remove_portal_on_floor(floor_id: StringName, world_cell: Vector2i) -> bool:
	if structural_edits_readonly():
		_refuse_readonly("remove_portal_on_floor")
		return false
	var floor_def := get_floor(floor_id)
	if floor_def == null:
		push_error("FloorManager.remove_portal_on_floor: unknown floor '%s'." % floor_id)
		return false
	if portal_at_on_floor(floor_id, world_cell) == null:
		push_error("FloorManager.remove_portal_on_floor: no portal on that cell.")
		return false
	return _remove_portal(floor_def, world_cell, true)

func _remove_portal(floor_def: Floor, world_cell: Vector2i, persist: bool) -> bool:
	for i in range(floor_def.portals.size() - 1, -1, -1):
		var portal: FloorPortal = floor_def.portals[i]
		if portal != null and portal.world_cell == world_cell:
			floor_def.portals.remove_at(i)
			if persist:
				_persist_room_layout(floor_def)
				mark_floor_dirty(floor_def.floor_id)
			return true
	return false

## Retargets the portal at a global world cell to a new destination
## floor. The portal keeps its id/cell/room — only the destination
## changes. Validates the new destination like a fresh placement.
func update_portal_destination(world_cell: Vector2i, destination_floor_id: StringName,
		arrival_cell: Vector2i = FloorPortal.NO_DESTINATION_CELL) -> bool:
	if structural_edits_readonly():
		_refuse_readonly("update_portal_destination")
		return false
	if active_floor == null:
		push_error("FloorManager.update_portal_destination requires an active floor.")
		return false
	var portal := portal_at(world_cell)
	if portal == null:
		push_error("FloorManager.update_portal_destination: no portal on that cell.")
		return false
	if portal.destination_floor_id == destination_floor_id \
			and portal.destination_world_cell == arrival_cell:
		return true
	var verdict := _can_place_portal(active_floor, room_world, world_cell,
		destination_floor_id, portal, arrival_cell)
	if not bool(verdict.get("allowed", false)):
		push_error("FloorManager.update_portal_destination: %s" % verdict.get("reason", "refused"))
		return false
	portal.destination_floor_id = destination_floor_id
	portal.destination_world_cell = arrival_cell
	_persist_room_layout(active_floor)
	mark_floor_dirty(active_floor.floor_id)
	return true

## ------------------------------------------------------------------
## Replica apply (multiplayer clients): unguarded, persistence-free
## counterparts of the mutation cores. WorldSnapshot.apply and these
## ops are the ONLY ways a client world changes — they never write
## user:// and never re-request. floor_id must be the client's own
## replicated floor; callers filter before invoking.
## ------------------------------------------------------------------

## Applies an authoritative room creation. spec_entry is the
## FloorSaveSystem.spec_to_layout_entry shape carried by the broadcast.
func replica_add_room(floor_id: StringName, spec_entry: Dictionary) -> Room:
	var floor_def := get_floor(floor_id)
	if floor_def == null or room_world == null or not (spec_entry is Dictionary):
		return null
	var spec := spec_from_layout_entry(spec_entry)
	if spec == null:
		return null
	var result := _add_room_to_floor(floor_def, room_world, spec)
	return result.get("room") if result.get("ok", false) else null

## Applies an authoritative room deletion on the client's replica.
func replica_remove_room(floor_id: StringName, room_id: Vector2i) -> bool:
	var floor_def := get_floor(floor_id)
	if floor_def == null or room_world == null:
		return false
	return _remove_room_from_floor(floor_def, room_world, room_id, {}, false)

## Applies an authoritative visibility change on the client's replica.
func replica_set_room_visibility(floor_id: StringName, room_id: Vector2i,
		show_from_outside: bool, show_outside: bool) -> bool:
	var floor_def := get_floor(floor_id)
	if floor_def == null or room_world == null:
		return false
	return _set_room_visibility(floor_def, room_world, room_id,
		show_from_outside, show_outside, false)

## room_id -> global bounds Rect2i for every spec with a resolvable
## size on the given floor (active_floor when null is NOT assumed —
## callers pass the floor explicitly).
func _floor_spec_bounds_for(floor_def: Floor) -> Dictionary:
	var bounds := {}
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

func _floor_spec_bounds() -> Dictionary:
	return _floor_spec_bounds_for(active_floor)

## room_id -> Array[Rect2i] of global footprint sections for every
## spec on the given floor. Cell-exact adjacency for shaped rooms.
func _floor_spec_sections_for(floor_def: Floor) -> Dictionary:
	var sections := {}
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

func _floor_spec_sections() -> Dictionary:
	return _floor_spec_sections_for(active_floor)

## Writes a floor's layout.json regardless of which world hosts it —
## floor-scoped persistence for runtime worlds.
func _persist_room_layout(floor_def: Floor) -> void:
	var error := FloorSaveSystem.save_layout(floor_def)
	if error != OK:
		push_warning("FloorManager: layout save for floor '%s' failed (error %d)." % [
			floor_def.floor_id if floor_def != null else &"?", error])

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
	if data.is_empty():
		return
	_apply_layout_entries(floor_def, data)

## Applies an already-parsed layout dictionary — the same shape
## FloorSaveSystem.load_layout returns — to floor_def in memory.
## Used by the multiplayer snapshot path so a client adopts the
## server's authoritative room layout; never writes layout.json and
## never touches res:// resources. Returns false when the data holds
## no usable room specs.
func apply_layout_data(floor_def: Floor, data: Dictionary) -> bool:
	if floor_def == null or not (data is Dictionary):
		return false
	var entries: Variant = data.get("rooms")
	if not (entries is Array) or (entries as Array).is_empty():
		return false
	_apply_layout_entries(floor_def, data)
	return not floor_def.rooms.is_empty()

## The spec-parsing half of the layout override, shared by the
## user:// path (_apply_layout_override) and the network path
## (apply_layout_data). Entries that fail to parse are skipped with
## a warning; entry/spawn ride along when present.
func _apply_layout_entries(floor_def: Floor, data: Dictionary) -> void:
	var entries: Array = data.get("rooms", [])
	var specs: Array[FloorRoomSpec] = []
	for entry in entries:
		if not (entry is Dictionary):
			push_warning("FloorManager: skipping malformed layout entry in floor '%s'." % floor_def.floor_id)
			continue
		var spec := spec_from_layout_entry(entry)
		if spec == null:
			push_warning("FloorManager: skipping malformed layout entry in floor '%s'." % floor_def.floor_id)
			continue
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
	var spawn_points_raw: Variant = data.get("spawn_points")
	if spawn_points_raw is Array:
		var cells: Array[Vector2i] = []
		for raw_cell in spawn_points_raw:
			if raw_cell is Array and (raw_cell as Array).size() == 2:
				cells.append(_layout_vec2i(raw_cell))
		floor_def.spawn_points = cells
	# Portals ride the same layout payload. Entries that fail to parse
	# are skipped with a warning — a malformed portal never blocks the
	# floor's room layout. Missing key (older saves) leaves resource-
	# authored portals untouched; an explicit array replaces them.
	var portals_raw: Variant = data.get("portals")
	if portals_raw is Array:
		floor_def.portals.clear()
		for raw_portal in portals_raw:
			var portal := FloorSaveSystem.portal_from_dict(raw_portal)
			if portal == null:
				push_warning("FloorManager: skipping malformed portal entry in floor '%s'." % floor_def.floor_id)
				continue
			floor_def.portals.append(portal)
	_normalize_spawn_points(floor_def)
	_sync_entry_from_spawns(floor_def)
	print("FloorManager: floor '%s' layout override applied (%d room spec(s))." % [
		floor_def.floor_id, specs.size()])

static func _layout_vec2i(value: Variant) -> Vector2i:
	if value is Array and (value as Array).size() >= 2:
		return Vector2i(int(value[0]), int(value[1]))
	return Vector2i.ZERO

## Parses one layout-entry Dictionary (the shape FloorSaveSystem.
## spec_to_layout_entry emits and layout.json stores) into a
## FloorRoomSpec, or null when the entry is unusable. Shared by the
## layout-override path and the multiplayer structural-ops protocol.
static func spec_from_layout_entry(entry: Dictionary) -> FloorRoomSpec:
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
	spec.scatter_ground = bool(entry.get("scatter_ground", false))
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
	return spec

func _player() -> Player:
	if not is_inside_tree():
		return null
	return get_tree().get_first_node_in_group(&"player") as Player

## Connects the world's content-change signal once so room edits mark
## THAT floor dirty. floor_id is stored per world — the same signal
## fires for every materialized world and must be attributed correctly.
func _hook_world(world: RoomWorld, floor_id: StringName) -> void:
	if world == null:
		return
	_world_floor[world] = floor_id
	var callback := _on_world_content_changed.bind(world)
	if not world.room_content_changed.is_connected(callback):
		world.room_content_changed.connect(callback)

func _on_world_content_changed(world: RoomWorld) -> void:
	if _persist_paused:
		return
	var floor_id: Variant = _world_floor.get(world)
	if floor_id == null and world == room_world and active_floor != null:
		floor_id = active_floor.floor_id
	if floor_id is StringName:
		mark_floor_dirty(floor_id)

## Picks where a player entering this floor should stand: a RANDOM
## spawn point (Floor.spawn_points — the floor's natural entries) when
## the list resolves to a live room, else the legacy entry_room_id/
## spawn_position fallback. Candidates are shuffled so every spawn
## point is equally likely and one stale point cannot block the rest.
## Returns {"room": Room, "cell": Vector2i} (cell is room-local) or {}
## when the floor has no usable room. Shared by _ensure_player_
## placement (single-player/snapshot) and the multiplayer transition
## path so both sides agree on the rule — the actual pick differs per
## call, which is the point: each player gets their own random entry.
## Resolves a portal's optional arrival override to a {room, cell}
## placement on the given world, or {} when the cell is unusable —
## callers fall back to spawn_placement_for. The cell must sit inside
## a room footprint (shaped-room holes snap to the nearest real cell,
## same rule as spawn placement).
func arrival_placement_for_cell(floor_def: Floor, world: RoomWorld,
		world_cell: Vector2i) -> Dictionary:
	if floor_def == null or world == null \
			or world_cell == FloorPortal.NO_DESTINATION_CELL:
		return {}
	var spec := spawn_cell_room(floor_def, world_cell)
	if spec == null:
		return {}
	var room := world.get_room(spec.room_id)
	if room == null:
		return {}
	var local: Vector2i = world_cell - spec.global_origin
	if not room.has_cell(local):
		local = _nearest_room_cell(room, local)
	return {"room": room, "cell": local}

func spawn_placement_for(floor_def: Floor, world: RoomWorld) -> Dictionary:
	if floor_def == null or world == null:
		return {}
	# duplicate(): floor_spawn_points may return the floor's live
	# array — shuffling it would reorder spawn_points[0] and break
	# the entry_room_id/spawn_position mirror.
	var candidates := floor_spawn_points(floor_def).duplicate()
	candidates.shuffle()
	for cell in candidates:
		var spec := spawn_cell_room(floor_def, cell)
		if spec == null:
			continue
		var room := world.get_room(spec.room_id)
		if room == null:
			continue
		var local: Vector2i = cell - spec.global_origin
		if not room.has_cell(local):
			local = _nearest_room_cell(room, local)
		return {"room": room, "cell": local}
	# Legacy fallback: entry room + spawn_position.
	var entry := world.get_room(floor_def.entry_room_id)
	if entry == null:
		var rooms := world.registry.get_rooms()
		if not rooms.is_empty():
			entry = rooms[0]
	if entry == null:
		return {}
	var spawn := floor_def.spawn_position
	if spawn.x < 0 or spawn.y < 0 or spawn.x >= entry.size.x or spawn.y >= entry.size.y:
		spawn = Vector2i(entry.size.x >> 1, entry.size.y >> 1)
	# Shaped rooms can have holes inside their bounding box; snap the
	# spawn to the nearest real footprint cell so the player never
	# lands somewhere they cannot move.
	if not entry.has_cell(spawn):
		spawn = _nearest_room_cell(entry, spawn)
	return {"room": entry, "cell": spawn}

## Places the player on the floor after a load/materialize. Floor
## entries ALWAYS spawn at a random spawn point
## (spawn_placement_for) — saved player_state no longer resumes a
## previous position; spawn points are the only entries.
func _ensure_player_placement(world: RoomWorld, floor_def: Floor) -> void:
	# Consume the one-shot arrival override up front so it can never
	# leak into a later placement when no player exists.
	var arrival_cell := _arrival_override_cell
	_arrival_override_cell = FloorPortal.NO_DESTINATION_CELL
	var player := _player()
	if player == null:
		return
	var placement := {}
	if arrival_cell != FloorPortal.NO_DESTINATION_CELL:
		placement = arrival_placement_for_cell(floor_def, world, arrival_cell)
	if placement.is_empty():
		placement = spawn_placement_for(floor_def, world)
	if placement.is_empty():
		push_warning("FloorManager: floor '%s' has no rooms; player left unplaced." % floor_def.floor_id)
		return
	var entry: Room = placement["room"]
	var spawn: Vector2i = placement["cell"]
	player.room_world = world
	player.room = entry
	player.block_layer = entry.block_layer
	player.room_size = entry.size
	player.place_at(spawn, player.stand_elevation_at(spawn))
	world.set_primary_room(entry.room_coordinates)

## Public entry point for spawn placement: WorldBootstrap calls this
## after spawning the player node because load_floor ran before the
## player existed. Defaults to the active floor and bound world.
func place_player_at_spawn(floor_def: Floor = null, world: RoomWorld = null) -> void:
	var def := floor_def if floor_def != null else active_floor
	var target := world if world != null else room_world
	if def == null or target == null:
		return
	_ensure_player_placement(target, def)

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
			if spec.scatter_ground:
				_scatter_ground_tiles(world, defined_room, spec)
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
		if spec.scatter_ground:
			_scatter_ground_tiles(world, room, spec)
	return room

## Scatters small organic blobs of GROUND_SCATTER_PATCH_IDS tiles over
## the room's bare (default-tile) cells. Runs once at room
## materialization — before saved content hydrates on top — so authored
## or player-painted tiles always win. The RNG is seeded from the room
## id + global origin, making the pattern identical on every peer and
## across reloads; patched cells land in room.auto_tiles so saves skip
## them and placed_content_counts ignores them while untouched.
func _scatter_ground_tiles(world: RoomWorld, room: Room, spec: FloorRoomSpec) -> void:
	var catalog := world.tile_catalog
	if catalog == null or room == null:
		return
	var patch_defs: Array[TileDefinition] = []
	for tile_id in GROUND_SCATTER_PATCH_IDS:
		var patch_def := catalog.get_definition(tile_id)
		if patch_def != null and patch_def != room.default_tile:
			patch_defs.append(patch_def)
	if patch_defs.is_empty():
		return
	# Eligible cells: still showing the room's default tile.
	var remaining := {}
	for coordinates in room.cells:
		var cell: RoomCell = room.cells[coordinates]
		if cell != null and cell.tile == room.default_tile:
			remaining[coordinates] = true
	if remaining.is_empty():
		return
	var rng := RandomNumberGenerator.new()
	rng.seed = hash("%s@%s" % [spec.room_id, str(spec.global_origin)])
	var patch_budget := maxi(1, floori(float(room.cells.size()) / 2.0))
	var patch_count := clampi(floori(float(room.cells.size()) / 8.0), 2, 20)
	var patched := 0
	var dirs: Array[Vector2i] = [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]
	while patch_count > 0 and patched < patch_budget and not remaining.is_empty():
		patch_count -= 1
		var tile_def: TileDefinition = patch_defs[rng.randi_range(0, patch_defs.size() - 1)]
		var blob: Array[Vector2i] = []
		var blob_target := mini(rng.randi_range(3, 8), patch_budget - patched)
		var keys := remaining.keys()
		blob.append(keys[rng.randi_range(0, keys.size() - 1)])
		var index := 0
		while index < blob.size() and blob.size() < blob_target and patched + blob.size() < patch_budget:
			var origin_cell: Vector2i = blob[index]
			index += 1
			var options: Array[Vector2i] = []
			for direction in dirs:
				var neighbor: Vector2i = origin_cell + direction
				if remaining.has(neighbor) and not blob.has(neighbor):
					options.append(neighbor)
			if options.is_empty():
				continue
			blob.append(options[rng.randi_range(0, options.size() - 1)])
		for coordinates in blob:
			remaining.erase(coordinates)
			var cell: RoomCell = room.cells[coordinates]
			cell.tile = tile_def
			room.auto_tiles[coordinates] = tile_def.object_id
		patched += blob.size()
	# Independent per-cell bush roll: any still-bare cell has a
	# GROUND_SCATTER_BUSHY_CHANCE probability of becoming bushy_grass,
	# scattered singly rather than in blobs.
	var bushy_def := catalog.get_definition(GROUND_SCATTER_BUSHY_ID)
	if bushy_def != null and bushy_def != room.default_tile:
		for coordinates in remaining.keys():
			if rng.randf() >= GROUND_SCATTER_BUSHY_CHANCE:
				continue
			remaining.erase(coordinates)
			var cell: RoomCell = room.cells[coordinates]
			cell.tile = bushy_def
			room.auto_tiles[coordinates] = bushy_def.object_id
			patched += 1
	if patched > 0:
		room._notify_changed()
