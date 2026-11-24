class_name Player
extends CharacterBody2D

@export var grid: IsometricGrid
@export var block_layer: BlockLayer
@export var room: Room
## The RoomWorld this player belongs to. Multiplayer servers host one
## RoomWorld per occupied floor, so the "room_worlds" group lookup is
## ambiguous — every bind site (spawn, floor transition, snapshot
## apply, avatar spawn) must set this explicitly. Null falls back to
## the group lookup for tests and legacy single-world setups.
var room_world: RoomWorld
@export var room_size := Vector2i(10, 10)
@export var grid_position := Vector2i.ZERO
@export var elevation := 0.0
@export var height_units := 2.0
@export var max_step_height := 1.0
@export var sprite_texture: Texture2D
@export var sprite_down_right: Texture2D
@export var sprite_up_left: Texture2D
@export var sprite_down_left: Texture2D
@export var sprite_up_right: Texture2D
@export var facing_direction := Vector2i(1, 0)
@export var move_duration := 0.24
@export var hold_repeat_delay := 0.22
@export var buffer_movement_input := true
@export var sprite_bottom_offset := 0.0

var _is_moving := false
var _move_elapsed := 0.0
var _move_from := Vector2.ZERO
var _move_to := Vector2.ZERO
var _move_elev_from := 0.0
var _move_elev_to := 0.0
var _buffered_direction := Vector2i.ZERO
var _held_moves: Dictionary = {}

## True for network-driven avatars: remote-player replicas on clients
## and the server's authoritative bodies. They never join the "player"
## group (camera follow, placement ghost and blueprint hiding must keep
## finding only the local avatar) and ignore local movement input.
## Set BEFORE add_child — _ready reads it.
var network_remote := false
## When true, local movement input is ignored entirely (no prediction,
## no move_requested). MultiplayerManager sets this on clients until
## the authoritative world snapshot has been applied, so a client can
## never walk a world that does not match the server's.
var local_input_locked := false

## Emitted whenever the authoritative grid state (room/cell/elevation)
## settles after an accepted move. The dedicated server uses it to
## broadcast position updates; local single-player play ignores it.
signal authoritative_state_changed
## Emitted once per EXECUTED move step (including buffered steps and
## room transitions) — never for rejected or merely-buffered intents.
## MultiplayerManager forwards these to the server as validation
## requests, so the request stream matches the predicted step stream.
signal move_requested(direction: Vector2i)

@onready var visual: AnimatedSprite2D = $Visual
@onready var collision_shape: CollisionShape2D = $CollisionShape2D

func _ready() -> void:
	if block_layer == null and get_parent() is BlockLayer:
		block_layer = get_parent() as BlockLayer
	if grid == null:
		push_error("Player requires an IsometricGrid resource.")
	if not network_remote:
		add_to_group(&"player")
	else:
		add_to_group(&"net_avatar")
	_ensure_sprite_frames()
	_configure_collision()
	_update_visual_metrics()
	_update_visual_position()
	snap_to_surface()

func setup(grid_resource: IsometricGrid, block_layer_resource: BlockLayer, new_grid_position: Vector2i, new_elevation: float) -> void:
	grid = grid_resource
	block_layer = block_layer_resource
	grid_position = new_grid_position
	elevation = new_elevation
	_cancel_movement()
	if is_node_ready():
		_ensure_sprite_frames()
		_configure_collision()
		_update_visual_metrics()
		_update_visual_position()

func place_at(new_grid_position: Vector2i, new_elevation: float) -> void:
	grid_position = new_grid_position
	elevation = new_elevation
	_cancel_movement()
	_update_visual_position()
	authoritative_state_changed.emit()

## Remote-avatar update: retarget room/cell/elevation to a state the
## server already validated and replay the same eased step locally.
## No validation happens here — trust the authority, not the packet.
func network_apply_state(target_room: Room, target_cell: Vector2i,
		target_elevation: float, face: Vector2i) -> void:
	if target_room == null:
		return
	room = target_room
	block_layer = target_room.block_layer
	room_size = target_room.size
	if _is_cardinal_direction(face):
		_set_facing(face)
	var from_screen := position
	var from_elevation := elevation
	grid_position = target_cell
	elevation = target_elevation
	var to_screen := _screen_position_for_cell(target_cell, target_elevation)
	_play_move(from_screen, to_screen, from_elevation, target_elevation)

func snap_to_surface() -> void:
	if block_layer != null:
		elevation = stand_elevation_at(grid_position)
	_cancel_movement()
	_update_visual_position()

