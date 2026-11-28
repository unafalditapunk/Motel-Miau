extends SceneTree

## Smoke test for the avatar picker: P opens/closes the panel in Normal
## Mode only, the catalog auto-discovers races/variants (ready vs
## art-less), equipping a variant swaps the player's character set and
## persists the selection, west-only walk art mirrors into the east
## directions, and world input stays blocked while the panel is open.

const SCRATCH_SELECTION := "user://smoke_avatar_selection.json"

var _frames := 0
var _stage := 0
var _failures: Array[String] = []
var _world: WorldBootstrap
var _panel: AvatarPanel
var _controller: BlockPlacementController

func _initialize() -> void:
	AvatarCatalog.selection_path = SCRATCH_SELECTION
	DirAccess.remove_absolute(SCRATCH_SELECTION)
	AvatarCatalog.refresh()
	_world = load("res://Scenes/World/WorldBootstrap.tscn").instantiate()
	root.add_child(_world)

func _process(_delta: float) -> bool:
	_frames += 1
	if _frames == 2:
		_panel = _world.get_node_or_null("AvatarPanel") as AvatarPanel
		_controller = _world.get_node_or_null("BlockPlacementController") as BlockPlacementController
	if _frames < 8:
		return false
	if _stage == 0:
		_run_checks()
		_stage = 1
		return false
	# Stage 1: world input must work again once the panel closed.
	var pos_after := _world.player.grid_position
	_world.player.request_move(Vector2i(1, 0))
	_expect(_world.player.grid_position != pos_after, "player movement still blocked after panel closed")
	_report()
	quit()
	return true

func _expect(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)

func _key(keycode: Key) -> InputEventKey:
	var event := InputEventKey.new()
	event.keycode = keycode
	event.physical_keycode = keycode
	event.pressed = true
	return event

func _variant_button_for(avatar_id: String) -> Button:
	for button in _panel._variant_box.get_children():
		if button is Button and button.has_meta(&"avatar_id"):
			if String(button.get_meta(&"avatar_id")) == avatar_id:
				return button
	return null

