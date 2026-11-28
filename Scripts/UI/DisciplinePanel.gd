class_name DisciplinePanel
extends CanvasLayer

## Discipline panel: K toggles it in Normal Mode (Build Mode,
## Creation Mode, FloorPanel, combat and transitions suspend it —
## equipment can never change mid-encounter). Lists the character's
## Mutant Cursed level and every ability in unlock order; unlocked
## actives/ultimates get an equip toggle, passives and locked rows
## are shown read-only.
##
## While open it blocks world interaction via DisciplinePanel.any_open().

signal panel_toggled(is_open: bool)

const TOGGLE_KEY := KEY_K
const LAYER_INDEX := 66
const PANEL_WIDTH := 430.0
const PANEL_HEIGHT := 400.0

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
var _header_label: Label
var _ability_box: VBoxContainer
var _status_label: Label
var _hint_label: Label
var _controller: BlockPlacementController

func _ready() -> void:
	layer = LAYER_INDEX
	add_to_group(&"discipline_panels")
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
	if key_event.keycode == TOGGLE_KEY and _can_open():
		open()
		get_viewport().set_input_as_handled()

## True when nothing else owns the keyboard: not Build Mode,
## Creation Mode, FloorPanel, combat, transitions, or the avatar
## picker. Combat blocking here is what guarantees equipment cannot
## change during an encounter.
func _can_open() -> bool:
	if FloorEditor.any_active(get_tree()) or FloorPanel.any_open(get_tree()) \
			or TransitionOverlay.any_active(get_tree()) \
			or CombatManager.any_active(get_tree()) \
			or AvatarPanel.any_open(get_tree()):
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

## True when any DisciplinePanel in the tree is open. Player movement
## and world interaction check this to stay disabled while it's up.
static func any_open(tree: SceneTree) -> bool:
	if tree == null:
		return false
	for node in tree.get_nodes_in_group(&"discipline_panels"):
		var panel := node as DisciplinePanel
		if panel != null and panel.panel_open:
			return true
	return false

# ------------------------------------------------------------------
# Content
# ------------------------------------------------------------------

func _progression() -> CharacterProgression:
	return CharacterProgression.find(get_tree())

func _rebuild() -> void:
	for child in _ability_box.get_children():
		child.queue_free()
	var progression := _progression()
	_hint_label.text = "[K] close · click an ability to equip/unequip"
	if progression == null:
		_header_label.text = "Discipline"
		_add_info_row("No character progression found.")
		return
	var info := AbilityCatalog.discipline_info(progression.main_discipline)
	_header_label.text = "%s — level %d" % [
		String(info.get("display_name", progression.main_discipline)),
		progression.level]
	for ability_id in AbilityCatalog.all_ability_ids():
		_ability_box.add_child(_make_ability_row(ability_id, progression))

func _make_ability_row(ability_id: StringName, progression: CharacterProgression) -> Control:
	var def := AbilityCatalog.ability(ability_id)
	var unlocked := progression.is_unlocked(ability_id)
	var passive := StringName(def.get("kind", &"")) == &"passive"
	var equippable := unlocked and not passive

	var row := PanelContainer.new()
	row.custom_minimum_size = Vector2(0.0, 44.0)
	row.mouse_filter = Control.MOUSE_FILTER_PASS
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.16, 0.15, 0.2, 0.9) if unlocked \
		else Color(0.1, 0.1, 0.12, 0.85)
	style.border_color = Color(0.35, 0.32, 0.45)
	style.set_border_width_all(1)
	style.set_corner_radius_all(3)
	style.content_margin_left = 6.0
	style.content_margin_right = 6.0
	style.content_margin_top = 4.0
	style.content_margin_bottom = 4.0
	row.add_theme_stylebox_override(&"panel", style)

	var margin := MarginContainer.new()
	margin.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(margin)
	var hbox := HBoxContainer.new()
	hbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hbox.add_theme_constant_override(&"separation", 8)
	margin.add_child(hbox)

	var labels := VBoxContainer.new()
	labels.mouse_filter = Control.MOUSE_FILTER_IGNORE
	labels.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hbox.add_child(labels)

	var name_label := Label.new()
	name_label.text = String(def.get("display_name", ability_id))
	PixelUi.style_label(name_label,
		PixelUi.TEXT_COLOR if unlocked else PixelUi.TEXT_DIM, 11)
	name_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	labels.add_child(name_label)

	var detail := Label.new()
	detail.text = _detail_text(def, unlocked)
	PixelUi.style_label(detail, PixelUi.TEXT_DIM, 9, true)
	detail.mouse_filter = Control.MOUSE_FILTER_IGNORE
	labels.add_child(detail)

	var state_label := Label.new()
	state_label.custom_minimum_size = Vector2(86.0, 0.0)
	state_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	state_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	state_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if passive and unlocked:
		state_label.text = "passive"
		PixelUi.style_label(state_label, PixelUi.TEXT_COLOR, 9, true)
	elif equippable and progression.is_equipped(ability_id):
		state_label.text = "equipped"
		PixelUi.style_label(state_label, Color(0.55, 0.9, 0.55), 9, true)
	elif equippable:
		state_label.text = "unequipped"
		PixelUi.style_label(state_label, PixelUi.TEXT_DIM, 9, true)
	elif not unlocked:
		state_label.text = "lvl %d" % int(def.get("unlock_level", 0))
		PixelUi.style_label(state_label, PixelUi.TEXT_DIM, 9, true)
	else:
		state_label.text = ""
		hbox.add_child(state_label)

	if equippable:
		row.gui_input.connect(_on_row_input.bind(ability_id, progression))
		row.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	return row

