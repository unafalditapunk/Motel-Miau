class_name FloorPanel
extends CanvasLayer

## Floor Manager UI: lists every registered Floor and travels between
## them. Built entirely in code with PixelUi styling, matching
## CatalogPanel/BuildingToolbar. All switching goes through
## FloorManager.switch_floor — the panel holds no save/load logic.
##
## While open it blocks world interaction: Player movement and
## BlockPlacementController input check FloorPanel.any_open().

signal panel_toggled(is_open: bool)

const PANEL_WIDTH := 330.0
const PANEL_HEIGHT := 380.0
const TOGGLE_KEY := KEY_F7
const LAYER_INDEX := 66

## Bound FloorManager; resolved lazily from the world group when null.
var floor_manager: FloorManager
var panel_open := false:
	set(value):
		if panel_open == value:
			return
		panel_open = value
		if _root != null:
			_root.visible = value
		if value:
			_rebuild_list()
		panel_toggled.emit(value)

var _root: PanelContainer
var _list_box: VBoxContainer
var _status_label: Label
var _hint_label: Label
var _new_floor_button: Button
var _create_box: VBoxContainer
var _id_edit: LineEdit
var _name_edit: LineEdit
## Live row/button references per floor id, rebuilt with the list.
## queue_free'd rows linger until end of frame, so tree searches can
## return stale duplicates; these maps always point at current nodes.
var _floor_rows := {}
var _enter_buttons := {}

func _ready() -> void:
	layer = LAYER_INDEX
	add_to_group(&"floor_panels")
	_build_ui()
	_root.visible = panel_open

func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventKey):
		return
	var key_event := event as InputEventKey
	if not key_event.pressed or key_event.echo or key_event.keycode != TOGGLE_KEY:
		return
	# Floor switching mid-edit would invalidate the editor's room refs;
	# Creation Mode owns the keyboard until it exits. An active combat
	# encounter locks floor changes too.
	if FloorEditor.any_active(get_tree()) or CombatManager.any_active(get_tree()):
		return
	toggle()
	get_viewport().set_input_as_handled()

func open() -> void:
	panel_open = true

func close() -> void:
	panel_open = false

func toggle() -> void:
	panel_open = not panel_open

func is_open() -> bool:
	return panel_open

## True when any FloorPanel in the tree is open. Player movement and
## world interaction check this to stay disabled while the manager is
## up. Safe to call with a null tree.
static func any_open(tree: SceneTree) -> bool:
	if tree == null:
		return false
	for node in tree.get_nodes_in_group(&"floor_panels"):
		var panel := node as FloorPanel
		if panel != null and panel.panel_open:
			return true
	return false

func _resolve_floor_manager() -> FloorManager:
	if floor_manager != null and is_instance_valid(floor_manager):
		return floor_manager
	var world := get_tree().get_first_node_in_group(&"world") as WorldBootstrap
	if world != null:
		floor_manager = world.floor_manager
	return floor_manager

var _net_hooked := false

## The MultiplayerManager node, or null in single-player.
func _resolve_net() -> MultiplayerManager:
	return get_tree().get_first_node_in_group(&"multiplayer_manager") as MultiplayerManager

## Connects floor_result once so accepted/rejected floor ops refresh
## the list and status even while the panel stays open. Called from
## _rebuild_list and the request handlers — the net node may not
## exist yet when the panel first readies.
func _ensure_net_hook() -> void:
	if _net_hooked:
		return
	var net := _resolve_net()
	if net == null:
		return
	_net_hooked = true
	net.floor_result.connect(_on_floor_result)

func _on_floor_result(_op_id: int, accepted: bool, reason: StringName,
		payload: Dictionary) -> void:
	if accepted:
		var floor_id := String(payload.get("floor_id", "?"))
		if String(payload.get("op", "")) == "floor_create":
			var def: Variant = payload.get("floor_def", {})
			var label := String(def.get("display_name", "")) if def is Dictionary else ""
			_set_status("Created floor '%s' (%s)." % [label if not label.is_empty() else floor_id, floor_id], false)
		else:
			_set_status("Deleted floor '%s'." % floor_id, false)
	else:
		_set_status("Floor op rejected: %s" % _floor_op_reason_text(reason), true)
	_rebuild_list()

## Human-readable text for the StringName reasons the server sends
## with floor-op rejections; unknown reasons pass through raw.
static func _floor_op_reason_text(reason: StringName) -> String:
	match reason:
		&"occupied":
			return "players are still on that floor"
		&"busy":
			return "the server is busy — try again"
		&"unknown_floor":
			return "unknown floor"
		&"duplicate_floor":
			return "a floor with that id already exists"
		&"invalid_id":
			return "invalid floor id"
		&"not_ready":
			return "not ready — try again"
		_:
			return String(reason)

