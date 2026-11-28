class_name CombatUI
extends CanvasLayer

## Combat interface: a Minecraft-style ability hotbar centered at the
## bottom of the screen, plus a compact information panel anchored
## bottom-right (round/turn, HP, Move / End Turn, status, effects).
## All actions route through CombatManager, which routes them through
## CombatActionResolver — the UI never mutates combat state.
##
## Hotbar: one square slot per EQUIPPED ability (order = the
## skillset's available list). Number keys 1-9 and left-click select
## a slot; ranged abilities arm ATTACK-mode targeting, self/no-range
## abilities (Somnolencia) resolve immediately. The selected slot
## keeps its highlight until another selection, a successful
## resolution, or Escape cancels targeting.

enum TargetMode { IDLE, MOVE, ATTACK }

## Hotbar slot button: a plain Button plus the ability it fronts, so
## the custom tooltip override can build the structured hover panel.
class AbilitySlotButton extends Button:
	var ability_id: StringName = &""
	var ui: CombatUI

	func _make_custom_tooltip(_for_text: String) -> Control:
		if ui != null:
			return ui._slot_tooltip_node(ability_id)
		return null

const RESULT_SECONDS := 1.4
const SLOT_SIZE := 28.0
const SLOT_GAP := 4.0
const SLOT_FONT_SIZE := 8
const SLOT_ICON_SIZE := 16.0
## Number keys map to hotbar slots: KEY_1 -> slot 0, etc.
const FIRST_SLOT_KEY := KEY_1

var manager: CombatManager
var target_mode := TargetMode.IDLE
## Ability armed for ATTACK-mode click targeting; &"" = none.
var armed_ability: StringName = &""

var _panel: PanelContainer
var _title: Label
var _hp: Label
var _status: Label
var _result: Label
var _move_btn: Button
var _end_btn: Button
var _effects: Label
var _prompt: Label
var _result_left := 0.0
## Hotbar slots, parallel to _slot_ids. Built once per encounter in
## begin() — the equipped set cannot change mid-fight.
var _hotbar: PanelContainer
var _slot_box: HBoxContainer
var _slot_ids: Array[StringName] = []
var _slot_buttons: Array[Button] = []
var _slot_icons: Array[TextureRect] = []
var _slot_numbers: Array[Label] = []
var _slot_uses: Array[Label] = []

func _ready() -> void:
	layer = 5
	_build()

func bind(combat_manager: CombatManager) -> void:
	manager = combat_manager

