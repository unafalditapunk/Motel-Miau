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
## Root of the active character set. Idle sprites come from the
## sprite_* exports (typically <root>/rotations/<dir>.png); walk cycles
## load from <root>/animations/Walking/<dir>/frame_*.png where <dir>
## is one of south-west/south-east/north-west/north-east. Swap this to
## try another character (e.g. Assets/Characters/cat/siamese).
@export var character_root := "res://Assets/Characters/cat/orange"
@export var sprite_down_right: Texture2D
@export var sprite_up_left: Texture2D
@export var sprite_down_left: Texture2D
@export var sprite_up_right: Texture2D
@export var facing_direction := Vector2i(1, 0)
@export var move_duration := 0.24
@export var hold_repeat_delay := 0.22
@export var buffer_movement_input := true
@export var sprite_bottom_offset := 0.0
## How many frames each walk cycle uses. 0 = all available frames;
## otherwise frames are sampled evenly across the cycle (e.g. 4 of 8
## keeps the full stride at half the framerate). Experiment knob.
@export var walk_frame_count := 8

var _is_moving := false
## True while the in-flight move tween crosses a room boundary
## (spatial or interactive connection). The overview camera suspends
## room-centering while this is set so the avatar stays in view
## through the room slide.
var room_transition_active := false
var _move_elapsed := 0.0
var _move_direction := Vector2i.ZERO
## True while the in-flight step is a held-key chain link: those glide
## at constant velocity (linear) instead of smoothstep, so holding a
## direction reads as continuous motion instead of pulse-per-cell.
var _move_linear := false
## Set by _start_move for the next _play_move call; consumed there.
var _chain_pending := false
## Extra y offset (px, positive = down) applied to the visual while a
## walk animation plays. Walk frames reserve the bottom of the canvas
## for the implied cell tile, so their feet sit higher in-frame than
## the idle sprites — measured once at startup, see
## _walk_ground_offsets.
var _walk_ground_offsets: Dictionary = {}
var _visual_base_y := 0.0
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
## Floor portal trigger state: set when the player steps onto a portal
## cell and the deferred floor switch is pending. Blocks retriggering
## until the switch resolves (FloorManager.switch_floor is synchronous,
## so the flag only guards the short animation delay).
var _floor_portal_pending := false
## Delay between stepping onto a portal cell and the floor switch, so
## the step animation reads as walking through the doorway. Tests may
## shrink it to 0.
var floor_portal_delay := 0.18

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
	# A teleport must not leave the camera a frame behind: notify it
	# now so large jumps snap immediately instead of flashing the
	# player at the old camera position for one rendered frame.
	# Remote avatars never drive the camera.
	if not network_remote and is_inside_tree():
		var world := get_tree().get_first_node_in_group(&"world") as WorldBootstrap
		if world != null and world.world_camera != null:
			world.world_camera.notify_target_teleported()

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
	_chain_pending = false
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
	room_transition_active = false
	_move_elapsed = 0.0
	_move_direction = Vector2i.ZERO
	_buffered_direction = Vector2i.ZERO

## True while a modal world UI (FloorPanel), Creation Mode, or an
## external input lock (multiplayer pre-sync) is active; movement
## input is ignored so the player can't walk behind the UI, interfere
## with floor editing, or act on an unsynchronized world.
func _world_ui_blocked() -> bool:
	return local_input_locked \
		or FloorPanel.any_open(get_tree()) or FloorEditor.any_active(get_tree()) \
		or AvatarPanel.any_open(get_tree())

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
	room_transition_active = true
	var played := _play_move(from_screen, to_screen, previous_elevation, elevation)
	if not _is_moving:
		room_transition_active = false
	return played

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
	room_transition_active = true
	var played := _play_move(from_screen, to_screen, previous_elevation, elevation)
	if not _is_moving:
		room_transition_active = false
	return played

func _start_move(direction: Vector2i, chained := false) -> bool:
	_chain_pending = chained
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
	var played := _play_move(from_screen, to_screen, from_elevation, target_elevation)
	# The step onto the cell is committed — now check for a floor
	# portal. Interactive connections were already consulted above;
	# placement rules keep the two from sharing a cell.
	_trigger_floor_portal(target)
	return played

