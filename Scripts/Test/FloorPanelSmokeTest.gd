extends SceneTree

## Smoke test for the Floor Manager UI: F7 opens/closes the panel, the
## list is generated from the Floor registry, Enter travels via
## FloorManager.switch_floor, the active floor is marked, world input
## is blocked while open, and the F3 debug HUD shows floor info.

const SCRATCH_ROOT := "user://smoke_floor_panel_saves"

var _frames := 0
var _stage := 0
var _failures: Array[String] = []
var _world: WorldBootstrap
var _panel: FloorPanel
var _debug_hud: DebugHud
var _controller: BlockPlacementController

func _initialize() -> void:
	FloorSaveSystem.save_root = SCRATCH_ROOT
	_remove_dir_contents(SCRATCH_ROOT)
	_world = load("res://Scenes/World/WorldBootstrap.tscn").instantiate()
	root.add_child(_world)

func _process(_delta: float) -> bool:
	_frames += 1
	if _frames == 2:
		# The P3 slide transition defers the floor switch until the
		# slide-out finishes; zeroing the slide duration keeps
		# switches synchronous for this frame-driven test.
		_world.room_world.room_slide_duration = 0.0
		_panel = _world.get_node_or_null("FloorPanel") as FloorPanel
		_debug_hud = _world.get_node_or_null("DebugHud") as DebugHud
		_controller = _world.get_node_or_null("BlockPlacementController") as BlockPlacementController
	if _frames < 8:
		return false
	if _stage == 0:
		_run_checks()
		_stage = 1
		return false
	# Stage 1: the last travel's transition fade must have released
	# the input lock before world input is exercised again.
	if TransitionOverlay.any_active(self):
		return false
	var pos_after := _world.player.grid_position
	_world.player.request_move(Vector2i(1, 0))
	_expect(_world.player.grid_position != pos_after, "player movement still blocked after panel closed")
	_controller._unhandled_input(_key(KEY_E))
	_expect(_controller.construction_mode, "E key did not toggle after panel closed")
	_controller.construction_mode = false
	_report()
	quit()
	return true

func _expect(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)

func _remove_dir_contents(path: String) -> void:
	var dir := DirAccess.open(path)
	if dir == null:
		return
	for file_name in dir.get_files():
		dir.remove(file_name)
	for sub in dir.get_directories():
		_remove_dir_contents(path.path_join(sub))
		DirAccess.remove_absolute(path.path_join(sub))

func _key(keycode: Key) -> InputEventKey:
	var event := InputEventKey.new()
	event.keycode = keycode
	event.physical_keycode = keycode
	event.pressed = true
	return event

func _enter_buttons() -> Array[Button]:
	var buttons: Array[Button] = []
	for button in _panel._enter_buttons.values():
		if is_instance_valid(button):
			buttons.append(button)
	return buttons

func _enter_button_for(floor_id: StringName) -> Button:
	var button: Button = _panel._enter_buttons.get(floor_id)
	return button if button != null and is_instance_valid(button) else null

func _row_for(floor_id: StringName) -> Control:
	var row: Control = _panel._floor_rows.get(floor_id)
	return row if row != null and is_instance_valid(row) else null