func _build() -> void:
	_prompt = Label.new()
	_prompt.visible = false
	PixelUi.style_label(_prompt, Color(1.0, 0.9, 0.6), 10, true)
	add_child(_prompt)

	# ------------------------------------------------------------------
	# Combat information panel — bottom-right, compact.
	# ------------------------------------------------------------------
	_panel = PanelContainer.new()
	_panel.anchor_left = 1.0
	_panel.anchor_right = 1.0
	_panel.anchor_top = 1.0
	_panel.anchor_bottom = 1.0
	_panel.offset_left = -204.0
	_panel.offset_right = -8.0
	_panel.offset_top = -104.0
	_panel.offset_bottom = -8.0
	_panel.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	_panel.grow_vertical = Control.GROW_DIRECTION_BEGIN
	PixelUi.style_panel(_panel)
	_panel.visible = false
	add_child(_panel)

	var margin := MarginContainer.new()
	for side in [&"margin_left", &"margin_right", &"margin_top", &"margin_bottom"]:
		margin.add_theme_constant_override(side, 8)
	_panel.add_child(margin)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 4)
	margin.add_child(box)

	_title = Label.new()
	PixelUi.style_label(_title, PixelUi.TEXT_COLOR, 10, true)
	box.add_child(_title)

	_hp = Label.new()
	PixelUi.style_label(_hp, PixelUi.TEXT_COLOR, 10, true)
	box.add_child(_hp)

	var btn_row := HBoxContainer.new()
	btn_row.add_theme_constant_override("separation", 6)
	box.add_child(btn_row)

	_move_btn = Button.new()
	_move_btn.text = "Move"
	PixelUi.style_button(_move_btn, true)
	_move_btn.pressed.connect(func() -> void:
		if manager != null:
			manager.select_move_mode())
	btn_row.add_child(_move_btn)

	_end_btn = Button.new()
	_end_btn.text = "End Turn"
	PixelUi.style_button(_end_btn, true)
	_end_btn.pressed.connect(func() -> void:
		if manager != null:
			manager.player_end_turn())
	btn_row.add_child(_end_btn)

	_effects = Label.new()
	PixelUi.style_label(_effects, PixelUi.TEXT_DIM, 8, true)
	box.add_child(_effects)

	_status = Label.new()
	PixelUi.style_label(_status, PixelUi.TEXT_DIM, 8, true)
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(_status)

	# ------------------------------------------------------------------
	# Ability hotbar — bottom-center. A full-width bottom strip holds a
	# CenterContainer so the panel hugs its slots and stays centered at
	# any slot count or viewport width.
	# ------------------------------------------------------------------
	var hotbar_strip := CenterContainer.new()
	hotbar_strip.anchor_left = 0.0
	hotbar_strip.anchor_right = 1.0
	hotbar_strip.anchor_top = 1.0
	hotbar_strip.anchor_bottom = 1.0
	hotbar_strip.offset_left = 0.0
	hotbar_strip.offset_right = 0.0
	hotbar_strip.offset_top = -46.0
	hotbar_strip.offset_bottom = -8.0
	hotbar_strip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(hotbar_strip)

	_hotbar = PanelContainer.new()
	_hotbar.mouse_filter = Control.MOUSE_FILTER_STOP
	var hotbar_style := PixelUi.make_panel_stylebox(
		Color(0.07, 0.07, 0.11, 0.82), Color(0.4, 0.38, 0.5, 0.9))
	hotbar_style.content_margin_left = 4.0
	hotbar_style.content_margin_right = 4.0
	hotbar_style.content_margin_top = 3.0
	hotbar_style.content_margin_bottom = 3.0
	_hotbar.add_theme_stylebox_override(&"panel", hotbar_style)
	_hotbar.visible = false
	hotbar_strip.add_child(_hotbar)

	var hotbar_margin := MarginContainer.new()
	hotbar_margin.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_hotbar.add_child(hotbar_margin)

	_slot_box = HBoxContainer.new()
	_slot_box.add_theme_constant_override("separation", int(SLOT_GAP))
	hotbar_margin.add_child(_slot_box)

	_result = Label.new()
	_result.anchor_left = 0.5
	_result.anchor_right = 0.5
	_result.anchor_top = 1.0
	_result.anchor_bottom = 1.0
	_result.offset_left = -160.0
	_result.offset_right = 160.0
	_result.offset_top = -150.0
	_result.offset_bottom = -80.0
	_result.grow_horizontal = Control.GROW_DIRECTION_BOTH
	PixelUi.style_label(_result, Color(1.0, 0.85, 0.4), 16, true)
	_result.visible = false
	add_child(_result)

# ------------------------------------------------------------------
# Session-facing API (called by CombatManager)
# ------------------------------------------------------------------

func begin() -> void:
	target_mode = TargetMode.IDLE
	armed_ability = &""
	_status.text = ""
	_result.visible = false
	_result_left = 0.0
	_build_slots()
	_panel.visible = true
	_hotbar.visible = true
	refresh()

func hide_ui() -> void:
	_panel.visible = false
	_hotbar.visible = false
	_prompt.visible = false
	_result.visible = false
	_result_left = 0.0
	target_mode = TargetMode.IDLE
	armed_ability = &""

func is_combat_visible() -> bool:
	return _panel != null and _panel.visible

func refresh() -> void:
	if manager == null or manager.session == null:
		return
	var session := manager.session
	var current := session.current_combatant()
	_title.text = "Round %d — %s" % [
		session.round_number, current.display_name if current != null else "?"]
	var pc := manager.player_combatant()
	var ec := manager.enemy_combatant()
	if pc != null and ec != null:
		_hp.text = "You %d/%d    %s %d/%d" % [
			pc.hp, pc.max_hp, ec.display_name, ec.hp, ec.max_hp]
	var busy: bool = manager.player_visual_busy()
	var my_turn := session.state == CombatSession.State.ACTIVE \
		and current != null and current.id == CombatManager.PLAYER_ID
	_move_btn.disabled = not my_turn or busy or (pc != null and pc.move_used)
	_end_btn.disabled = not my_turn or busy
	_refresh_slot_states(my_turn, busy, pc)
	_refresh_effects()
	manager.refresh_highlights()

