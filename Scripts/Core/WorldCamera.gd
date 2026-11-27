class_name WorldCamera
extends Camera2D

@export_group("Follow")
@export var follow_target: Node2D
@export var follow_smoothing := 6.0
## World-space distance the follow target may jump in a single frame
## before the camera snaps instead of lerping. Normal movement covers
## at most one cell step (~36px for the 64x32 iso grid); room/floor
## teleports jump far more, and the camera should already be on the
## player when they land rather than gliding across the map.
@export var follow_snap_distance := 64.0
## Smoothing rate for the pre-teleport recenter glide (deferred floor
## switches at <1x zoom). Deliberately faster than follow_smoothing —
## the glide is a transition beat, not ambient following.
@export var recenter_smoothing := 14.0
@export var focus_offset := Vector2.ZERO
@export var clamp_to_center_bounds := false
@export var center_bounds := Rect2()

@export_group("Zoom")
@export var zoom_levels: PackedFloat32Array = PackedFloat32Array([1.0, 2.0, 3.0])
@export var current_zoom_index := 0

@export_group("Editor")
## Pan speed in screen pixels per second while editor mode is active.
@export var editor_pan_speed := 900.0

var _editor_active := false
var _pan_dragging := false
var _pan_drag_last := Vector2.ZERO
var _last_follow_pos := Vector2.ZERO
var _follow_pos_valid := false
var _overview_zoom := false
var _overview_was_active := false
## Deferred action run once the camera has glided onto the follow
## target while leaving room overview (see defer_until_recentered).
var _recenter_action := Callable()
## Recenter phase guard: 0 = glide onto the target, then the action
## fires. _recenter_firing guards re-entrant defer calls from the
## action itself.
var _recenter_phase := 0
var _recenter_firing := false

## Padding (world px) added around a room's cell bounds when deciding
## whether it fits the viewport in overview mode. Extra headroom on
## top covers walls/furniture/tile art that rises above the diamonds.
const OVERVIEW_PADDING := 16.0
const OVERVIEW_TOP_PADDING := 48.0

func _ready() -> void:
	anchor_mode = Camera2D.ANCHOR_MODE_DRAG_CENTER
	ignore_rotation = true
	position_smoothing_enabled = false
	offset = Vector2.ZERO
	enabled = true
	make_current()
	_apply_zoom_level()

func _process(delta: float) -> void:
	if _editor_active:
		_editor_pan_step(delta)
		return
	var target := _get_follow_target()
	if target == null:
		return
	if _recenter_action.is_valid():
		# Recenter-then-act: overview is suspended while the camera
		# glides onto the follow target at the current zoom; on
		# arrival the deferred action (a floor teleport) fires, so
		# the cut never happens from a detached room-center view.
		var recenter_desired := _desired_position(target)
		if _recenter_phase == 0:
			var rk := 1.0 - exp(-recenter_smoothing * delta)
			global_position = global_position.lerp(recenter_desired, rk)
			_follow_pos_valid = true
			_last_follow_pos = target.global_position
			if global_position.distance_to(recenter_desired) <= 2.0:
				global_position = recenter_desired
				var action := _recenter_action
				_recenter_action = Callable()
				_recenter_phase = 0
				_recenter_firing = true
				action.call()
				_recenter_firing = false
			return
	var was_overview := _overview_was_active
	var overview: Variant = _overview_room_center(target)
	_overview_was_active = overview != null
	if overview != null:
		# Room overview: glide to the room's center with the same
		# smoothing as player follow. The target is constant while the
		# player stays in the room, so the view holds still; entering
		# a different room glides to the new center.
		var k := 1.0 - exp(-follow_smoothing * delta)
		global_position = global_position.lerp(overview, k)
		if global_position.distance_to(overview) <= 0.25:
			global_position = overview
		_follow_pos_valid = true
		_last_follow_pos = target.global_position
		return
	var desired := _desired_position(target)
	# A teleport (floor portal, floor switch, room connection, spawn)
	# moves the target farther than any single movement step — snap
	# the camera instead of letting it glide across the world. Leaving
	# room overview also snaps: the locked view would otherwise glide
	# all the way back to the player.
	# Room-boundary moves suspend overview above; there the avatar
	# tweens gradually, so leaving overview must glide after it
	# instead of snapping like a teleport does.
	var transition_follow := target is Player \
		and (target as Player).room_transition_active
	var teleported := not _follow_pos_valid \
		or target.global_position.distance_to(_last_follow_pos) > follow_snap_distance \
		or (was_overview and not transition_follow)
	_follow_pos_valid = true
	_last_follow_pos = target.global_position
	if teleported or follow_smoothing <= 0.0:
		global_position = desired
		return
	var t := 1.0 - exp(-follow_smoothing * delta)
	global_position = global_position.lerp(desired, t)
	if global_position.distance_to(desired) <= 0.25:
		global_position = desired