func occupied_cells() -> Array[Vector2i]:
	return [grid_position]

func next_move_target() -> Vector2i:
	if _buffered_direction != Vector2i.ZERO:
		return grid_position + _buffered_direction
	return grid_position

func stand_elevation_at(cell: Vector2i) -> float:
	if block_layer == null:
		return 0.0
	return block_layer.get_surface_elevation(cell)

func movement_elevation_for(cell: Vector2i) -> float:
	return stand_elevation_at(cell)

func can_stand_at(cell: Vector2i) -> bool:
	if not _inside_room_bounds(cell):
		return false
	if block_layer == null:
		return true
	var surface := stand_elevation_at(cell)
	return block_layer.can_actor_stand(cell, surface, height_units) and block_layer.is_standable_surface(cell, surface)

func can_move_to(cell: Vector2i) -> bool:
	if not _inside_room_bounds(cell):
		return false
	var target_elevation := movement_elevation_for(cell)
	if absf(target_elevation - elevation) > max_step_height + 0.001:
		return false
	if block_layer == null:
		return true
	return block_layer.can_actor_stand(cell, target_elevation, height_units) and block_layer.is_standable_surface(cell, target_elevation)

func move_to(cell: Vector2i) -> bool:
	if not can_move_to(cell):
		return false
	_cancel_movement()
	var direction := cell - grid_position
	if _is_cardinal_direction(direction):
		_set_facing(direction)
	grid_position = cell
	elevation = movement_elevation_for(cell)
	_update_visual_position()
	authoritative_state_changed.emit()
	return true

func _cancel_movement() -> void:
	_is_moving = false
	_move_elapsed = 0.0
	_buffered_direction = Vector2i.ZERO

## True while a modal world UI (FloorPanel), Creation Mode, or an
## external input lock (multiplayer pre-sync) is active; movement
## input is ignored so the player can't walk behind the UI, interfere
## with floor editing, or act on an unsynchronized world.
func _world_ui_blocked() -> bool:
	return local_input_locked \
		or FloorPanel.any_open(get_tree()) or FloorEditor.any_active(get_tree())

func request_move(direction: Vector2i) -> void:
	if direction == Vector2i.ZERO or _world_ui_blocked():
		return
	if _is_moving:
		if buffer_movement_input:
			_buffered_direction = direction
		return
	_buffered_direction = Vector2i.ZERO
	_start_move(direction)

## Cell-exact membership: shaped rooms only contain their footprint
## cells, so bounding-box holes count as outside the room (the player
## must transition into whatever actually occupies that world cell).
func _inside_room_bounds(cell: Vector2i) -> bool:
	if room != null:
		return room.has_footprint_cell(cell)
	return cell.x >= 0 and cell.y >= 0 and cell.x < room_size.x and cell.y < room_size.y

func _room_world() -> RoomWorld:
	if room_world != null and is_instance_valid(room_world):
		return room_world
	return get_tree().get_first_node_in_group(&"room_worlds") as RoomWorld

func _room_world_cell(local_cell: Vector2i) -> Vector2i:
	if room != null:
		return room.world_cell_coordinates(local_cell)
	return local_cell

func evaluate_transition(direction: Vector2i) -> Dictionary:
	var result := {
		"attempted": false,
		"valid": false,
		"reason": &"not a cardinal step",
		"room_coordinates": Vector2i.ZERO,
		"local_cell": Vector2i.ZERO,
		"surface_elevation": 0.0,
	}
	if direction == Vector2i.ZERO or room == null or room.grid == null:
		result["reason"] = &"no room context"
		return result
	if not _is_cardinal_direction(direction):
		return result
	# Room connections only matter when the step leaves the room; probing
	# an in-bounds step must not consult the exit graph (covered corner
	# cells would otherwise look like ambiguous exits).
	if _inside_room_bounds(grid_position + direction):
		result["reason"] = &"inside room"
		return result
	result["attempted"] = true
	var world := _room_world()
	if world == null:
		result["reason"] = &"no room world"
		return result
	# An explicit room connection covering this exit cell takes precedence
	# over geometric adjacency; its paired entry defines the destination.
	var dest_room: Room = null
	var dest_local := Vector2i.ZERO
	var exit := world.find_room_exit(room, grid_position, direction)
	if not exit.is_empty():
		dest_room = world.get_room(exit["room_id"]) as Room
		dest_local = exit["cell"]
		if dest_room == null:
			result["reason"] = &"connection destination missing"
			return result
	else:
		if world.require_explicit_connections:
			result["reason"] = &"no connection"
			return result
		var world_cell := _room_world_cell(grid_position) + direction
		dest_room = world.get_room_at_world_cell(world_cell) as Room
		if dest_room == null or dest_room == room:
			result["reason"] = &"no room beyond boundary"
			return result
		dest_local = world_cell - dest_room.cell_origin
		if not dest_room.has_footprint_cell(dest_local):
			result["reason"] = &"outside destination room"
			return result
	world.ensure_room_loaded(dest_room)
	var surface := 0.0
	var dest_layer := dest_room.block_layer
	if dest_layer != null:
		surface = dest_layer.get_surface_elevation(dest_local)
	result["surface_elevation"] = surface
	result["room_coordinates"] = dest_room.room_coordinates
	result["local_cell"] = dest_local
	if absf(surface - elevation) > max_step_height + 0.001:
		result["reason"] = &"step too high"
		return result
	if dest_layer != null and not (dest_layer.can_actor_stand(dest_local, surface, height_units) and dest_layer.is_standable_surface(dest_local, surface)):
		result["reason"] = &"destination blocked"
		return result
	result["valid"] = true
	return result

