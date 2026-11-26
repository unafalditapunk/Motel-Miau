class_name RoomVisuals
extends Node

## Visual behavior for a RoomWorld's rooms: neighbor de-emphasis materials
## and transitions, neighborhood visibility, and slide in/out animations.
## Config (deemphasize_neighbors, hide_rooms_outside_neighborhood,
## room_slide_*, neighbor_*, emphasis_transition_duration) is read live
## from the owning RoomWorld so export changes apply immediately.

const NEIGHBOR_DEEMPHASIS_SHADER := preload("res://Shaders/NeighborDeemphasis.gdshader")

var _room_world: RoomWorld
var _room_materials: Dictionary = {}
var _emphasis_from: Dictionary = {}
var _emphasis_to: Dictionary = {}
var _emphasis_tween: Tween
var _room_home: Dictionary = {}
var _room_slide: Dictionary = {}
var _marker_nodes: Dictionary = {}
## Rooms currently concealed by a primary room's show_outside=false,
## mapped to their original modulate.a, plus their fade tweens.
var _concealed_rooms: Dictionary = {}
var _conceal_tweens: Dictionary = {}
## Rooms slid out by slide_all_out (floor transitions), kept so
## slide_all_home can restore exactly those on failure — rooms that
## were already hidden by neighborhood rules are never tracked here.
var _bulk_exit_rooms: Dictionary = {}

func _init(room_world: RoomWorld) -> void:
	_room_world = room_world

## Records a room's resting screen position for slide animations.
func set_room_home(room: Room, position: Vector2) -> void:
	_room_home[room] = position

## Drops all per-room visual state (materials, home, slide) for a room
## that is being unregistered.
func forget_room(room: Room) -> void:
	_kill_room_slide(room)
	_kill_conceal_tween(room)
	_bulk_exit_rooms.erase(room)
	_concealed_rooms.erase(room)
	_room_materials.erase(room)
	_room_home.erase(room)
	_emphasis_from.erase(room)
	_emphasis_to.erase(room)
	_marker_nodes.erase(room)

## Re-applies emphasis targets instantly (no transition). Used after
## changing the neighbor_* exports at runtime.
func refresh() -> void:
	_kill_emphasis_tween()
	_update_deemphasis_material()
	for room in _room_world.registry.get_rooms():
		apply_emphasis(room)
	_update_neighbor_concealment()

## Whether a room's contents are currently revealed to the local
## player: shown per the neighborhood/show_from_outside rules, not
## faded out by the primary room's show_outside=false concealment,
## and not sliding out. Remote avatars mirror this so a player only
## appears where their room is actually visible.
func is_room_revealed(room: Room) -> bool:
	if room == null or not room.visible:
		return false
	if _concealed_rooms.has(room):
		return false
	var slide: Dictionary = _room_slide.get(room, {})
	return not bool(slide.get("exiting", false))

func apply_emphasis(room: Room) -> void:
	if room == null:
		return
	_update_room_visibility(room)
	_set_room_strength(room, _target_emphasis(room.room_coordinates))

func begin_transition() -> void:
	_kill_emphasis_tween()
	_emphasis_from.clear()
	_emphasis_to.clear()
	for room in _room_world.registry.get_rooms():
		if room == null:
			continue
		_update_room_visibility(room)
		_emphasis_from[room] = _current_emphasis(room)
		_emphasis_to[room] = _target_emphasis(room.room_coordinates)
	if _room_world.emphasis_transition_duration <= 0.0 or not is_inside_tree():
		_apply_emphasis_blend(1.0)
		_update_neighbor_concealment()
		return
	_emphasis_tween = create_tween()
	_emphasis_tween.tween_method(_apply_emphasis_blend, 0.0, 1.0, _room_world.emphasis_transition_duration).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	# Concealment follows the same transition clock: start the fades now
	# so rooms fade together with the emphasis change.
	_update_neighbor_concealment()

func _apply_emphasis_blend(t: float) -> void:
	for room in _emphasis_from:
		var from := float(_emphasis_from[room])
		var to := float(_emphasis_to.get(room, from))
		_set_room_strength(room, lerpf(from, to, t))

