class_name Combatant
extends RefCounted

## One participant in a CombatSession: a player or an enemy, identified
## by an arbitrary team StringName so factions are not limited to two
## sides. Pure simulation state — no Node, no sprite, no stats beyond
## what the first combat prototype needs. Visual representation and
## input belong to later phases.
##
## Turn state (act_used / move_used) is per-turn scratch space reset by
## reset_turn() when the combatant's turn begins.

var id: StringName
var display_name := ""
var team: StringName
var cell := Vector2i.ZERO
var elevation := 0.0
var height := 2.0
var max_step_height := 1.0
var move_budget := 4
var max_hp := 0
var hp := 0
var act_used := false
var move_used := false
## Per-encounter abilities/effects (CombatSkillset). Null for enemies
## and fixtures without disciplines — they keep the basic attack.
var skillset: CombatSkillset

func _init(p_id: StringName = &"", p_name: String = "", p_team: StringName = &"",
		p_cell: Vector2i = Vector2i.ZERO, p_max_hp: int = 0,
		p_elevation: float = 0.0, p_height: float = 2.0,
		p_move_budget: int = 4, p_max_step: float = 1.0) -> void:
	id = p_id
	display_name = p_name
	team = p_team
	cell = p_cell
	elevation = p_elevation
	height = p_height
	move_budget = p_move_budget
	max_step_height = p_max_step
	max_hp = p_max_hp
	hp = p_max_hp
	if p_max_hp <= 0:
		push_error("Combatant '%s' created with non-positive max_hp." % p_id)

func is_alive() -> bool:
	return hp > 0

## Applies damage, clamped to remaining HP. Returns the damage actually
## dealt (0 for invalid amounts or a defeated combatant).
func apply_damage(amount: int) -> int:
	if amount <= 0 or not is_alive():
		return 0
	var dealt := mini(amount, hp)
	hp -= dealt
	return dealt

## Applies healing, clamped to max_hp. Returns the HP actually
## restored (0 for invalid amounts or a defeated combatant).
func heal(amount: int) -> int:
	if amount <= 0 or not is_alive():
		return 0
	var restored := mini(amount, max_hp - hp)
	hp += restored
	return restored

## Clears per-turn action flags. Called by CombatSession when this
## combatant's turn begins.
func reset_turn() -> void:
	act_used = false
	move_used = false