func _desired_position(target: Node2D) -> Vector2:
	var desired := target.global_position + focus_offset
	if clamp_to_center_bounds and center_bounds.has_area():
		desired.x = clampf(desired.x, center_bounds.position.x, center_bounds.end.x)
		desired.y = clampf(desired.y, center_bounds.position.y, center_bounds.end.y)
	return desired

## Room-overview camera target: while zoomed below 1x, returns the
## canvas position that frames the player's current room — or null
## when overview does not apply (zoomed in, no room, or the room is
## too big to fit the viewport, in which case normal follow resumes).
## Computed from logical grid coordinates, not node positions, so
## room slide animations never drag the locked camera.
func _overview_room_center(target: Node2D) -> Variant:
	if not _overview_zoom:
		return null
	# While a floor-transition slide is running, stay glued to the
	# avatar — the room overview re-centers the moment the animation
	# ends instead of drifting in during the slide.
	if TransitionOverlay.any_active(get_tree()):
		return null
	# During a room-boundary move the avatar tweens into the next
	# room — suspend the room-center lock so the camera follows the
	# avatar through the slide, then re-centers when it ends.
	if target is Player and (target as Player).room_transition_active:
		return null
	var room: Room = null
	var room_world: RoomWorld = null
	if target is Player:
		room = (target as Player).room
		room_world = (target as Player).room_world
	if room_world == null or not is_instance_valid(room_world):
		room_world = get_tree().get_first_node_in_group(&"room_worlds") as RoomWorld
	if room_world == null:
		return null
	if room == null or not is_instance_valid(room):
		room = room_world.get_room(room_world.primary_room_coordinates)
	if room == null or room_world.grid == null:
		return null
	var bounds := _room_overview_bounds(room_world, room)
	var view := get_viewport().get_visible_rect().size / maxf(zoom.x, 0.001)
	if bounds.size.x > view.x or bounds.size.y > view.y:
		return null
	return room_world.to_global(bounds.get_center())

## Screen-space bounds of a room's cell footprint, in RoomWorld local
## coordinates, padded for the tall art that rises above the tiles.
func _room_overview_bounds(room_world: RoomWorld, room: Room) -> Rect2:
	var grid := room_world.grid
	var origin := Vector2(room.cell_origin)
	var size := Vector2(room.size)
	var min_p := Vector2(INF, INF)
	var max_p := Vector2(-INF, -INF)
	for corner in [Vector2.ZERO, Vector2(size.x, 0.0), Vector2(0.0, size.y), size]:
		var p := grid.grid_to_screen_position(origin + corner)
		min_p = min_p.min(p)
		max_p = max_p.max(p)
	var rect := Rect2(min_p, max_p - min_p)
	rect = rect.grow(OVERVIEW_PADDING)
	rect.position.y -= OVERVIEW_TOP_PADDING
	rect.size.y += OVERVIEW_TOP_PADDING
	return rect

## Called by the follow target right after it teleports (place_at).
## Applies the same discontinuity rule as _process immediately, so a
## large jump snaps this frame instead of leaving one rendered frame
## with the camera still at the old position. Small jumps keep the
## normal smoothing.
func notify_target_teleported() -> void:
	var target := _get_follow_target()
	if target == null:
		return
	var teleported := not _follow_pos_valid \
		or target.global_position.distance_to(_last_follow_pos) > follow_snap_distance
	_follow_pos_valid = true
	_last_follow_pos = target.global_position
	if teleported and not _overview_zoom:
		global_position = _desired_position(target)

## Defers `action` until the camera has glided from room overview onto
## the follow target. Returns true when the action was queued (caller
## must not proceed — it runs via the callable); false when overview
## zoom is not active and the caller should proceed immediately.
## A newer call replaces a pending one so the latest input wins.
func defer_until_recentered(action: Callable) -> bool:
	# _recenter_firing: the deferred action re-enters the transition
	# path, which asks to defer again — it must proceed immediately
	# or the sequence would re-queue itself forever.
	if _recenter_firing or not _overview_zoom or is_editor_active() \
			or not action.is_valid():
		return false
	# Keep the current phase: repeated defers must not restart the
	# glide or the sequence never completes.
	_recenter_action = action
	return true

## True while a recenter-then-act sequence is in flight.
func is_recenter_pending() -> bool:
	return _recenter_action.is_valid()

func _get_follow_target() -> Node2D:
	if follow_target != null and is_instance_valid(follow_target):
		return follow_target
	return get_tree().get_first_node_in_group(&"player") as Node2D

func set_zoom_level(index: int) -> void:
	if zoom_levels.is_empty():
		return
	current_zoom_index = posmod(index, zoom_levels.size())
	_apply_zoom_level()

func zoom_in() -> void:
	set_zoom_level(current_zoom_index + 1)

func zoom_out() -> void:
	set_zoom_level(current_zoom_index - 1)