func _current_emphasis(room: Room) -> float:
	if room == null or room.deemphasis_material == null:
		return 0.0
	var mat := room.deemphasis_material as ShaderMaterial
	if mat == null:
		return 0.0
	var value: Variant = mat.get_shader_parameter(&"strength")
	return float(value) if value != null else 0.0

func _set_room_strength(room: Room, strength: float) -> void:
	if room == null:
		return
	if strength <= 0.001:
		if _room_materials.has(room):
			room.clear_deemphasis()
			_room_materials.erase(room)
		return
	var mat := _ensure_room_material(room)
	mat.set_shader_parameter(&"strength", strength)

func _ensure_room_material(room: Room) -> ShaderMaterial:
	var mat: ShaderMaterial = _room_materials.get(room)
	if mat == null or not is_instance_valid(mat):
		mat = ShaderMaterial.new()
		mat.shader = NEIGHBOR_DEEMPHASIS_SHADER
		_set_deemphasis_params(mat)
		_room_materials[room] = mat
		room.set_deemphasis(mat)
	return mat

func _update_deemphasis_material() -> void:
	for mat in _room_materials.values():
		if is_instance_valid(mat):
			_set_deemphasis_params(mat)

func _set_deemphasis_params(mat: ShaderMaterial) -> void:
	mat.set_shader_parameter(&"saturation", _room_world.neighbor_saturation)
	mat.set_shader_parameter(&"brightness", _room_world.neighbor_brightness)
	mat.set_shader_parameter(&"alpha", _room_world.neighbor_alpha)
	mat.set_shader_parameter(&"blur", _room_world.neighbor_blur)

func _kill_emphasis_tween() -> void:
	if _emphasis_tween != null and is_instance_valid(_emphasis_tween):
		_emphasis_tween.kill()
	_emphasis_tween = null

func _target_emphasis(room_coordinates: Vector2i) -> float:
	if not _room_world.deemphasize_neighbors or room_coordinates == _room_world.primary_room_coordinates:
		return 0.0
	return 1.0

func _update_room_visibility(room: Room) -> void:
	var is_primary := room.room_coordinates == _room_world.primary_room_coordinates
	var is_neighbor := _room_world.neighborhood.is_neighbor(room.room_coordinates)
	# show_from_outside=false keeps the room hidden until the player
	# walks in (it becomes primary); the slide animation still plays.
	var should_show := is_primary or (room.show_from_outside \
		and (is_neighbor or not _room_world.hide_rooms_outside_neighborhood))
	var slide: Dictionary = _room_slide.get(room, {})
	var exiting := bool(slide.get("exiting", false))

	if should_show:
		if exiting:
			_kill_room_slide(room)
			room.position = _room_home.get(room, room.position)
		if not room.visible:
			room.visible = true
			if _room_world.room_slide_duration > 0.0 and is_inside_tree():
				_start_room_slide(room, false)
	elif exiting:
		# A slide-out started before room_slide_duration was zeroed would
		# otherwise keep the room visible forever; cancel it immediately.
		if _room_world.room_slide_duration <= 0.0:
			_kill_room_slide(room)
			if room.visible:
				room.visible = false
	elif room.visible:
		if _room_world.room_slide_duration > 0.0 and is_inside_tree():
			_start_room_slide(room, true)
		else:
			room.visible = false

func _start_room_slide(room: Room, exiting: bool) -> void:
	_kill_room_slide(room)
	var home: Vector2 = _room_home.get(room, room.position)
	var target := home + Vector2(0.0, _room_world.room_slide_distance if exiting else -_room_world.room_slide_distance)
	if not exiting:
		room.position = target
	room.is_sliding = true
	var tween := create_tween()
	tween.set_trans(Tween.TRANS_QUAD)
	tween.set_ease(Tween.EASE_OUT if not exiting else Tween.EASE_IN)
	tween.tween_property(room, "position", home if not exiting else target, _room_world.room_slide_duration)
	tween.finished.connect(_on_room_slide_finished.bind(room))
	_room_slide[room] = {"tween": tween, "exiting": exiting}

