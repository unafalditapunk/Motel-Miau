class_name AvatarPanel
extends CanvasLayer

## Avatar picker: P toggles it in Normal Mode (Build Mode, Creation
## Mode, FloorPanel and transitions suspend it). Lists every scanned
## AvatarCatalog race on the left and that race's variants on the
## right; clicking a variant equips it immediately, persists the
## choice, and announces it to the server in multiplayer.
##
## While open it blocks world interaction: Player movement and
## BlockPlacementController input check AvatarPanel.any_open().

signal panel_toggled(is_open: bool)

const PANEL_WIDTH := 470.0
const PANEL_HEIGHT := 380.0
const TOGGLE_KEY := KEY_P
const LAYER_INDEX := 65
const PREVIEW_SIZE := 44.0

var panel_open := false:
	set(value):
		if panel_open == value:
			return
		panel_open = value
		if _root != null:
			_root.visible = value
		if value:
			_rebuild()
		panel_toggled.emit(value)

var _root: PanelContainer
var _race_box: VBoxContainer
var _variant_box: VBoxContainer
var _status_label: Label
var _hint_label: Label
var _selected_race := ""
var _race_group := ButtonGroup.new()
var _variant_group := ButtonGroup.new()
var _controller: BlockPlacementController

func _ready() -> void:
	layer = LAYER_INDEX
	add_to_group(&"avatar_panels")
	_build_ui()
	_root.visible = panel_open

func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventKey):
		return
	var key_event := event as InputEventKey
	if not key_event.pressed or key_event.echo:
		return
	if panel_open:
		if key_event.keycode == TOGGLE_KEY or key_event.keycode == KEY_ESCAPE:
			close()
			get_viewport().set_input_as_handled()
		return
	# Normal Mode only: Build Mode, Creation Mode, FloorPanel and
	# screen transitions all own the keyboard while active.
	if key_event.keycode == TOGGLE_KEY and _can_open():
		open()
		get_viewport().set_input_as_handled()

## True when nothing else owns the keyboard: not Build Mode
## (construction_mode), Creation Mode, FloorPanel, or a transition.
func _can_open() -> bool:
	if FloorEditor.any_active(get_tree()) or FloorPanel.any_open(get_tree()) \
			or TransitionOverlay.any_active(get_tree()):
		return false
	if _controller == null:
		_controller = get_tree().get_first_node_in_group(&"block_placement_controller") as BlockPlacementController
	return _controller == null or not _controller.construction_mode

func open() -> void:
	panel_open = true

func close() -> void:
	panel_open = false

func toggle() -> void:
	panel_open = not panel_open

func is_open() -> bool:
	return panel_open

## True when any AvatarPanel in the tree is open. Player movement and
## world interaction check this to stay disabled while the picker is
## up. Safe to call with a null tree.
static func any_open(tree: SceneTree) -> bool:
	if tree == null:
		return false
	for node in tree.get_nodes_in_group(&"avatar_panels"):
		var panel := node as AvatarPanel
		if panel != null and panel.panel_open:
			return true
	return false

# ------------------------------------------------------------------
# Content
# ------------------------------------------------------------------

func _local_player() -> Player:
	return get_tree().get_first_node_in_group(&"player") as Player

func _rebuild() -> void:
	AvatarCatalog.refresh()
	for child in _race_box.get_children():
		child.queue_free()
	for child in _variant_box.get_children():
		child.queue_free()
	var scan := AvatarCatalog.scan()
	_hint_label.text = "[P] close · click a variant to equip"
	if (scan["races"] as Array).is_empty():
		_add_info_row(_variant_box, "No characters found under %s." % AvatarCatalog.CHARACTERS_ROOT)
		return
	var current_id := _current_avatar_id()
	var current_race := ""
	if not current_id.is_empty():
		var entry: Variant = AvatarCatalog.find(current_id)
		if entry is Dictionary:
			current_race = String(entry.get("race_id", ""))
	# Preselect the race holding the active avatar; fall back to the
	# first race with at least one ready variant.
	if current_race.is_empty() or not _race_has_variants(scan, current_race):
		current_race = _first_race_with_ready(scan)
	_selected_race = current_race
	for race in scan["races"]:
		_race_box.add_child(_make_race_button(race, current_race))
	_rebuild_variants(scan, current_id)

func _race_has_variants(scan: Dictionary, race_id: String) -> bool:
	for race in scan["races"]:
		if String(race["id"]) == race_id:
			return not (race["variants"] as Array).is_empty()
	return false

func _first_race_with_ready(scan: Dictionary) -> String:
	for race in scan["races"]:
		for avatar_id in race["variants"]:
			var entry: Dictionary = scan["by_id"][avatar_id]
			if entry["ready"]:
				return String(race["id"])
	return String((scan["races"] as Array)[0]["id"]) if not (scan["races"] as Array).is_empty() else ""

func _current_avatar_id() -> StringName:
	var player := _local_player()
	if player == null:
		return AvatarCatalog.load_selection()
	var id := AvatarCatalog.id_for_root(player.character_root)
	return id if not id.is_empty() else AvatarCatalog.load_selection()

func _make_race_button(race: Dictionary, active_race: String) -> Button:
	var race_id := String(race["id"])
	var button := Button.new()
	button.text = "%s (%d)" % [race["name"], (race["variants"] as Array).size()]
	button.toggle_mode = true
	button.button_group = _race_group
	button.custom_minimum_size = Vector2(0.0, 24.0)
	button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	button.alignment = HORIZONTAL_ALIGNMENT_LEFT
	PixelUi.style_button(button)
	PixelUi.nearest(button)
	button.set_pressed_no_signal(race_id == active_race)
	button.pressed.connect(_on_race_pressed.bind(race_id))
	return button