## Floor portal trigger: after a successful in-room step, asks the
## FloorManager whether the stepped-on global cell hosts a portal on
## the ACTIVE floor and, when it does, schedules the normal
## FloorManager.switch_floor after a short delay so the step
## animation plays first. Guards:
##   - only the bound room_world (the active floor's world) is
##     eligible — bodies on runtime/secondary worlds never trigger;
##   - multiplayer CLIENTS route through
##     MultiplayerManager.request_portal_transition instead of a
##     local switch_floor — the server re-validates the portal
##     against the peer's authoritative floor and body position;
##   - dedicated-server bodies are authoritative proxies driven by
##     client move RPCs — they never self-transition (their floor
##     changes only inside _handle_floor_transition);
##   - the destination must still be a registered floor, else the
##     cell behaves like ordinary floor;
##   - _floor_portal_pending prevents retriggering during the delay.
func _trigger_floor_portal(local_cell: Vector2i) -> void:
	if _floor_portal_pending or room == null:
		return
	var world := _room_world()
	if world == null:
		return
	var floor_manager := _floor_manager()
	if floor_manager == null or floor_manager.active_floor == null:
		return
	var mm := _multiplayer_manager()
	if mm != null and mm.mode == MultiplayerManager.Mode.SERVER:
		return
	var mp_client := mm != null and mm.mode == MultiplayerManager.Mode.CLIENT
	if not mp_client and floor_manager.structural_edits_readonly():
		return
	# Only the bound world hosts the active floor; runtime worlds
	# (multiplayer secondary floors) are out of scope for P1.
	if world != floor_manager.room_world:
		return
	var world_cell := room.world_cell_coordinates(local_cell)
	var portal := floor_manager.portal_at(world_cell)
	if portal == null:
		return
	var destination := portal.destination_floor_id
	if floor_manager.get_floor(destination) == null:
		# Stale portal (destination floor deleted outside the prune
		# path): preserve normal movement rather than fail loudly on
		# every step.
		return
	_floor_portal_pending = true
	var stepped_room := room
	# The delay must cover the step animation that just started, or the
	# floor switch cuts the glide tween short and place_at visibly
	# snaps the sprite the remaining fraction of a cell.
	get_tree().create_timer(maxf(floor_portal_delay, move_duration)).timeout.connect(
		_on_floor_portal_delay_elapsed.bind(world_cell, stepped_room))

## Deferred portal activation: fires after the step animation delay.
## Cancels when the player no longer stands in the room instance the
## portal was triggered from (a floor switch or room teardown already
## moved them); otherwise re-resolves the portal (it may have been
## deleted during the delay) and either performs the standard
## single-player floor transition or asks the server to perform the
## authoritative multiplayer one.
func _on_floor_portal_delay_elapsed(world_cell: Vector2i, stepped_room: Room) -> void:
	_floor_portal_pending = false
	if not is_inside_tree() or not is_instance_valid(stepped_room) \
			or room != stepped_room:
		return
	var floor_manager := _floor_manager()
	if floor_manager == null:
		return
	var portal := floor_manager.portal_at(world_cell)
	if portal == null:
		return
	var destination := portal.destination_floor_id
	if floor_manager.get_floor(destination) == null:
		return
	var mm := _multiplayer_manager()
	if mm != null and mm.mode == MultiplayerManager.Mode.CLIENT:
		# Server-authoritative path: the server re-validates the
		# portal against this peer's floor and body position and
		# derives the destination itself. A refused request just
		# leaves the player standing on the portal cell. The local
		# TransitionOverlay picks up transition_requested /
		# transition_result for the fade.
		mm.request_portal_transition(world_cell)
		return
	# Single-player: at <1x overview zoom, glide the camera onto the
	# avatar before the slide plays. Re-entry re-validates the portal
	# and room, so a player who moved on cancels cleanly.
	var camera := _world_camera()
	if camera != null and camera.defer_until_recentered(
			_on_floor_portal_delay_elapsed.bind(world_cell, stepped_room)):
		return
	# Single-player: run the switch under the transition slide when
	# the overlay exists (it also locks input while it plays); fall
	# back to a bare switch otherwise. A portal with an arrival cell
	# (e.g. another portal for chains) lands there via switch_floor_at.
	var do_switch := func() -> bool:
		if portal.has_destination_cell():
			return floor_manager.switch_floor_at(destination,
				portal.destination_world_cell)
		return floor_manager.switch_floor(destination)
	var overlay := _transition_overlay()
	if overlay != null:
		if not bool(overlay.play_transition(do_switch)):
			push_warning("Player: floor portal transition to '%s' failed; player stays put." % destination)
		return
	if not do_switch.call():
		push_warning("Player: floor portal transition to '%s' failed; player stays put." % destination)