func _on_room_slide_finished(room: Room) -> void:
	if not is_instance_valid(room):
		for key in _room_slide.keys():
			if not is_instance_valid(key):
				_room_slide.erase(key)
		return
	var slide: Dictionary = _room_slide.get(room, {})
	var exiting := bool(slide.get("exiting", false))
	_room_slide.erase(room)
	room.is_sliding = false
	room.position = _room_home.get(room, room.position)
	if exiting:
		room.visible = false

# ------------------------------------------------------------------
# Bulk floor-transition slides (TransitionOverlay, Phase P3)
# ------------------------------------------------------------------

## Slides every currently visible room down and off screen — the
## "leave through the bottom" half of a floor transition. Returns the
## number of rooms animated (0 means there was nothing to move).
func slide_all_out() -> int:
	_bulk_exit_rooms.clear()
	var count := 0
	for room in _room_world.registry.get_rooms():
		if room == null or not room.visible:
			continue
		_bulk_exit_rooms[room] = true
		_start_room_slide(room, true)
		count += 1
	return count

## Slides every currently visible room in from above — the "arrive
## from the top" half, played after the destination floor exists.
## Hidden rooms stay hidden; they appear later via normal visibility.
## Rooms mid EXIT slide are the should-be-hidden set: their exit
## tween keeps room.visible true until it finishes, so without this
## check slide_all_in would kill the exit, slide them in, and leave
## them visible forever (nothing re-evaluates visibility afterwards).
func slide_all_in() -> int:
	_bulk_exit_rooms.clear()
	var count := 0
	for room in _room_world.registry.get_rooms():
		if room == null or not room.visible:
			continue
		var slide: Dictionary = _room_slide.get(room, {})
		if bool(slide.get("exiting", false)):
			_kill_room_slide(room)
			room.position = _room_home.get(room, room.position)
			room.visible = false
			continue
		_start_room_slide(room, false)
		count += 1
	return count

## Failure recovery: snaps every room that slide_all_out moved back
## to its home position and visibility. Used when a transition is
## rejected, times out, or the switch callable fails — the old floor
## was never destroyed, so it simply reappears.
func slide_all_home() -> void:
	for room in _bulk_exit_rooms.keys():
		if not is_instance_valid(room):
			continue
		_kill_room_slide(room)
		room.position = _room_home.get(room, room.position)
		room.is_sliding = false
		room.visible = true
	_bulk_exit_rooms.clear()

# ------------------------------------------------------------------
# Connection markers
# ------------------------------------------------------------------

## Rebuilds the optional ground-marker sprites for every registered
## room's connection cells. A marker is drawn only when the connection
## (or the RoomWorld's per-type texture) provides a texture, so worlds
## without marker art are unaffected.
func refresh_connection_markers() -> void:
	for room in _room_world.registry.get_rooms():
		_rebuild_room_markers(room)

func _rebuild_room_markers(room: Room) -> void:
	if room == null:
		return
	var holder: Node2D = _marker_nodes.get(room)
	if holder == null or not is_instance_valid(holder):
		holder = Node2D.new()
		holder.name = "ConnectionMarkers"
		room.add_child(holder)
		_marker_nodes[room] = holder
	for child in holder.get_children():
		child.queue_free()
	if room.grid == null:
		return
	for connection in _room_world.connections.get_all_connections():
		var traversal := connection.traversal_for(room.room_coordinates)
		if traversal.is_empty():
			continue
		var texture := _marker_texture_for(connection)
		if texture == null:
			continue
		var exits: Array[Vector2i] = traversal["exits"]
		if exits.is_empty():
			continue
		var center := Vector2.ZERO
		var best_depth := -INF
		for cell in exits:
			center += Vector2(cell)
			var depth := _marker_depth(room, cell)
			if depth > best_depth:
				best_depth = depth
		center /= float(exits.size())
		var sprite := Sprite2D.new()
		sprite.name = "Marker_%s" % str(connection.connection_id)
		sprite.texture = texture
		sprite.centered = true
		sprite.texture_filter = CanvasItem.TEXTURE_FILTER_PARENT_NODE
		sprite.position = room.grid.grid_to_screen_position(center, 0.0)
		# Ground decal: above floor tiles, below blocks standing on the cell.
		sprite.z_index = int(best_depth) - 1
		holder.add_child(sprite)
		room.apply_deemphasis_to(sprite)

