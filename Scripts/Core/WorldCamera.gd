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

func _ready() -> void:
	anchor_mode = Camera2D.ANCHOR_MODE_DRAG_CENTER
	ignore_rotation = true
	position_smoothing_enabled = false
	offset = Vector2.ZERO
	enabled = true
	make_current()
	_apply_zoom_level()

func _process(delta: float) -> void:
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