func _rebuild_list() -> void:
	for child in _list_box.get_children():
		child.queue_free()
	_floor_rows.clear()
	_enter_buttons.clear()
	var manager := _resolve_floor_manager()
	if manager == null:
		_add_info_row("No FloorManager available.")
		return
	# Multiplayer clients see the floor list read-only for structural
	# edits, but Enter stays enabled: it sends a server-authoritative
	# floor TRAVEL request (Phase C2) rather than a local switch.
	# Create/Delete also work on clients — they send floor-op requests
	# (Phase C4) the server validates and broadcasts back.
	var readonly := manager.structural_edits_readonly()
	_ensure_net_hook()
	if readonly:
		_hint_label.text = "[F7] close · travel via Enter · floor edits are server requests"
	else:
		_hint_label.text = "[F7] close"
	if manager.floors.is_empty():
		_add_info_row("No floors registered.")
		return
	for floor_def in manager.floors:
		_list_box.add_child(_make_floor_row(manager, floor_def))

func _add_info_row(text: String) -> void:
	var label := Label.new()
	label.text = text
	PixelUi.style_label(label, PixelUi.TEXT_DIM, 10, true)
	_list_box.add_child(label)

func _make_floor_row(manager: FloorManager, floor_def: Floor) -> Control:
	var row := PanelContainer.new()
	row.name = "Floor_%s" % floor_def.floor_id
	PixelUi.style_panel(row, PixelUi.BUTTON_BG, PixelUi.BUTTON_BORDER)
	row.custom_minimum_size = Vector2(0.0, 52.0)
	var margin := MarginContainer.new()
	for side in [&"margin_left", &"margin_right", &"margin_top", &"margin_bottom"]:
		margin.add_theme_constant_override(side, 4)
	row.add_child(margin)
	var hbox := HBoxContainer.new()
	hbox.add_theme_constant_override(&"separation", 6)
	margin.add_child(hbox)

	var info := VBoxContainer.new()
	info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hbox.add_child(info)

	var is_active := manager.active_floor != null and manager.active_floor.floor_id == floor_def.floor_id
	var name_label := Label.new()
	name_label.text = floor_def.display_name if not floor_def.display_name.is_empty() else String(floor_def.floor_id)
	PixelUi.style_label(name_label, PixelUi.TEXT_COLOR.lightened(0.15) if is_active else PixelUi.TEXT_COLOR, 11)
	info.add_child(name_label)

	var badges: Array[String] = []
	if is_active:
		badges.append("ACTIVE")
	badges.append("saved" if manager.has_floor_save(floor_def.floor_id) else "new")
	var detail := Label.new()
	detail.text = "%s · %s · %s" % [
		String(floor_def.floor_id),
		_layout_description(floor_def),
		" · ".join(badges)]
	PixelUi.style_label(detail, PixelUi.TEXT_DIM, 9)
	info.add_child(detail)

	var enter := Button.new()
	enter.name = "EnterButton"
	enter.text = "Enter"
	enter.custom_minimum_size = Vector2(56.0, 24.0)
	enter.disabled = is_active
	enter.set_meta(&"floor_id", floor_def.floor_id)
	PixelUi.style_button(enter, true)
	PixelUi.nearest(enter)
	enter.pressed.connect(_on_enter_pressed.bind(floor_def.floor_id))
	hbox.add_child(enter)

	var del := Button.new()
	del.name = "DeleteButton"
	del.text = "Del"
	del.custom_minimum_size = Vector2(40.0, 24.0)
	# The last remaining floor can never be deleted; multiplayer
	# clients send a server request and let the server decide.
	del.disabled = manager.floors.size() <= 1
	del.set_meta(&"floor_id", floor_def.floor_id)
	PixelUi.style_button(del, true)
	PixelUi.nearest(del)
	del.pressed.connect(_on_delete_pressed.bind(floor_def.floor_id))
	hbox.add_child(del)
	_floor_rows[floor_def.floor_id] = row
	_enter_buttons[floor_def.floor_id] = enter
	return row

