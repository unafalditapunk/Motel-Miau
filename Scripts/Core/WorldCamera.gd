class_name WorldCamera
extends Camera2D

@export_group("Follow")
@export var follow_target: Node2D
@export var follow_smoothing := 6.0
@export var focus_offset := Vector2.ZERO
@export var clamp_to_center_bounds := false
@export var center_bounds := Rect2()

@export_group("Zoom")
@export var zoom_levels: PackedFloat32Array = PackedFloat32Array([1.0, 2.0, 3.0])
@export var current_zoom_index := 0

@export_group("Editor")
## Pan speed in screen pixels per second while editor mode is active.
@export var editor_pan_speed := 900.0
## Zoom ladder used while editor mode is active (wider range than
## gameplay so whole floors can be overviewed).
@export var editor_zoom_levels := PackedFloat32Array([0.4, 0.7, 1.0, 1.5, 2.2, 3.0])

var _editor_active := false
var _saved_zoom_levels := PackedFloat32Array()
var _saved_zoom_index := 0
var _pan_dragging := false
var _pan_drag_last := Vector2.ZERO

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
	var desired := target.global_position + focus_offset
	if clamp_to_center_bounds and center_bounds.has_area():
		desired.x = clampf(desired.x, center_bounds.position.x, center_bounds.end.x)
		desired.y = clampf(desired.y, center_bounds.position.y, center_bounds.end.y)
	if follow_smoothing <= 0.0:
		global_position = desired
		return
	var t := 1.0 - exp(-follow_smoothing * delta)
	global_position = global_position.lerp(desired, t)
	if global_position.distance_to(desired) <= 0.25:
		global_position = desired

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

## Detaches the camera from the player and swaps in the wider editor
## zoom ladder. Gameplay zoom settings are restored on set_editor_mode
## (false). Camera position is left untouched; call focus_on() to aim.
func set_editor_mode(editor_enabled: bool) -> void:
	if editor_enabled == _editor_active:
		return
	_editor_active = editor_enabled
	if editor_enabled:
		_saved_zoom_levels = zoom_levels
		_saved_zoom_index = current_zoom_index
		zoom_levels = editor_zoom_levels
		# Preserve the current zoom factor where the editor ladder allows.
		current_zoom_index = _nearest_zoom_index(zoom.x)
		_apply_zoom_level()
	else:
		_pan_dragging = false
		zoom_levels = _saved_zoom_levels
		current_zoom_index = _saved_zoom_index
		_apply_zoom_level()

## Centers the camera on a world position, optionally at a zoom level.
func focus_on(world_position: Vector2, zoom_index := -1) -> void:
	global_position = world_position
	if zoom_index >= 0:
		set_zoom_level(zoom_index)

## Swaps the zoom ladder while staying in editor mode, preserving the
## current zoom factor where possible. Used to give ROOMS view the
## crisp gameplay zooms while GRID view keeps the wide editor range.
func editor_set_zoom_levels(levels: PackedFloat32Array) -> void:
	if not _editor_active or levels.is_empty():
		return
	var current := zoom.x
	zoom_levels = levels
	current_zoom_index = _nearest_zoom_index(current)
	_apply_zoom_level()

func editor_use_gameplay_zoom() -> void:
	editor_set_zoom_levels(_saved_zoom_levels)

func editor_use_editor_zoom() -> void:
	editor_set_zoom_levels(editor_zoom_levels)

func _nearest_zoom_index(level: float) -> int:
	var best := 0
	var best_distance := INF
	for index in zoom_levels.size():
		var distance := absf(zoom_levels[index] - level)
		if distance < best_distance:
			best_distance = distance
			best = index
	return best

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
