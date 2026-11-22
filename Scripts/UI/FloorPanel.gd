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
	# Creation Mode owns the keyboard until it exits.
	if FloorEditor.any_active(get_tree()):
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

func _rebuild_list() -> void:
	for child in _list_box.get_children():
		child.queue_free()
	_floor_rows.clear()
	_enter_buttons.clear()
	var manager := _resolve_floor_manager()
	if manager == null:
		_add_info_row("No FloorManager available.")
		return
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
	if manager.active_floor != null and manager.active_floor.floor_id == floor_id:
		return
	_set_status("Traveling to %s..." % floor_id, false)
	# Synchronous switch; on success the world is already rebuilt.
	if manager.switch_floor(floor_id):
		close()
	else:
		_set_status("Could not enter '%s'. See console for details." % floor_id, true)
		_rebuild_list()

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
	vbox.add_child(hint)

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	vbox.add_child(scroll)

	_list_box = VBoxContainer.new()
	_list_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_list_box.add_theme_constant_override(&"separation", 4)
	scroll.add_child(_list_box)

	_status_label = Label.new()
	_status_label.text = ""
	PixelUi.style_label(_status_label, PixelUi.TEXT_DIM, 9)
	vbox.add_child(_status_label)