func _apply_zoom_level() -> void:
	if zoom_levels.is_empty():
		zoom = Vector2.ONE
		return
	var level := zoom_levels[current_zoom_index]
	zoom = Vector2(level, level)
	_overview_zoom = level < 1.0
	# Minified rendering (zoom < 1, e.g. the 0.5 overview) aliases
	# badly under plain NEAREST — two texels share one screen pixel
	# and edges crawl. NEAREST_WITH_MIPMAPS picks the mip level that
	# matches the minification (at 0.5x that's the half-res mip,
	# sampled 1:1 → crisp texels, no shimmer). Inheriting sprites get
	# it automatically; sprites with their own filter are unaffected.
	var viewport := get_viewport()
	if viewport != null:
		viewport.canvas_item_default_texture_filter = \
			Viewport.DEFAULT_CANVAS_ITEM_TEXTURE_FILTER_NEAREST_WITH_MIPMAPS \
			if level < 1.0 \
			else Viewport.DEFAULT_CANVAS_ITEM_TEXTURE_FILTER_NEAREST

func _unhandled_input(event: InputEvent) -> void:
	if _editor_active and event is InputEventMouseButton:
		var drag_button := event as InputEventMouseButton
		if drag_button.button_index == MOUSE_BUTTON_MIDDLE:
			_pan_dragging = drag_button.pressed
			_pan_drag_last = drag_button.position
			get_viewport().set_input_as_handled()
			return
	if _editor_active and _pan_dragging and event is InputEventMouseMotion:
		var motion := event as InputEventMouseMotion
		# Screen-space drag pans the camera in world space.
		global_position -= motion.relative / maxf(zoom.x, 0.001)
		_pan_drag_last = motion.position
		get_viewport().set_input_as_handled()
		return
	if event is InputEventMouseButton:
		var mouse_button := event as InputEventMouseButton
		if not mouse_button.pressed:
			return
		if mouse_button.button_index == MOUSE_BUTTON_WHEEL_UP:
			zoom_in()
			get_viewport().set_input_as_handled()
		elif mouse_button.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			zoom_out()
			get_viewport().set_input_as_handled()
	elif event is InputEventKey:
		var key_event := event as InputEventKey
		if not key_event.pressed or key_event.echo:
			return
		match key_event.physical_keycode:
			KEY_EQUAL, KEY_KP_ADD:
				zoom_in()
				get_viewport().set_input_as_handled()
			KEY_MINUS, KEY_KP_SUBTRACT:
				zoom_out()
				get_viewport().set_input_as_handled()

func view_center_world() -> Vector2:
	return global_position + offset

func screen_to_world(screen_position: Vector2) -> Vector2:
	var viewport_size := get_viewport().get_visible_rect().size
	var zoom_factor := zoom.x if zoom.x != 0.0 else 1.0
	return view_center_world() + (screen_position - viewport_size * 0.5) / zoom_factor

func world_to_screen(world_position: Vector2) -> Vector2:
	var viewport_size := get_viewport().get_visible_rect().size
	var zoom_factor := zoom.x if zoom.x != 0.0 else 1.0
	return (world_position - view_center_world()) * zoom_factor + viewport_size * 0.5

func get_world_mouse_position() -> Vector2:
	return screen_to_world(get_viewport().get_mouse_position())

# ------------------------------------------------------------------
# Editor mode (Creation Mode floor editing)
# ------------------------------------------------------------------

## True while the camera is detached from the player for floor editing.
func is_editor_active() -> bool:
	return _editor_active

## Detaches the camera from the player for floor editing. The
## gameplay zoom ladder is kept — Creation Mode uses the same zooms
## as normal play. Camera position is left untouched; call focus_on()
## to aim.
func set_editor_mode(editor_enabled: bool) -> void:
	if editor_enabled == _editor_active:
		return
	if editor_enabled and _recenter_action.is_valid():
		# Editor mode suspends _process follow logic — run the pending
		# action now so a deferred teleport can't soft-lock.
		var action := _recenter_action
		_recenter_action = Callable()
		_recenter_phase = 0
		action.call()
	_editor_active = editor_enabled
	if not editor_enabled:
		_pan_dragging = false

## Centers the camera on a world position, optionally at a zoom level.
func focus_on(world_position: Vector2, zoom_index := -1) -> void:
	global_position = world_position
	if zoom_index >= 0:
		set_zoom_level(zoom_index)

## Held-key pan for editor mode. Runs from _process so it does not
## compete with the player's key-event movement handling.
func _editor_pan_step(delta: float) -> void:
	var direction := Vector2.ZERO
	if Input.is_physical_key_pressed(KEY_A) or Input.is_physical_key_pressed(KEY_LEFT):
		direction.x -= 1.0
	if Input.is_physical_key_pressed(KEY_D) or Input.is_physical_key_pressed(KEY_RIGHT):
		direction.x += 1.0
	if Input.is_physical_key_pressed(KEY_W) or Input.is_physical_key_pressed(KEY_UP):
		direction.y -= 1.0
	if Input.is_physical_key_pressed(KEY_S) or Input.is_physical_key_pressed(KEY_DOWN):
		direction.y += 1.0
	if direction == Vector2.ZERO:
		return
	global_position += direction * editor_pan_speed * delta / maxf(zoom.x, 0.001)
