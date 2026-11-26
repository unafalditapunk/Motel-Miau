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
	var desired := _desired_position(target)
	# A teleport (floor portal, floor switch, room connection, spawn)
	# moves the target farther than any single movement step — snap
	# the camera instead of letting it glide across the world.
	var teleported := not _follow_pos_valid \
		or target.global_position.distance_to(_last_follow_pos) > follow_snap_distance
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
	if teleported:
		global_position = _desired_position(target)

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