func _detail_text(def: Dictionary, unlocked: bool) -> String:
	var kind := String(def.get("kind", ""))
	if not unlocked:
		return "Locked — unlocks at level %d" % int(def.get("unlock_level", 0))
	var parts: Array[String] = []
	match kind:
		"active":
			parts.append("Active")
		"passive":
			parts.append("Passive")
		"ultimate":
			parts.append("Ultimate")
	var damage := int(def.get("damage", 0))
	if damage > 0:
		parts.append("%d dmg" % damage)
	var ability_range := int(def.get("range", 0))
	if ability_range > 0:
		parts.append("range %d" % ability_range)
	if bool(def.get("ends_turn", false)):
		parts.append("ends turn")
	if bool(def.get("self_damage", false)):
		parts.append("self damage")
	var max_uses := int(def.get("max_uses", 0))
	if max_uses > 0:
		parts.append("%d use/encounter" % max_uses)
	if String(def.get("description", "")) != "":
		parts.append(String(def["description"]))
	return " · ".join(parts)

func _on_row_input(event: InputEvent, ability_id: StringName,
		progression: CharacterProgression) -> void:
	if not (event is InputEventMouseButton):
		return
	var click := event as InputEventMouseButton
	if not click.pressed or click.button_index != MOUSE_BUTTON_LEFT:
		return
	if progression.is_equipped(ability_id):
		if progression.unequip(ability_id):
			_set_status("Unequipped %s." % _ability_name(ability_id), false)
	elif progression.equip(ability_id):
		_set_status("Equipped %s." % _ability_name(ability_id), false)
	_rebuild()

func _ability_name(ability_id: StringName) -> String:
	return String(AbilityCatalog.ability(ability_id).get("display_name", ability_id))

func _add_info_row(text: String) -> void:
	var label := Label.new()
	label.text = text
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	PixelUi.style_label(label, PixelUi.TEXT_DIM, 10, true)
	_ability_box.add_child(label)

func _set_status(text: String, is_error: bool) -> void:
	_status_label.text = text
	_status_label.add_theme_color_override(&"font_color",
		Color(1.0, 0.55, 0.5) if is_error else PixelUi.TEXT_DIM)

# ------------------------------------------------------------------
# UI construction (code-built, matching AvatarPanel/FloorPanel)
# ------------------------------------------------------------------

func _build_ui() -> void:
	_root = PanelContainer.new()
	_root.name = "DisciplinePanelRoot"
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

	_header_label = Label.new()
	_header_label.text = "Discipline"
	PixelUi.style_label(_header_label, PixelUi.TEXT_COLOR, 12, true)
	vbox.add_child(_header_label)

	_hint_label = Label.new()
	_hint_label.text = "[K] close"
	PixelUi.style_label(_hint_label, PixelUi.TEXT_DIM, 9, true)
	vbox.add_child(_hint_label)

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	vbox.add_child(scroll)
	_ability_box = VBoxContainer.new()
	_ability_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_ability_box.add_theme_constant_override(&"separation", 4)
	scroll.add_child(_ability_box)

	_status_label = Label.new()
	_status_label.text = ""
	PixelUi.style_label(_status_label, PixelUi.TEXT_DIM, 9)
	vbox.add_child(_status_label)