func _multiplayer_manager() -> MultiplayerManager:
	if not is_inside_tree():
		return null
	return get_tree().get_first_node_in_group(&"multiplayer_manager") as MultiplayerManager

func _transition_overlay() -> TransitionOverlay:
	if not is_inside_tree():
		return null
	return get_tree().get_first_node_in_group(&"transition_overlay") as TransitionOverlay

func _floor_manager() -> FloorManager:
	if not is_inside_tree():
		return null
	return get_tree().get_first_node_in_group(&"floor_managers") as FloorManager

## The active WorldCamera, when one is driving this viewport.
func _world_camera() -> WorldCamera:
	if not is_inside_tree():
		return null
	return get_viewport().get_camera_2d() as WorldCamera

func _play_move(from_screen: Vector2, to_screen: Vector2, from_elevation: float, to_elevation: float) -> bool:
	_move_linear = _chain_pending
	_chain_pending = false
	if move_duration <= 0.0 or grid == null:
		position = to_screen
		_update_depth()
		_is_moving = false
		return true

	_move_direction = facing_direction
	_is_moving = true
	_move_elapsed = 0.0
	_move_from = from_screen
	_move_to = to_screen
	_move_elev_from = from_elevation
	_move_elev_to = to_elevation
	z_index = _depth_for_screen_position(_depth_sample_position(position), _move_elev_from)
	_update_facing_animation()
	return true

func _process(delta: float) -> void:
	_update_held_movement()
	if not _is_moving:
		return
	_move_elapsed += delta
	var t := clampf(_move_elapsed / move_duration, 0.0, 1.0)
	# Chained held-key steps run linear (constant cell speed); isolated
	# steps keep the smoothstep ease so taps accelerate/decelerate.
	var eased := t if _move_linear else t * t * (3.0 - 2.0 * t)
	position = _move_from.lerp(_move_to, eased)
	var visual_elevation := lerpf(_move_elev_from, _move_elev_to, eased)
	z_index = _depth_for_screen_position(_depth_sample_position(position), visual_elevation)
	if t >= 1.0:
		_finish_move()

func _finish_move() -> void:
	position = _move_to
	_update_depth()
	_is_moving = false
	room_transition_active = false
	_update_facing_animation()
	if not buffer_movement_input or _buffered_direction == Vector2i.ZERO:
		_buffered_direction = Vector2i.ZERO
		return
	var direction := _buffered_direction
	_buffered_direction = Vector2i.ZERO
	_start_move(direction, true)

func _unhandled_key_input(event: InputEvent) -> void:
	if network_remote:
		return
	if _world_ui_blocked():
		# Keep _held_moves: keys held through a transition (floor
		# portal, floor switch) must resume moving in that direction
		# once the lock releases. _update_held_movement prunes keys
		# that are no longer physically pressed once unblocked.
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

## Swaps the visible character set at runtime. new_root is a catalog
## character root ("res://Assets/Characters/<race>/<variant>"); all
## four rotation sprites must exist or the swap is refused. Walk
## cycles rebuild from <root>/animations/Walking/ — east directions
## fall back to horizontally mirrored west frames when their folders
## are absent, so a variant only needs south-west/north-west art.
func set_character(new_root: String) -> bool:
	if new_root.is_empty() or new_root == character_root:
		return new_root == character_root
	var rotations := _load_rotations(new_root)
	if rotations.size() != AvatarCatalog.ROTATION_FILES.size():
		push_warning("Player.set_character: '%s' is missing rotation sprites; swap refused." % new_root)
		return false
	character_root = new_root
	for dir_name in rotations:
		set(AvatarCatalog.ROTATION_FILES[dir_name], rotations[dir_name])
	if not is_node_ready():
		return true
	if visual != null:
		visual.sprite_frames = SpriteFrames.new()
	_ensure_sprite_frames()
	_update_visual_metrics()
	return true