func _on_race_pressed(race_id: String) -> void:
	if _selected_race == race_id:
		return
	_selected_race = race_id
	_rebuild_variants(AvatarCatalog.scan(), _current_avatar_id())

func _rebuild_variants(scan: Dictionary, current_id: StringName) -> void:
	for child in _variant_box.get_children():
		child.queue_free()
	var found := false
	for race in scan["races"]:
		if String(race["id"]) != _selected_race:
			continue
		found = true
		for avatar_id in race["variants"]:
			_variant_box.add_child(_make_variant_button(scan["by_id"][avatar_id], current_id))
		break
	if not found:
		_add_info_row(_variant_box, "No variants in this race.")

func _make_variant_button(entry: Dictionary, current_id: StringName) -> Button:
	var avatar_id := StringName(entry["id"])
	var has_art: bool = entry["ready"]
	var button := Button.new()
	button.set_meta(&"avatar_id", String(avatar_id))
	button.toggle_mode = true
	button.button_group = _variant_group
	button.disabled = not has_art
	button.custom_minimum_size = Vector2(0.0, 52.0)
	button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	PixelUi.style_button(button, true)
	PixelUi.nearest(button)
	button.set_pressed_no_signal(avatar_id == current_id)
	if not has_art:
		button.tooltip_text = "Missing art: %s" % ", ".join(entry["missing"])
	var margin := MarginContainer.new()
	margin.mouse_filter = Control.MOUSE_FILTER_IGNORE
	for side in [&"margin_left", &"margin_right", &"margin_top", &"margin_bottom"]:
		margin.add_theme_constant_override(side, 3)
	button.add_child(margin)
	var hbox := HBoxContainer.new()
	hbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
	margin.add_child(hbox)
	var preview := TextureRect.new()
	preview.custom_minimum_size = Vector2(PREVIEW_SIZE, PREVIEW_SIZE)
	preview.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	preview.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	preview.texture = entry["preview"]
	preview.mouse_filter = Control.MOUSE_FILTER_IGNORE
	PixelUi.nearest(preview)
	hbox.add_child(preview)
	var labels := VBoxContainer.new()
	labels.mouse_filter = Control.MOUSE_FILTER_IGNORE
	labels.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	hbox.add_child(labels)
	var name_label := Label.new()
	name_label.text = entry["display_name"]
	PixelUi.style_label(name_label, PixelUi.TEXT_COLOR if has_art else PixelUi.TEXT_DIM, 11)
	name_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	labels.add_child(name_label)
	var detail := Label.new()
	detail.text = "equipped" if avatar_id == current_id else ("no art yet" if not has_art else entry["id"])
	PixelUi.style_label(detail, PixelUi.TEXT_DIM, 9)
	detail.mouse_filter = Control.MOUSE_FILTER_IGNORE
	labels.add_child(detail)
	button.pressed.connect(_on_variant_pressed.bind(entry))
	return button

func _add_info_row(box: VBoxContainer, text: String) -> void:
	var label := Label.new()
	label.text = text
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	PixelUi.style_label(label, PixelUi.TEXT_DIM, 10, true)
	box.add_child(label)

func _on_variant_pressed(entry: Dictionary) -> void:
	var avatar_id := StringName(entry["id"])
	var player := _local_player()
	if player == null:
		_set_status("No player to equip.", true)
		return
	if not player.set_character(String(entry["root"])):
		_set_status("Could not equip '%s'." % entry["display_name"], true)
		return
	var err := AvatarCatalog.save_selection(avatar_id)
	if err != OK:
		push_warning("AvatarPanel: could not save avatar selection: %s" % error_string(err))
	var net := get_tree().get_first_node_in_group(&"multiplayer_manager") as MultiplayerManager
	if net != null and net.mode == MultiplayerManager.Mode.CLIENT:
		net.request_avatar_change(avatar_id)
	_set_status("Equipped %s." % entry["display_name"], false)

func _set_status(text: String, is_error: bool) -> void:
	_status_label.text = text
	_status_label.add_theme_color_override(&"font_color",
		Color(1.0, 0.55, 0.5) if is_error else PixelUi.TEXT_DIM)

# ------------------------------------------------------------------
# UI construction (code-built, matching FloorPanel/CatalogPanel)
# ------------------------------------------------------------------

func _build_ui() -> void:
	_root = PanelContainer.new()
	_root.name = "AvatarPanelRoot"
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
	title.text = "Avatar"
	PixelUi.style_label(title, PixelUi.TEXT_COLOR, 12, true)
	vbox.add_child(title)

	_hint_label = Label.new()
	_hint_label.text = "[P] close"
	PixelUi.style_label(_hint_label, PixelUi.TEXT_DIM, 9, true)
	vbox.add_child(_hint_label)

	var columns := HBoxContainer.new()
	columns.size_flags_vertical = Control.SIZE_EXPAND_FILL
	columns.add_theme_constant_override(&"separation", 6)
	vbox.add_child(columns)

	var race_scroll := ScrollContainer.new()
	race_scroll.custom_minimum_size = Vector2(120.0, 0.0)
	race_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	columns.add_child(race_scroll)
	_race_box = VBoxContainer.new()
	_race_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_race_box.add_theme_constant_override(&"separation", 3)
	race_scroll.add_child(_race_box)

	var variant_scroll := ScrollContainer.new()
	variant_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	variant_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	columns.add_child(variant_scroll)
	_variant_box = VBoxContainer.new()
	_variant_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_variant_box.add_theme_constant_override(&"separation", 4)
	variant_scroll.add_child(_variant_box)

	_status_label = Label.new()
	_status_label.text = ""
	PixelUi.style_label(_status_label, PixelUi.TEXT_DIM, 9)
	vbox.add_child(_status_label)