func _marker_texture_for(connection: RoomConnection) -> Texture2D:
	if connection == null:
		return null
	if connection.marker_texture != null:
		return connection.marker_texture
	match connection.connection_type:
		RoomConnection.ConnectionType.DOOR:
			return _room_world.door_marker_texture
		RoomConnection.ConnectionType.CORRIDOR:
			return _room_world.corridor_marker_texture
		RoomConnection.ConnectionType.STAIRWAY:
			return _room_world.stairway_marker_texture
		RoomConnection.ConnectionType.PORTAL:
			return _room_world.portal_marker_texture
	return null

func _marker_depth(room: Room, cell: Vector2i) -> float:
	if room.block_layer != null:
		return float(room.block_layer.depth_for_cell(cell))
	var world_cell := room.grid.depth_cell(room.world_cell_coordinates(cell))
	return float((world_cell.x + world_cell.y) * 48 + world_cell.y * 6)

func _kill_room_slide(room: Room) -> void:
	var slide: Dictionary = _room_slide.get(room, {})
	var tween: Tween = slide.get("tween")
	if tween != null and is_instance_valid(tween):
		tween.kill()
	_room_slide.erase(room)
	if is_instance_valid(room):
		room.is_sliding = false

# ------------------------------------------------------------------
# Neighbor concealment (primary room's show_outside option)
# ------------------------------------------------------------------

## When the primary room has show_outside=false, every edge-adjacent
## room fades out completely (floors, tiles, blocks, markers); they
## fade back in otherwise. Runs on every emphasis transition so
## room/primary/connection changes re-evaluate it.
func _update_neighbor_concealment() -> void:
	var primary := _room_world.get_room(_room_world.primary_room_coordinates)
	var conceal := primary != null and not primary.show_outside
	var hidden_set := {}
	if conceal:
		var primary_sections := primary.global_sections()
		for other in _room_world.registry.get_rooms():
			if other == null or other == primary:
				continue
			for other_section in other.global_sections():
				var touches := false
				for primary_section in primary_sections:
					if _rects_adjacent(primary_section, other_section):
						touches = true
						break
				if touches:
					hidden_set[other] = true
					break
	for room in _room_world.registry.get_rooms():
		if room == null:
			continue
		_apply_concealment(room, hidden_set.has(room))

## Adjacency for concealment: bounds that touch along an edge OR at a
## corner (diagonal rooms are hidden too). Rooms never overlap, so
## inclusive bounds comparison is sufficient.
static func _rects_adjacent(a: Rect2i, b: Rect2i) -> bool:
	var a_end := a.position + a.size
	var b_end := b.position + b.size
	var x_touch := b.position.x <= a_end.x and b_end.x >= a.position.x
	var y_touch := b.position.y <= a_end.y and b_end.y >= a.position.y
	return x_touch and y_touch

## Fades the whole room (room.modulate reaches every descendant layer)
## to alpha 0, or back to its recorded alpha. room.visible stays under
## neighborhood control, so concealment never fights slide/show logic.
func _apply_concealment(room: Room, hidden: bool) -> void:
	if _concealed_rooms.has(room) == hidden:
		return
	_kill_conceal_tween(room)
	var duration := _room_world.emphasis_transition_duration
	if hidden:
		if not _concealed_rooms.has(room):
			_concealed_rooms[room] = room.modulate.a
		_tween_room_alpha(room, 0.0, duration)
	else:
		var alpha: float = _concealed_rooms.get(room, 1.0)
		_concealed_rooms.erase(room)
		_tween_room_alpha(room, alpha, duration)

func _tween_room_alpha(room: Room, target: float, duration: float) -> void:
	if duration <= 0.0 or not is_inside_tree():
		room.modulate.a = target
		return
	var tween := create_tween()
	tween.tween_property(room, "modulate:a", target, duration) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	_conceal_tweens[room] = tween

func _kill_conceal_tween(room: Room) -> void:
	var tween: Tween = _conceal_tweens.get(room)
	if tween != null and is_instance_valid(tween):
		tween.kill()
	_conceal_tweens.erase(room)