func set_status(text: String) -> void:
	_status.text = text

func set_target_mode(mode: TargetMode) -> void:
	target_mode = mode
	# Only ATTACK-mode click targeting keeps an armed ability; MOVE
	# and IDLE release it so the slot highlight clears.
	if mode != TargetMode.ATTACK:
		armed_ability = &""
	refresh()

func _ability_label(ability_id: StringName) -> String:
	return String(AbilityCatalog.ability(ability_id).get("display_name", ability_id))

# ------------------------------------------------------------------
# Hotbar slots
# ------------------------------------------------------------------

## (Re)builds the slot row from the player's equipped abilities.
## Called once per encounter — equipment cannot change mid-fight.
func _build_slots() -> void:
	for child in _slot_box.get_children():
		child.queue_free()
	_slot_ids.clear()
	_slot_buttons.clear()
	_slot_icons.clear()
	_slot_numbers.clear()
	_slot_uses.clear()
	if manager == null:
		return
	for ability_id in manager.player_ability_ids():
		_slot_ids.append(ability_id)
		_slot_box.add_child(_make_slot(ability_id, _slot_ids.size()))

func _make_slot(ability_id: StringName, index: int) -> Button:
	var button := AbilitySlotButton.new()
	button.ability_id = ability_id
	button.ui = self
	button.custom_minimum_size = Vector2(SLOT_SIZE, SLOT_SIZE)
	button.focus_mode = Control.FOCUS_NONE
	button.clip_contents = true
	# Square, flat, pixel-style slot chrome — swapped per state in
	# _refresh_slot_states.
	button.add_theme_stylebox_override(&"normal", _slot_style(false))
	button.add_theme_stylebox_override(&"hover", _slot_style(false, true))
	button.add_theme_stylebox_override(&"pressed", _slot_style(false))
	button.add_theme_stylebox_override(&"hover_pressed", _slot_style(false, true))
	button.add_theme_stylebox_override(&"disabled", _slot_style(true))
	button.add_theme_stylebox_override(&"focus", StyleBoxEmpty.new())
	PixelUi.nearest(button)

	var icon := TextureRect.new()
	icon.texture = PixelUi.placeholder_icon(ability_id)
	icon.custom_minimum_size = Vector2(SLOT_ICON_SIZE, SLOT_ICON_SIZE)
	icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	icon.set_anchors_preset(Control.PRESET_CENTER)
	icon.offset_left = -SLOT_ICON_SIZE * 0.5
	icon.offset_top = -SLOT_ICON_SIZE * 0.5 - 2.0
	icon.offset_right = SLOT_ICON_SIZE * 0.5
	icon.offset_bottom = SLOT_ICON_SIZE * 0.5 - 2.0
	PixelUi.nearest(icon)
	button.add_child(icon)
	_slot_icons.append(icon)

	var number := Label.new()
	number.text = str(index)
	PixelUi.style_label(number, PixelUi.TEXT_DIM, SLOT_FONT_SIZE)
	number.mouse_filter = Control.MOUSE_FILTER_IGNORE
	number.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	number.offset_left = 2.0
	number.offset_top = -11.0
	number.offset_right = 14.0
	number.offset_bottom = -2.0
	button.add_child(number)
	_slot_numbers.append(number)

	var uses := Label.new()
	uses.text = ""
	PixelUi.style_label(uses, Color(1.0, 0.85, 0.4), SLOT_FONT_SIZE)
	uses.mouse_filter = Control.MOUSE_FILTER_IGNORE
	uses.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	uses.offset_left = -14.0
	uses.offset_top = -11.0
	uses.offset_right = -2.0
	uses.offset_bottom = -2.0
	uses.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	button.add_child(uses)
	_slot_uses.append(uses)

	button.tooltip_text = _slot_tooltip_text(ability_id)
	var aid: StringName = ability_id
	button.pressed.connect(func() -> void: _on_slot_pressed(aid))
	_slot_buttons.append(button)
	return button

