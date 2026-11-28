class_name CombatUI
extends CanvasLayer

## Minimal combat interface for the first playable encounter. Screen
## space: a bottom panel with round/turn/HP and the Move / Attack /
## End Turn buttons, plus a floating interaction prompt over the
## enemy. All actions route through CombatManager, which routes them
## through CombatActionResolver — the UI never mutates combat state.

enum TargetMode { IDLE, MOVE, ATTACK }

const RESULT_SECONDS := 1.4

var manager: CombatManager
var target_mode := TargetMode.IDLE
## Ability armed for ATTACK-mode click targeting; &"" = basic attack.
var armed_ability: StringName = &""

var _panel: PanelContainer
var _title: Label
var _hp: Label
var _status: Label
var _result: Label
var _move_btn: Button
var _attack_btn: Button
var _end_btn: Button
var _ability_box: HFlowContainer
var _effects: Label
var _prompt: Label
var _result_left := 0.0

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

	_panel = PanelContainer.new()
	_panel.anchor_left = 0.5
	_panel.anchor_right = 0.5
	_panel.anchor_top = 1.0
	_panel.anchor_bottom = 1.0
	_panel.offset_left = -150.0
	_panel.offset_right = 150.0
	_panel.offset_top = -196.0
	_panel.offset_bottom = -14.0
	_panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_panel.grow_vertical = Control.GROW_DIRECTION_BEGIN
	PixelUi.style_panel(_panel)
	_panel.visible = false
	add_child(_panel)

	var margin := MarginContainer.new()
	for side in [&"margin_left", &"margin_right", &"margin_top", &"margin_bottom"]:
		margin.add_theme_constant_override(side, 10)
	_panel.add_child(margin)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 6)
	margin.add_child(box)

	_title = Label.new()
	PixelUi.style_label(_title, PixelUi.TEXT_COLOR, 10, true)
	box.add_child(_title)

	_hp = Label.new()
	PixelUi.style_label(_hp, PixelUi.TEXT_COLOR, 10, true)
	box.add_child(_hp)

	var btn_row := CenterContainer.new()
	box.add_child(btn_row)
	var btns := HBoxContainer.new()
	btns.add_theme_constant_override("separation", 8)
	btn_row.add_child(btns)

	_move_btn = Button.new()
	_move_btn.text = "Move"
	PixelUi.style_button(_move_btn, true)
	_move_btn.pressed.connect(func() -> void:
		if manager != null:
			manager.select_move_mode())
	btns.add_child(_move_btn)

	_attack_btn = Button.new()
	_attack_btn.text = "Attack"
	PixelUi.style_button(_attack_btn, true)
	_attack_btn.pressed.connect(func() -> void:
		if manager != null:
			manager.select_attack_mode())
	btns.add_child(_attack_btn)

	_end_btn = Button.new()
	_end_btn.text = "End Turn"
	PixelUi.style_button(_end_btn, true)
	_end_btn.pressed.connect(func() -> void:
		if manager != null:
			manager.player_end_turn())
	btns.add_child(_end_btn)

	# Equipped discipline abilities — rebuilt by refresh() from the
	# player's per-encounter skillset.
	_ability_box = HFlowContainer.new()
	_ability_box.add_theme_constant_override("h_separation", 6)
	_ability_box.add_theme_constant_override("v_separation", 4)
	box.add_child(_ability_box)

	_effects = Label.new()
	PixelUi.style_label(_effects, PixelUi.TEXT_DIM, 8, true)
	box.add_child(_effects)

	_status = Label.new()
	PixelUi.style_label(_status, PixelUi.TEXT_DIM, 8, true)
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(_status)

	_result = Label.new()
	_result.anchor_left = 0.5
	_result.anchor_right = 0.5
	_result.anchor_top = 1.0
	_result.anchor_bottom = 1.0
	_result.offset_left = -160.0
	_result.offset_right = 160.0
	_result.offset_top = -190.0
	_result.offset_bottom = -120.0
	_result.grow_horizontal = Control.GROW_DIRECTION_BOTH
	PixelUi.style_label(_result, Color(1.0, 0.85, 0.4), 16, true)
	_result.visible = false
	add_child(_result)

# ------------------------------------------------------------------
# Session-facing API (called by CombatManager)
# ------------------------------------------------------------------

func begin() -> void:
	target_mode = TargetMode.IDLE
	_status.text = ""
	_result.visible = false
	_result_left = 0.0
	_panel.visible = true
	refresh()

func hide_ui() -> void:
	_panel.visible = false
	_prompt.visible = false
	_result.visible = false
	_result_left = 0.0
	target_mode = TargetMode.IDLE

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
	_attack_btn.disabled = not my_turn or busy or (pc != null and pc.act_used)
	_attack_btn.text = "Attack" if armed_ability == &"" \
		else _ability_label(armed_ability)
	_end_btn.disabled = not my_turn or busy
	_refresh_ability_buttons(my_turn, busy, pc)
	_refresh_effects()
	manager.refresh_highlights()

func set_status(text: String) -> void:
	_status.text = text

func set_target_mode(mode: TargetMode) -> void:
	target_mode = mode
	if mode != TargetMode.ATTACK:
		armed_ability = &""
	refresh()

func _ability_label(ability_id: StringName) -> String:
	return String(AbilityCatalog.ability(ability_id).get("display_name", ability_id))

## Rebuilds the equipped-ability buttons from the player's skillset.
## Buttons stay clickable whenever it's the player's action window so
## invalid uses surface a reason in the status line; only hard states
## (not your turn, mid-walk, act spent, uses exhausted) disable them.
func _refresh_ability_buttons(my_turn: bool, busy: bool, pc: Combatant) -> void:
	for child in _ability_box.get_children():
		child.queue_free()
	if manager == null:
		return
	var skillset := manager.player_skillset()
	for ability_id in manager.player_ability_ids():
		var def := AbilityCatalog.ability(ability_id)
		var button := Button.new()
		button.text = _ability_label(ability_id)
		var uses_left := -1
		if skillset != null and not skillset.is_unlimited(ability_id):
			uses_left = skillset.uses_remaining(ability_id)
		if uses_left == 0:
			button.text += " (0)"
		button.tooltip_text = String(def.get("description", ""))
		PixelUi.style_button(button, true)
		PixelUi.nearest(button)
		button.disabled = not my_turn or busy \
			or (pc != null and pc.act_used) or uses_left == 0
		var aid: StringName = ability_id
		button.pressed.connect(func() -> void: _on_ability_pressed(aid))
		_ability_box.add_child(button)

func _on_ability_pressed(ability_id: StringName) -> void:
	if manager == null:
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