func _run_checks() -> void:
	_expect(_panel != null, "AvatarPanel missing from WorldBootstrap")
	_expect(_controller != null, "BlockPlacementController missing")
	if _panel == null or _world == null or _world.player == null:
		return
	var player := _world.player
	player.move_duration = 0.0

	# --- Catalog discovery ---
	var scan := AvatarCatalog.scan()
	var by_id: Dictionary = scan["by_id"]
	_expect(by_id.has("cat/black"), "catalog missing cat/black")
	_expect(by_id.has("cat/gray"), "catalog missing cat/gray")
	_expect(by_id.has("cat/orange"), "catalog missing cat/orange")
	_expect(by_id.has("cat/siamese"), "catalog missing cat/siamese")
	_expect(by_id.has("zombie/basic"), "catalog missing zombie/basic placeholder")
	var cat_entry: Dictionary = by_id.get("cat/black", {})
	_expect(bool(cat_entry.get("ready", false)), "cat/black should be ready")
	_expect(cat_entry.get("preview") != null, "cat/black missing preview texture")
	var zombie_entry: Dictionary = by_id.get("zombie/basic", {})
	_expect(not bool(zombie_entry.get("ready", true)), "zombie/basic should not be ready (no art)")
	_expect(String(AvatarCatalog.default_id()) == "cat/black", "default avatar should be cat/black, got '%s'" % AvatarCatalog.default_id())

	# --- P opens/closes in Normal Mode ---
	_expect(not _panel.is_open(), "panel should start closed")
	_panel._unhandled_input(_key(KEY_P))
	_expect(_panel.is_open(), "P did not open the panel")
	_expect(_panel._root.visible, "panel root not visible when open")
	_expect(AvatarPanel.any_open(self), "any_open false while panel open")

	# --- Race list covers every scanned race; cat variants listed ---
	_expect(_panel._race_box.get_child_count() == (scan["races"] as Array).size(),
		"race buttons = %d, expected %d" % [_panel._race_box.get_child_count(), (scan["races"] as Array).size()])
	# The current avatar (cat/black from the scene) preselects cat.
	_expect(_panel._selected_race == "cat", "cat race not preselected, got '%s'" % _panel._selected_race)
	_expect(_panel._variant_box.get_child_count() == 4, "cat variants = %d, expected 4" % _panel._variant_box.get_child_count())

	# --- World input blocked while open ---
	var pos_before := player.grid_position
	player.request_move(Vector2i(1, 0))
	_expect(player.grid_position == pos_before and not player._is_moving, "player moved while panel open")
	_controller._unhandled_input(_key(KEY_E))
	_expect(not _controller.construction_mode, "E toggled build mode while avatar panel open")

	# --- Equip cat/gray through its variant button ---
	var gray_button := _variant_button_for("cat/gray")
	_expect(gray_button != null, "no variant button for cat/gray")
	if gray_button != null:
		_expect(not gray_button.disabled, "cat/gray button disabled despite ready art")
		gray_button.emit_signal(&"pressed")
	_expect(player.character_root == "res://Assets/Characters/cat/gray", "character_root is '%s'" % player.character_root)
	_expect(AvatarCatalog.load_selection() == &"cat/gray", "selection not persisted as cat/gray")
	# West-only art: east walk cycles must exist via the mirror fallback.
	# Animation names keep the folder spelling: "walk_south-west" etc.
	var frames := player.visual.sprite_frames
	_expect(frames.has_animation(&"walk_south-west"), "walk_south-west missing after gray equip")
	_expect(frames.has_animation(&"walk_south-east"), "walk_south-east missing — mirror fallback failed")
	if frames.has_animation(&"walk_south-east"):
		_expect(frames.get_frame_count(&"walk_south-east") > 0, "walk_south-east has no frames")

	# --- Equip cat/orange (has real east files — no mirror needed) ---
	var orange_button := _variant_button_for("cat/orange")
	_expect(orange_button != null, "no variant button for cat/orange")
	if orange_button != null:
		orange_button.emit_signal(&"pressed")
	_expect(player.character_root == "res://Assets/Characters/cat/orange", "character_root is '%s'" % player.character_root)

	# --- set_character refuses roots without rotation art ---
	_expect(not player.set_character("res://Assets/Characters/cat"), "set_character accepted a race root")
	_expect(not player.set_character("res://Assets/Characters/chicken/chick"), "set_character accepted art-less variant")

	# --- Art-less variants render disabled ---
	# queue_free'd cat buttons linger as children until end of frame —
	# count only live ones.
	_panel._on_race_pressed("zombie")
	var live_buttons: Array[Button] = []
	for child in _panel._variant_box.get_children():
		if child is Button and not child.is_queued_for_deletion():
			live_buttons.append(child)
	_expect(live_buttons.size() == 3, "zombie variants = %d, expected 3" % live_buttons.size())
	var any_enabled := false
	for button in live_buttons:
		if not button.disabled:
			any_enabled = true
	_expect(not any_enabled, "art-less zombie variants should all be disabled")

	# --- P toggles closed; Esc also closes ---
	_panel._unhandled_input(_key(KEY_P))
	_expect(not _panel.is_open(), "P did not close the panel")
	_expect(not AvatarPanel.any_open(self), "any_open true after close")
	_panel._unhandled_input(_key(KEY_P))
	_expect(_panel.is_open(), "P did not reopen the panel")
	_panel._unhandled_input(_key(KEY_ESCAPE))
	_expect(not _panel.is_open(), "Esc did not close the panel")

	# --- P is ignored in Build Mode ---
	_controller.construction_mode = true
	_panel._unhandled_input(_key(KEY_P))
	_expect(not _panel.is_open(), "P opened the panel during Build Mode")
	_controller.construction_mode = false

func _report() -> void:
	if _failures.is_empty():
		print("AVATAR_PANEL_SMOKE: OK")
	else:
		for failure in _failures:
			push_error("AVATAR_PANEL_SMOKE FAIL: " + failure)
		print("AVATAR_PANEL_SMOKE: FAILED (%d)" % _failures.size())