## Square slot stylebox. selected = bright border (armed for
## targeting); dimmed = desaturated for hard-unavailable states.
func _slot_style(dimmed: bool, hovered := false) -> StyleBoxFlat:
	var bg := Color(0.13, 0.12, 0.18, 0.9) if not dimmed \
		else Color(0.08, 0.08, 0.11, 0.75)
	if hovered and not dimmed:
		bg = bg.lightened(0.15)
	var border := Color(0.55, 0.5, 0.4, 0.85) if not dimmed \
		else Color(0.3, 0.28, 0.35, 0.6)
	var style := StyleBoxFlat.new()
	style.bg_color = bg
	style.border_color = border
	style.set_border_width_all(1)
	style.set_corner_radius_all(0)
	style.anti_aliasing = false
	style.content_margin_left = 2.0
	style.content_margin_right = 2.0
	style.content_margin_top = 2.0
	style.content_margin_bottom = 2.0
	return style

func _slot_style_selected() -> StyleBoxFlat:
	var style := _slot_style(false)
	style.border_color = Color(1.0, 0.85, 0.4, 1.0)
	style.set_border_width_all(2)
	return style

## Live per-frame slot state: selection highlight, uses badge, and
## disabled visuals. Selection survives across turns like a hotbar;
## hard states (not your turn, mid-walk, act spent, no uses) dim.
func _refresh_slot_states(my_turn: bool, busy: bool, pc: Combatant) -> void:
	var skillset := manager.player_skillset() if manager != null else null
	for i in _slot_ids.size():
		var ability_id := _slot_ids[i]
		var button := _slot_buttons[i]
		var selected := armed_ability == ability_id
		var uses_left := -1
		if skillset != null and not skillset.is_unlimited(ability_id):
			uses_left = skillset.uses_remaining(ability_id)
		var unusable := not my_turn or busy \
			or (pc != null and pc.act_used) or uses_left == 0
		button.disabled = unusable
		# Selected state wins over the disabled dim — the highlight
		# shows WHAT is armed even when it can't fire right now.
		button.add_theme_stylebox_override(&"normal",
			_slot_style_selected() if selected else _slot_style(unusable))
		button.add_theme_stylebox_override(&"hover",
			_slot_style_selected() if selected else _slot_style(unusable, true))
		button.add_theme_stylebox_override(&"disabled",
			_slot_style_selected() if selected else _slot_style(true))
		_slot_uses[i].text = str(uses_left) if uses_left >= 0 else ""
		_slot_uses[i].visible = uses_left >= 0

## Compact structured tooltip: name, damage, range, description and
## a live usability line — all read from AbilityCatalog + skillset.
func _slot_tooltip_text(ability_id: StringName) -> String:
	# Godot shows make_custom_tooltip's return INSTEAD of tooltip_text;
	# this stays as a fallback for headless/no-tooltip contexts.
	var def := AbilityCatalog.ability(ability_id)
	var parts: Array[String] = [String(def.get("display_name", ability_id))]
	var damage := int(def.get("damage", 0))
	if damage > 0:
		parts.append("Damage: %d" % damage)
	var ability_range := int(def.get("range", 0))
	if ability_range > 0:
		parts.append("Range: %d cell%s" % [ability_range, "s" if ability_range != 1 else ""])
	if bool(def.get("self_damage", false)):
		parts.append("Self damage: %d" % int(def["self_damage"]))
	if bool(def.get("ends_turn", false)):
		parts.append("Ends your turn")
	parts.append(String(def.get("description", "")))
	return "\n".join(parts)