## Short layout descriptor: "3x3" when room ids form a filled grid,
## otherwise a plain room count.
func _layout_description(floor_def: Floor) -> String:
	var ids := floor_def.room_ids()
	if ids.is_empty():
		return "no rooms"
	var min_x := ids[0].x
	var max_x := ids[0].x
	var min_y := ids[0].y
	var max_y := ids[0].y
	for id in ids:
		min_x = mini(min_x, id.x)
		max_x = maxi(max_x, id.x)
		min_y = mini(min_y, id.y)
		max_y = maxi(max_y, id.y)
	var grid_size := (max_x - min_x + 1) * (max_y - min_y + 1)
	if ids.size() == grid_size:
		return "%dx%d" % [max_x - min_x + 1, max_y - min_y + 1]
	return "%d rooms" % ids.size()

func _on_enter_pressed(floor_id: StringName) -> void:
	var manager := _resolve_floor_manager()
	if manager == null:
		_set_status("No FloorManager available.", true)
		return
	if manager.structural_edits_readonly():
		# Client: never switch locally — ask the server to move this
		# peer's body. The destination snapshot arrives async.
		var net := get_tree().get_first_node_in_group(&"multiplayer_manager") as MultiplayerManager
		if net == null or not net.request_floor_transition(floor_id):
			_set_status("Could not request travel to '%s'." % floor_id, true)
		else:
			_set_status("Requesting travel to %s..." % floor_id, false)
			close()
		return
	if manager.active_floor != null and manager.active_floor.floor_id == floor_id:
		return
	_set_status("Traveling to %s..." % floor_id, false)
	# At <1x overview zoom, glide the camera onto the avatar before
	# the slide plays. Re-entry re-runs the guards, so a floor that
	# became active mid-glide cancels cleanly.
	var viewport_camera := get_viewport().get_camera_2d() as WorldCamera
	if viewport_camera != null and viewport_camera.defer_until_recentered(
			func() -> void: _on_enter_pressed(floor_id)):
		return
	# Slide transition when the overlay exists: the switch is deferred
	# until the slide-out finishes. Close the panel as soon as the
	# travel is accepted — the overlay's message label reports any
	# later failure.
	var overlay := get_tree().get_first_node_in_group(&"transition_overlay") as TransitionOverlay
	var switched := false
	if overlay != null:
		if not overlay.transition_completed.is_connected(_on_transition_completed):
			overlay.transition_completed.connect(_on_transition_completed)
		switched = bool(overlay.play_transition(func() -> bool:
			return manager.switch_floor(floor_id)))
	else:
		switched = manager.switch_floor(floor_id)
	if switched:
		close()
	else:
		_set_status("Could not enter '%s'. See console for details." % floor_id, true)
		_rebuild_list()

## Async transition result (slide path): surface a failure status
## when the deferred switch did not complete.
func _on_transition_completed(success: bool) -> void:
	if not success and is_open():
		_set_status("Travel failed. See console for details.", true)

func _on_delete_pressed(floor_id: StringName) -> void:
	var manager := _resolve_floor_manager()
	if manager == null:
		_set_status("No FloorManager available.", true)
		return
	if manager.structural_edits_readonly():
		# Client: ask the server — it rejects occupied/last floors.
		var net := _resolve_net()
		if net == null or not net.request_floor_delete(floor_id):
			_set_status("Could not request delete of '%s'." % floor_id, true)
		else:
			_set_status("Requesting delete of '%s'..." % floor_id, false)
		return
	if manager.delete_floor(floor_id):
		_set_status("Deleted floor '%s'." % floor_id, false)
	else:
		_set_status("Could not delete '%s'. See console for details." % floor_id, true)
	_rebuild_list()

func _on_new_floor_pressed() -> void:
	_create_box.visible = not _create_box.visible

func _on_create_floor_pressed() -> void:
	var manager := _resolve_floor_manager()
	if manager == null:
		_set_status("No FloorManager available.", true)
		return
	var id_text := _id_edit.text.strip_edges()
	if id_text.is_empty():
		_set_status("Floor id is required.", true)
		return
	if manager.structural_edits_readonly():
		# Client: ask the server; the canonical definition is derived
		# server-side and arrives via floor_result.
		var net := _resolve_net()
		if net == null or not net.request_floor_create(StringName(id_text), _name_edit.text.strip_edges()):
			_set_status("Could not request floor '%s'." % id_text, true)
		else:
			_set_status("Requesting floor '%s'..." % id_text, false)
		return
	var floor_def := manager.create_floor(StringName(id_text), _name_edit.text.strip_edges())
	if floor_def == null:
		_set_status("Could not create floor '%s'. See console for details." % id_text, true)
	else:
		_set_status("Created floor '%s'." % floor_def.floor_id, false)
		_id_edit.text = ""
		_name_edit.text = ""
		_create_box.visible = false
	_rebuild_list()