func _load_rotations(root_path: String) -> Dictionary:
	var rotations := {}
	for dir_name in AvatarCatalog.ROTATION_FILES:
		var path := "%s/rotations/%s.png" % [root_path, dir_name]
		# exists() guard: load() logs an engine error per missing file.
		if not ResourceLoader.exists(path):
			continue
		var texture := load(path) as Texture2D
		if texture != null:
			rotations[dir_name] = texture
	return rotations

func _ensure_sprite_frames() -> void:
	if visual == null:
		return
	if visual.sprite_frames == null:
		visual.sprite_frames = SpriteFrames.new()
	if _has_directional_textures():
		_ensure_directional_animations(visual.sprite_frames)
		_ensure_walk_animations(visual.sprite_frames)
	elif visual.sprite_frames.get_frame_count(&"idle") == 0 and sprite_texture != null:
		if not visual.sprite_frames.has_animation(&"idle"):
			visual.sprite_frames.add_animation(&"idle")
		visual.sprite_frames.add_frame(&"idle", sprite_texture)
	_update_facing_animation()
	visual.texture_filter = CanvasItem.TEXTURE_FILTER_PARENT_NODE

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

## Grid direction → walk-cycle folder name under
## <character_root>/animations/Walking/: (0,1) = screen down-left =
## south-west, (1,0) = screen down-right = south-east, (-1,0) = screen
## up-left = north-west, (0,-1) = screen up-right = north-east. The
## east folders hold horizontally mirrored west frames.
const WALK_ANIMATION_DIRS := {
	Vector2i(0, 1): "south-west",
	Vector2i(1, 0): "south-east",
	Vector2i(-1, 0): "north-west",
	Vector2i(0, -1): "north-east",
}

func _walk_dir_path(direction: Vector2i) -> String:
	return "%s/animations/Walking/%s" % [character_root, WALK_ANIMATION_DIRS[direction]]

## East walk folders hold horizontally mirrored west frames when the
## artist only ships west art; variants may also omit them entirely,
## in which case the west cycle is flipped at load time. Real east
## files always win when present.
const MIRRORED_WALK_DIRS := {
	"south-east": "south-west",
	"north-east": "north-west",
}

func _walk_frames_for(direction: Vector2i) -> Array[Texture2D]:
	var dir_name: String = WALK_ANIMATION_DIRS[direction]
	var textures := _load_walk_frames(_walk_dir_path(direction))
	if not textures.is_empty():
		return textures
	var mirror := String(MIRRORED_WALK_DIRS.get(dir_name, ""))
	if mirror.is_empty():
		return []
	var source := _load_walk_frames("%s/animations/Walking/%s" % [character_root, mirror])
	var flipped: Array[Texture2D] = []
	for texture in source:
		flipped.append(_flip_texture_horizontal(texture))
	return flipped

## Runtime horizontal mirror for west-only walk art. Mipmaps are
## regenerated so 0.5x overview filtering still applies; real east
## PNGs on disk are preferred whenever they exist.
func _flip_texture_horizontal(texture: Texture2D) -> Texture2D:
	var image := texture.get_image()
	if image == null:
		return texture
	image.flip_x()
	image.generate_mipmaps()
	return ImageTexture.create_from_image(image)

func _ensure_walk_animations(frames: SpriteFrames) -> void:
	_walk_ground_offsets.clear()
	for direction in WALK_ANIMATION_DIRS:
		var textures := _walk_frames_for(direction)
		if textures.is_empty():
			continue
		var animation := _walk_animation_name(direction)
		if frames.has_animation(animation):
			frames.remove_animation(animation)
		frames.add_animation(animation)
		for texture in textures:
			frames.add_frame(animation, texture)
		frames.set_animation_loop(animation, true)
		# One full cycle per two cell-steps reads as a natural stride.
		frames.set_animation_speed(animation, textures.size() / maxf(move_duration * 2.0, 0.01))
		var offset := _walk_ground_offset(direction, textures)
		if offset != 0.0:
			_walk_ground_offsets[animation] = offset