## Custom tooltip control built per hover by AbilitySlotButton.
func _slot_tooltip_node(ability_id: StringName) -> Control:
	var def := AbilityCatalog.ability(ability_id)
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override(&"panel",
		PixelUi.make_panel_stylebox(Color(0.08, 0.08, 0.13, 0.96)))
	var margin := MarginContainer.new()
	for side in [&"margin_left", &"margin_right", &"margin_top", &"margin_bottom"]:
		margin.add_theme_constant_override(side, 5)
	panel.add_child(margin)
	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 2)
	margin.add_child(vbox)

	var name_label := Label.new()
	name_label.text = String(def.get("display_name", ability_id))
	PixelUi.style_label(name_label, PixelUi.TEXT_COLOR, 10, true)
	vbox.add_child(name_label)

	var damage := int(def.get("damage", 0))
	if damage > 0:
		_add_tooltip_line(vbox, "Damage: %d" % damage)
	var ability_range := int(def.get("range", 0))
	if ability_range > 0:
		_add_tooltip_line(vbox, "Range: %d cell%s" % [
			ability_range, "s" if ability_range != 1 else ""])
	if bool(def.get("self_damage", false)):
		_add_tooltip_line(vbox, "Self damage: %d" % int(def["self_damage"]))
	if bool(def.get("ends_turn", false)):
		_add_tooltip_line(vbox, "Ends your turn")
	var desc := String(def.get("description", ""))
	if desc != "":
		_add_tooltip_line(vbox, desc, PixelUi.TEXT_DIM)
	_add_tooltip_line(vbox, _slot_usability_text(ability_id),
		Color(0.55, 0.9, 0.55) if _slot_usable_now(ability_id) else Color(1.0, 0.6, 0.5))
	return panel

func _add_tooltip_line(vbox: VBoxContainer, text: String,
		color: Color = PixelUi.TEXT_COLOR) -> void:
	var label := Label.new()
	label.text = text
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	PixelUi.style_label(label, color, 8)
	vbox.add_child(label)

## Live usability for tooltip/status text — mirrors the slot's
## disabled conditions without touching combat state.
func _slot_usable_now(ability_id: StringName) -> bool:
	if manager == null or manager.session == null:
		return false
	var session := manager.session
	var current := session.current_combatant()
	if session.state != CombatSession.State.ACTIVE or current == null \
			or current.id != CombatManager.PLAYER_ID:
		return false
	var pc := manager.player_combatant()
	if pc != null and (pc.act_used or manager.player_visual_busy()):
		return false
	var skillset := manager.player_skillset()
	if skillset != null and not skillset.is_unlimited(ability_id) \
			and skillset.uses_remaining(ability_id) <= 0:
		return false
	return true

func _slot_unusable_reason(ability_id: StringName) -> StringName:
	if manager == null or manager.session == null:
		return &"not_active"
	var session := manager.session
	var current := session.current_combatant()
	if session.state != CombatSession.State.ACTIVE:
		return &"not_active"
	if current == null or current.id != CombatManager.PLAYER_ID:
		return &"out_of_turn"
	var pc := manager.player_combatant()
	if pc != null and pc.act_used:
		return &"act_used"
	if manager.player_visual_busy():
		return &"moving"
	var skillset := manager.player_skillset()
	if skillset != null and not skillset.is_unlimited(ability_id) \
			and skillset.uses_remaining(ability_id) <= 0:
		return &"no_uses"
	return &""

func _slot_usability_text(ability_id: StringName) -> String:
	var reason := _slot_unusable_reason(ability_id)
	if reason == &"":
		return "Ready"
	return format_reason(reason)

func _on_slot_pressed(ability_id: StringName) -> void:
	_activate_slot(ability_id)

## Shared slot activation for clicks and number keys: hard-unusable
## states surface a reason; usable abilities arm targeting or resolve
## immediately (self/no-range), exactly like the old button row.
func _activate_slot(ability_id: StringName) -> void:
	if manager == null:
		return
	var reason := _slot_unusable_reason(ability_id)
	if reason != &"":
		set_status(format_reason(reason))
		return
	var def := AbilityCatalog.ability(ability_id)
	var ability_range := int(def.get("range", 0))
	if ability_range <= 0 or bool(def.get("ends_turn", false)) \
			or StringName(def.get("kind", &"")) == &"passive":
		# Self/no-target abilities resolve immediately.
		manager.player_use_ability(ability_id)
	else:
		manager.select_ability_mode(ability_id)