func _make_line_edit(placeholder: String) -> LineEdit:
	var edit := LineEdit.new()
	edit.placeholder_text = placeholder
	edit.custom_minimum_size = Vector2(0.0, 22.0)
	edit.add_theme_color_override(&"font_color", PixelUi.TEXT_COLOR)
	edit.add_theme_color_override(&"font_placeholder_color", PixelUi.TEXT_DIM)
	edit.add_theme_color_override(&"caret_color", PixelUi.TEXT_COLOR)
	edit.add_theme_stylebox_override(&"normal",
		PixelUi.make_panel_stylebox(Color(0.05, 0.05, 0.1, 0.9), PixelUi.BUTTON_BORDER))
	edit.add_theme_stylebox_override(&"focus",
		PixelUi.make_panel_stylebox(Color(0.08, 0.07, 0.14, 0.95), PixelUi.PANEL_BORDER))
	PixelUi.nearest(edit)
	return edit

func _set_status(text: String, is_error: bool) -> void:
	_status_label.text = text
	_status_label.add_theme_color_override(&"font_color",
		Color(1.0, 0.55, 0.5) if is_error else PixelUi.TEXT_DIM)

func _build_ui() -> void:
	_root = PanelContainer.new()
	_root.name = "FloorPanelRoot"
	_root.set_anchors_preset(Control.PRESET_CENTER)
	_root.anchor_left = 0.5
	_root.anchor_right = 0.5
	_root.anchor_top = 0.5
	_root.anchor_bottom = 0.5
	_root.offset_left = -PANEL_WIDTH * 0.5
	_root.offset_top = -PANEL_HEIGHT * 0.5
	_root.offset_right = PANEL_WIDTH * 0.5
	_root.offset_bottom = PANEL_HEIGHT * 0.5
	_root.custom_minimum_size = Vector2(PANEL_WIDTH, PANEL_HEIGHT)
	PixelUi.style_panel(_root)
	PixelUi.nearest(_root)
	add_child(_root)

	var margin := MarginContainer.new()
	for side in [&"margin_left", &"margin_right", &"margin_top", &"margin_bottom"]:
		margin.add_theme_constant_override(side, 6)
	_root.add_child(margin)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override(&"separation", 4)
	margin.add_child(vbox)

	var title := Label.new()
	title.text = "Floors"
	PixelUi.style_label(title, PixelUi.TEXT_COLOR, 12, true)
	vbox.add_child(title)

	var hint := Label.new()
	hint.text = "[F7] close"
	PixelUi.style_label(hint, PixelUi.TEXT_DIM, 9, true)
	_hint_label = hint
	vbox.add_child(hint)

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	vbox.add_child(scroll)

	_list_box = VBoxContainer.new()
	_list_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_list_box.add_theme_constant_override(&"separation", 4)
	scroll.add_child(_list_box)

	_new_floor_button = Button.new()
	_new_floor_button.text = "New Floor"
	_new_floor_button.custom_minimum_size = Vector2(0.0, 24.0)
	PixelUi.style_button(_new_floor_button)
	PixelUi.nearest(_new_floor_button)
	_new_floor_button.pressed.connect(_on_new_floor_pressed)
	vbox.add_child(_new_floor_button)

	_create_box = VBoxContainer.new()
	_create_box.visible = false
	_create_box.add_theme_constant_override(&"separation", 4)
	vbox.add_child(_create_box)

	_id_edit = _make_line_edit("floor_id (e.g. attic)")
	_create_box.add_child(_id_edit)
	_name_edit = _make_line_edit("Display name (optional)")
	_create_box.add_child(_name_edit)

	var create_row := HBoxContainer.new()
	create_row.add_theme_constant_override(&"separation", 4)
	_create_box.add_child(create_row)

	var create_button := Button.new()
	create_button.text = "Create"
	create_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	PixelUi.style_button(create_button)
	PixelUi.nearest(create_button)
	create_button.pressed.connect(_on_create_floor_pressed)
	create_row.add_child(create_button)

	var cancel_button := Button.new()
	cancel_button.text = "Cancel"
	cancel_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	PixelUi.style_button(cancel_button)
	PixelUi.nearest(cancel_button)
	cancel_button.pressed.connect(func() -> void: _create_box.visible = false)
	create_row.add_child(cancel_button)

	_status_label = Label.new()
	_status_label.text = ""
	PixelUi.style_label(_status_label, PixelUi.TEXT_DIM, 9)
	vbox.add_child(_status_label)