func _load_walk_frames(dir_path: String) -> Array[Texture2D]:
	var all: Array[Texture2D] = []
	for i in 32:
		var path := "%s/frame_%03d.png" % [dir_path, i]
		if not ResourceLoader.exists(path):
			break
		var texture := load(path) as Texture2D
		if texture == null:
			break
		all.append(texture)
	# Experiment knob: sample evenly across the cycle so a reduced
	# count keeps the full stride instead of truncating it.
	if walk_frame_count <= 0 or all.size() <= walk_frame_count:
		return all
	var picked: Array[Texture2D] = []
	for i in walk_frame_count:
		picked.append(all[floori(float(i) * all.size() / float(walk_frame_count))])
	return picked

func _walk_animation_name(direction: Vector2i) -> StringName:
	return StringName("walk_%s" % WALK_ANIMATION_DIRS[direction].get_file())

func _walk_animation_for(direction: Vector2i) -> StringName:
	if WALK_ANIMATION_DIRS.has(direction):
		return _walk_animation_name(direction)
	return &""

## Vertical offset needed so walk frames stand on the same ground
## line as the idle sprites. The visual anchor math assumes the idle
## sprite proportions; walk frames are shorter and reserve the bottom
## of the canvas for the implied cell tile, which lifts the feet.
## Measured from pixels: align the lowest foot of the contact frames
## with the idle sprite's foot line.
func _walk_ground_offset(direction: Vector2i, textures: Array[Texture2D]) -> float:
	var idle := _idle_texture_for(direction)
	if idle == null or textures.is_empty():
		return 0.0
	var idle_margin := _sprite_bottom_margin(idle)
	var walk_margin := INF
	var walk_height := 0.0
	for texture in textures:
		walk_margin = minf(walk_margin, _sprite_bottom_margin(texture))
		walk_height = maxf(walk_height, float(texture.get_height()))
	if walk_margin == INF or idle_margin == 0.0:
		return 0.0
	return (idle.get_height() - walk_height) * 0.5 + (walk_margin - idle_margin)

## Pixels between the sprite's bottom edge and its lowest opaque
## pixel — the "air" under the feet.
func _sprite_bottom_margin(texture: Texture2D) -> float:
	var image := texture.get_image()
	if image == null:
		return 0.0
	var height := image.get_height()
	var width := image.get_width()
	for y in range(height - 1, -1, -1):
		for x in range(width):
			if image.get_pixel(x, y).a > 0.05:
				return float(height - y)
	return 0.0

func _idle_texture_for(direction: Vector2i) -> Texture2D:
	match direction:
		Vector2i(1, 0):
			return sprite_down_right
		Vector2i(-1, 0):
			return sprite_up_left
		Vector2i(0, 1):
			return sprite_down_left
		Vector2i(0, -1):
			return sprite_up_right
	return null

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
	if _is_moving:
		var walk := _walk_animation_for(_move_direction)
		if visual.sprite_frames.has_animation(walk):
			animation = walk
	if not visual.sprite_frames.has_animation(animation):
		animation = &"idle"
	if not visual.sprite_frames.has_animation(animation):
		return
	# Re-playing the same animation every step would restart the cycle
	# each cell — only switch when the target actually changed.
	if visual.animation != animation or not visual.is_playing():
		visual.animation = animation
		visual.play(animation)
	visual.position.y = _visual_base_y + _animation_y_offset(animation)

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
	_visual_base_y = -base_height * 0.5 + _visual_ground_offset()
	visual.position = Vector2(0.0, _visual_base_y + _animation_y_offset(visual.animation))

func _animation_y_offset(animation: StringName) -> float:
	return float(_walk_ground_offsets.get(animation, 0.0))

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

## Depth is sampled at the feet (bottom of the cell diamond), not the
## cell anchor: while walking south the sprite's feet overlap the next
## cell's tall tiles before the anchor crosses the boundary, and those
## tiles' surface depth would cover them. The -2px keeps the sample
## inside the diamond — the exact bottom vertex ties to the diagonal
## front cell in screen_to_grid.
func _depth_sample_position(screen_position: Vector2) -> Vector2:
	return screen_position + Vector2(0.0, _tile_size().y * 0.5 - 2.0)

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