func _run_checks() -> void:
	_expect(_panel != null, "FloorPanel missing from WorldBootstrap")
	_expect(_debug_hud != null, "DebugHud missing")
	_expect(_controller != null, "BlockPlacementController missing")
	if _panel == null or _world == null or _world.floor_manager == null or _world.player == null:
		return
	var manager := _world.floor_manager
	var player := _world.player
	player.move_duration = 0.0

	# --- Panel opens/closes with F7 and lists registry floors ---
	_expect(not _panel.is_open(), "panel should start closed")
	_panel._unhandled_input(_key(KEY_F7))
	_expect(_panel.is_open(), "F7 did not open the panel")
	_expect(_panel._root.visible, "panel root not visible when open")
	var floor_count := manager.floors.size()
	_expect(_enter_buttons().size() == floor_count, "panel shows %d enter buttons, expected %d floors" % [_enter_buttons().size(), floor_count])
	for id in [&"motel", &"forest", &"village"]:
		_expect(_row_for(id) != null, "panel missing row for floor '%s'" % id)
		_expect(_enter_button_for(id) != null, "panel missing Enter button for '%s'" % id)
	_expect(manager.active_floor == null, "active floor should be null before first travel (legacy world)")
	for button in _enter_buttons():
		_expect(not button.disabled, "Enter disabled before any floor is active")

	# --- F7 toggles closed and open again ---
	_panel._unhandled_input(_key(KEY_F7))
	_expect(not _panel.is_open(), "F7 did not close the panel")
	_expect(not FloorPanel.any_open(self), "any_open true while panel closed")
	_panel._unhandled_input(_key(KEY_F7))
	_expect(_panel.is_open(), "F7 did not reopen the panel")

	# --- World input is blocked while open ---
	_expect(FloorPanel.any_open(self), "any_open false while panel open")
	var pos_before := player.grid_position
	player.request_move(Vector2i(1, 0))
	_expect(player.grid_position == pos_before and not player._is_moving, "player moved while panel open")
	_controller.construction_mode = true
	_controller._unhandled_input(_key(KEY_E))
	_expect(_controller.construction_mode, "E key did not toggle while panel open (should be blocked)")
	_controller.construction_mode = false
	_controller._unhandled_input(_key(KEY_E))
	_expect(not _controller.construction_mode, "E key toggled construction mode while panel open")

	# --- F3 still works while the panel is open ---
	_debug_hud._unhandled_input(_key(KEY_F3))
	_expect(_debug_hud.enabled, "F3 did not enable debug HUD while panel open")

	# --- Enter Motel via its button's pressed signal ---
	var motel_button := _enter_button_for(&"motel")
	motel_button.emit_signal(&"pressed")
	_expect(not _panel.is_open(), "panel did not close after successful travel")
	_expect(manager.active_floor != null and manager.active_floor.floor_id == &"motel", "active floor is not motel")
	_expect(_world.room_world.registry.get_rooms().size() == 17, "motel rooms = %d, expected 17" % _world.room_world.registry.get_rooms().size())
	_expect(player.room != null and player.room.room_coordinates == Vector2i(0, 0), "motel player room wrong")
	_expect(player.grid_position == Vector2i(6, 6), "motel spawn wrong: %s" % player.grid_position)
	_expect(manager.has_floor_save(&"motel") == false, "motel should be unsaved until switching away")

	# --- Reopen: active floor marked, its Enter disabled ---
	_panel._unhandled_input(_key(KEY_F7))
	_expect(_panel.is_open(), "F7 did not reopen the panel")
	var motel_enter := _enter_button_for(&"motel")
	_expect(motel_enter != null and motel_enter.disabled, "active floor's Enter button not disabled")
	var forest_row := _row_for(&"forest")
	_expect(forest_row != null, "forest row missing after travel")

	# --- Debug HUD shows floor info ---
	var hud_text := _debug_hud._build_text()
	_expect(hud_text.contains("Motel") and hud_text.contains("motel"), "debug HUD missing motel floor line: %s" % hud_text)

	# --- Travel Forest -> Village -> Motel; saves accumulate per floor ---
	_panel._on_enter_pressed(&"forest")
	_expect(manager.active_floor != null and manager.active_floor.floor_id == &"forest", "active floor is not forest")
	_expect(_world.room_world.registry.get_rooms().size() == 9, "forest rooms = %d" % _world.room_world.registry.get_rooms().size())
	_expect(manager.has_floor_save(&"motel"), "motel save missing after leaving it")
	hud_text = _debug_hud._build_text()
	_expect(hud_text.contains("Forest"), "debug HUD not updated to forest: %s" % hud_text)

	_panel._unhandled_input(_key(KEY_F7))
	_panel._on_enter_pressed(&"village")
	_expect(manager.active_floor != null and manager.active_floor.floor_id == &"village", "active floor is not village")
	_expect(_world.room_world.registry.get_rooms().size() == 9, "village rooms = %d" % _world.room_world.registry.get_rooms().size())
	hud_text = _debug_hud._build_text()
	_expect(hud_text.contains("Village"), "debug HUD not updated to village")

	_panel._unhandled_input(_key(KEY_F7))
	_panel._on_enter_pressed(&"motel")
	_expect(manager.active_floor != null and manager.active_floor.floor_id == &"motel", "failed to return to motel")
	_expect(_world.room_world.registry.get_rooms().size() == 17, "motel reload rooms = %d" % _world.room_world.registry.get_rooms().size())
	_expect(player.room != null and player.room.room_coordinates == Vector2i(0, 0), "motel player room wrong after roundtrip")
	_expect(player.grid_position == Vector2i(6, 6), "motel position not restored: %s" % player.grid_position)
	hud_text = _debug_hud._build_text()
	_expect(hud_text.contains("Motel"), "debug HUD not updated back to motel")

	# --- Panel closed by the successful travel ---
	_expect(not _panel.is_open(), "panel should be closed after successful travel")
	_expect(not FloorPanel.any_open(self), "any_open still true after close")

func _report() -> void:
	if _failures.is_empty():
		print("FLOOR_PANEL_SMOKE: OK")
	else:
		for failure in _failures:
			push_error("FLOOR_PANEL_SMOKE FAIL: " + failure)
		print("FLOOR_PANEL_SMOKE: FAILED (%d)" % _failures.size())