## Drowsiness bonus + Hope counter — the encounter's visible temp
## effects. Empty when the player has no skillset.
func _refresh_effects() -> void:
	var skillset := manager.player_skillset() if manager != null else null
	if skillset == null:
		_effects.text = ""
		return
	var parts: Array[String] = []
	if skillset.drowsiness_bonus > 0:
		parts.append("Somnolencia: next attack +%d" % skillset.drowsiness_bonus)
	if skillset.hope_unlocked():
		var done := skillset.turns_completed % CombatSkillset.HOPE_EVERY_TURNS
		parts.append("Esperanza: %d/%d" % [done, CombatSkillset.HOPE_EVERY_TURNS])
	_effects.text = "   ".join(parts)

func format_reason(reason: StringName) -> String:
	match reason:
		&"unreachable":
			return "Can't reach that cell."
		&"move_used":
			return "Already moved this turn."
		&"act_used":
			return "Already acted this turn."
		&"out_of_range":
			return "Target out of range."
		&"no_los":
			return "No line of sight."
		&"same_team":
			return "Can't attack your ally."
		&"target_defeated":
			return "Target is defeated."
		&"out_of_turn":
			return "Not your turn."
		&"not_active":
			return "Combat is not active."
		&"occupied":
			return "Cell is occupied."
		&"moving":
			return "Moving..."
		&"ability_unavailable":
			return "Ability not available."
		&"unknown_ability":
			return "Unknown ability."
		&"no_uses":
			return "No uses left."
		&"effect_pending":
			return "Effect already active."
		&"invalid_target":
			return "No valid target."
		_:
			return String(reason)

## Brief end-of-encounter banner; the combat state is already torn
## down, this is purely cosmetic and self-hides.
func show_result(text: String) -> void:
	_panel.visible = false
	_hotbar.visible = false
	_result.text = text
	_result.visible = true
	_result_left = RESULT_SECONDS

func set_prompt(screen_pos: Vector2, shown: bool) -> void:
	_prompt.visible = shown
	if shown:
		_prompt.text = "E — Enfrentar"
		_prompt.position = screen_pos + Vector2(-34.0, -52.0)

# ------------------------------------------------------------------
# Input
# ------------------------------------------------------------------

func _process(delta: float) -> void:
	if _result_left > 0.0:
		_result_left -= delta
		if _result_left <= 0.0:
			_result.visible = false

func _unhandled_input(event: InputEvent) -> void:
	if not _panel.visible or _result.visible:
		return
	if event is InputEventKey:
		_handle_hotbar_key(event as InputEventKey)
		return
	if target_mode == TargetMode.IDLE:
		return
	if not (event is InputEventMouseButton):
		return
	var mouse_button := event as InputEventMouseButton
	if not mouse_button.pressed or mouse_button.button_index != MOUSE_BUTTON_LEFT:
		return
	var cell := world_cell_at_mouse()
	if manager != null and manager.handle_world_click(cell):
		get_viewport().set_input_as_handled()

## Number keys 1-9 select hotbar slots; Escape cancels armed
## targeting. Digits are unused elsewhere in the game — combat is
## the only context where the panel is visible.
func _handle_hotbar_key(key_event: InputEventKey) -> void:
	if not key_event.pressed or key_event.echo:
		return
	if key_event.keycode == KEY_ESCAPE:
		if target_mode != TargetMode.IDLE:
			set_target_mode(TargetMode.IDLE)
			get_viewport().set_input_as_handled()
		return
	var index := _slot_index_for_key(key_event.keycode)
	if index < 0:
		return
	if index < _slot_ids.size():
		_activate_slot(_slot_ids[index])
		get_viewport().set_input_as_handled()

func _slot_index_for_key(keycode: Key) -> int:
	if keycode < FIRST_SLOT_KEY or keycode > KEY_9:
		return -1
	return int(keycode) - int(FIRST_SLOT_KEY)

## Mouse position -> shared world cell, same canvas-transform trick
## BlockPlacementController uses (screen_to_grid returns world cells;
## room.cell_origin is subtracted only for room-local queries).
func world_cell_at_mouse() -> Vector2i:
	var canvas_pos := get_viewport().get_canvas_transform().affine_inverse() \
		* get_viewport().get_mouse_position()
	var room := manager.player.room if manager != null and manager.player != null else null
	var grid := room.grid if room != null else null
	if grid == null:
		return Vector2i(-9999, -9999)
	return grid.screen_to_grid(canvas_pos)