func _start_room_transition(direction: Vector2i) -> bool:
	var info := evaluate_transition(direction)
	if not bool(info.get("valid", false)):
		return false
	var world := _room_world()
	var dest_room := world.get_room(info["room_coordinates"]) as Room
	if dest_room == null:
		return false
	_set_facing(direction)
	move_requested.emit(direction)
	var previous_room := room
	var from_screen := position
	var previous_elevation := elevation
	room = dest_room
	block_layer = dest_room.block_layer
	room_size = dest_room.size
	grid_position = info["local_cell"]
	elevation = float(info["surface_elevation"])
	world.set_primary_room(dest_room.room_coordinates)
	world.save_room_state(previous_room)
	var to_screen := _screen_position_for_cell(grid_position, elevation)
	authoritative_state_changed.emit()
	return _play_move(from_screen, to_screen, previous_elevation, elevation)

## Attempts an interactive (non-spatial) connection transition. entry is
## the Dictionary returned by RoomWorld.find_interactive_entry. Returns
## false — leaving the player in place — when the destination is missing,
## out of bounds, or blocked.
func _try_connection_transition(entry: Dictionary, from_screen: Vector2, from_elevation: float) -> bool:
	var world := _room_world()
	if world == null or room == null:
		return false
	var dest_room := world.get_room(entry["room_id"]) as Room
	if dest_room == null:
		return false
	var dest_local: Vector2i = entry["cell"]
	if not dest_room.has_footprint_cell(dest_local):
		return false
	world.ensure_room_loaded(dest_room)
	var surface := 0.0
	var dest_layer := dest_room.block_layer
	if dest_layer != null:
		surface = dest_layer.get_surface_elevation(dest_local)
	if absf(surface - elevation) > max_step_height + 0.001:
		return false
	if dest_layer != null and not (dest_layer.can_actor_stand(dest_local, surface, height_units) and dest_layer.is_standable_surface(dest_local, surface)):
		return false
	var previous_room := room
	var previous_elevation := from_elevation
	room = dest_room
	block_layer = dest_room.block_layer
	room_size = dest_room.size
	grid_position = dest_local
	elevation = surface
	world.set_primary_room(dest_room.room_coordinates)
	world.save_room_state(previous_room)
	var to_screen := _screen_position_for_cell(grid_position, elevation)
	authoritative_state_changed.emit()
	return _play_move(from_screen, to_screen, previous_elevation, elevation)

func _start_move(direction: Vector2i) -> bool:
	if _world_ui_blocked():
		return false
	var target := grid_position + direction
	if not _inside_room_bounds(target):
		return _start_room_transition(direction)
	if not can_move_to(target):
		return false
	_set_facing(direction)
	# The move intent is only reported once it actually starts —
	# request_move() buffers during a step, and _finish_move re-enters
	# here, so this emits exactly once per executed step.
	move_requested.emit(direction)

	var from_screen := position
	var from_elevation := elevation
	var target_elevation := movement_elevation_for(target)
	grid_position = target
	elevation = target_elevation
	# Interactive room connections trigger on entering their source cell.
	# If the transition fails validation the player simply stays on the cell.
	var world := _room_world()
	if world != null and room != null:
		var entry := world.find_interactive_entry(room.room_coordinates, target)
		if not entry.is_empty() and _try_connection_transition(entry, from_screen, from_elevation):
			return true
	var to_screen := _screen_position_for_cell(target, target_elevation)
	authoritative_state_changed.emit()
	return _play_move(from_screen, to_screen, from_elevation, target_elevation)

func _play_move(from_screen: Vector2, to_screen: Vector2, from_elevation: float, to_elevation: float) -> bool:
	if move_duration <= 0.0 or grid == null:
		position = to_screen
		_update_depth()
		_is_moving = false
		return true

	_is_moving = true
	_move_elapsed = 0.0
	_move_from = from_screen
	_move_to = to_screen
	_move_elev_from = from_elevation
	_move_elev_to = to_elevation
	z_index = _depth_for_screen_position(position, _move_elev_from)
	return true

func _process(delta: float) -> void:
	_update_held_movement()
	if not _is_moving:
		return
	_move_elapsed += delta
	var t := clampf(_move_elapsed / move_duration, 0.0, 1.0)
	var eased := t * t * (3.0 - 2.0 * t)
	position = _move_from.lerp(_move_to, eased)
	var visual_elevation := lerpf(_move_elev_from, _move_elev_to, eased)
	z_index = _depth_for_screen_position(position, visual_elevation)
	if t >= 1.0:
		_finish_move()

func _finish_move() -> void:
	position = _move_to
	_update_depth()
	_is_moving = false
	if not buffer_movement_input or _buffered_direction == Vector2i.ZERO:
		_buffered_direction = Vector2i.ZERO
		return
	var direction := _buffered_direction
	_buffered_direction = Vector2i.ZERO
	_start_move(direction)

func _unhandled_key_input(event: InputEvent) -> void:
	if network_remote:
		return
	if _world_ui_blocked():
		_held_moves.clear()
		_buffered_direction = Vector2i.ZERO
		return
	if not (event is InputEventKey):
		return
	var key_event := event as InputEventKey
	var direction := _direction_from_key(key_event.physical_keycode)
	if direction == Vector2i.ZERO:
		return
	if key_event.pressed:
		if key_event.echo:
			return
		request_move(direction)
		_held_moves.erase(key_event.physical_keycode)
		_held_moves[key_event.physical_keycode] = Time.get_ticks_msec()
	else:
		_held_moves.erase(key_event.physical_keycode)

func _update_held_movement() -> void:
	if network_remote or _held_moves.is_empty() or _world_ui_blocked():
		return
	var now := Time.get_ticks_msec()
	var direction := Vector2i.ZERO
	for keycode in _held_moves.keys():
		if not Input.is_physical_key_pressed(keycode):
			_held_moves.erase(keycode)
		elif now - int(_held_moves[keycode]) >= int(hold_repeat_delay * 1000.0):
			direction = _direction_from_key(keycode)
	if direction == Vector2i.ZERO:
		return
	request_move(direction)

func _direction_from_key(keycode: Key) -> Vector2i:
	match keycode:
		KEY_W, KEY_UP:
			return Vector2i(0, -1)
		KEY_S, KEY_DOWN:
			return Vector2i(0, 1)
		KEY_D, KEY_RIGHT:
			return Vector2i(1, 0)
		KEY_A, KEY_LEFT:
			return Vector2i(-1, 0)
	return Vector2i.ZERO

func _ensure_sprite_frames() -> void:
	if visual == null:
		return
	if visual.sprite_frames == null:
		visual.sprite_frames = SpriteFrames.new()
	if _has_directional_textures():
		_ensure_directional_animations(visual.sprite_frames)
	elif visual.sprite_frames.get_frame_count(&"idle") == 0 and sprite_texture != null:
		if not visual.sprite_frames.has_animation(&"idle"):
			visual.sprite_frames.add_animation(&"idle")
		visual.sprite_frames.add_frame(&"idle", sprite_texture)
	_update_facing_animation()
	visual.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST

func _has_directional_textures() -> bool:
	return sprite_down_right != null and sprite_up_left != null and sprite_down_left != null and sprite_up_right != null

func _ensure_directional_animations(frames: SpriteFrames) -> void:
	var animations := {
		&"idle_down_right": sprite_down_right,
		&"idle_up_left": sprite_up_left,
		&"idle_down_left": sprite_down_left,
		&"idle_up_right": sprite_up_right,
	}
	for animation in animations:
		if not frames.has_animation(animation):
			frames.add_animation(animation)
		if frames.get_frame_count(animation) == 0:
			frames.add_frame(animation, animations[animation])
		frames.set_animation_speed(animation, 1.0)
		frames.set_animation_loop(animation, true)

func _is_cardinal_direction(direction: Vector2i) -> bool:
	return direction == Vector2i(1, 0) or direction == Vector2i(-1, 0) or direction == Vector2i(0, 1) or direction == Vector2i(0, -1)

func _set_facing(direction: Vector2i) -> void:
	if not _is_cardinal_direction(direction):
		return
	facing_direction = direction
	_update_facing_animation()

func _animation_for_direction(direction: Vector2i) -> StringName:
	match direction:
		Vector2i(1, 0):
			return &"idle_down_right"
		Vector2i(-1, 0):
			return &"idle_up_left"
		Vector2i(0, 1):
			return &"idle_down_left"
		Vector2i(0, -1):
			return &"idle_up_right"
	return &"idle_down_right"

func _update_facing_animation() -> void:
	if visual == null or visual.sprite_frames == null:
		return
	var animation := _animation_for_direction(facing_direction)
	if not visual.sprite_frames.has_animation(animation):
		animation = &"idle"
	if not visual.sprite_frames.has_animation(animation):
		return
	visual.animation = animation
	visual.play(animation)

func _configure_collision() -> void:
	if collision_shape == null:
		return
	if collision_shape.shape == null or not (collision_shape.shape is ConvexPolygonShape2D):
		collision_shape.shape = ConvexPolygonShape2D.new()
	var tile_size := _tile_size()
	var half_width := tile_size.x * 0.5
	var half_height := tile_size.y * 0.5
	(collision_shape.shape as ConvexPolygonShape2D).points = PackedVector2Array([
		Vector2(0.0, -half_height),
		Vector2(half_width, 0.0),
		Vector2(0.0, half_height),
		Vector2(-half_width, 0.0),
	])

func _update_visual_metrics() -> void:
	if visual == null:
		return
	var base_height := _base_sprite_height()
	visual.scale = Vector2.ONE
	visual.position = Vector2(0.0, -base_height * 0.5 + _visual_ground_offset())

func _base_sprite_height() -> float:
	if visual == null or visual.sprite_frames == null:
		return 0.0
	var animation := _animation_for_direction(facing_direction)
	if not visual.sprite_frames.has_animation(animation):
		animation = &"idle"
	if not visual.sprite_frames.has_animation(animation):
		return 0.0
	var texture := visual.sprite_frames.get_frame_texture(animation, 0)
	if texture == null:
		return 0.0
	return texture.get_height()

func _screen_position_for_cell(cell: Vector2i, cell_elevation: float) -> Vector2:
	if grid == null:
		return position
	var world_cell := _room_world_cell(cell)
	return grid.grid_to_screen_position(Vector2(world_cell.x, world_cell.y), cell_elevation)

func _visual_ground_offset() -> float:
	return _tile_size().y * 0.5 + sprite_bottom_offset

func _update_visual_position() -> void:
	if grid == null:
		return
	position = _screen_position_for_cell(grid_position, elevation)
	_update_depth()

func _depth_for_screen_position(screen_position: Vector2, cell_elevation: float) -> int:
	if grid == null:
		return z_index
	var anchored := screen_position + Vector2(0.0, cell_elevation * grid.height_pixels_per_unit)
	var world_cell := grid.screen_to_grid(anchored)
	if block_layer != null:
		return block_layer.depth_for_cell(world_cell - block_layer.cell_origin, cell_elevation) + 1
	world_cell = grid.depth_cell(world_cell)
	return (world_cell.x + world_cell.y) * 128 + world_cell.y * 16 + int(round(cell_elevation)) + 1

func _current_depth() -> int:
	# +1 keeps the player above tiles/carpets sharing the same cell and
	# elevation; blocks in front still win by a full cell of depth.
	if block_layer != null:
		return block_layer.depth_for_cell(grid_position, elevation) + 1
	var depth_cell := grid.depth_cell(_room_world_cell(grid_position)) if room != null else grid.depth_cell(grid_position)
	return (depth_cell.x + depth_cell.y) * 128 + depth_cell.y * 16 + int(round(elevation)) + 1

func _update_depth() -> void:
	# Clamp: during floor switches the depth center can recenter while
	# block_layer still points at a room being torn down, producing
	# out-of-range values.
	z_index = clampi(_current_depth(), -4096, 4096)

func _tile_size() -> Vector2:
	if grid != null:
		return Vector2(grid.tile_width, grid.tile_height)
	return Vector2(IsoMath.TILE_WIDTH, IsoMath.TILE_HEIGHT)
