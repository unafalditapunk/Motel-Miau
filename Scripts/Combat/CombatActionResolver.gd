class_name CombatActionResolver
extends RefCounted

## The only place combat actions are validated and applied. All rules
## for movement and the basic attack live here; Combatant stays pure
## state and CombatSession stays lifecycle/turn state.
##
## Model A economy: one move (up to move_budget cells) and one Act per
## turn, independent of each other. The Act is consumed only by a
## successful attack; movement never consumes it.
##
## Action results are Dictionaries with stable StringName reason codes
## (no UI strings):
##   { ok, reason, action, actor_id, target_id, ...payload }

const ATTACK_DAMAGE := 2
const ATTACK_RANGE := 1

var _session: CombatSession

func setup(session: CombatSession) -> void:
	_session = session

# ------------------------------------------------------------------
# Movement
# ------------------------------------------------------------------

## Tactical move for the acting combatant. The destination must appear
## in CombatGrid's reachable set with every OTHER combatant's cell
## passed as extra_blocked — combatant occupancy never touches
## BlockLayer.
func move(actor_id: StringName, dest: Vector2i) -> Dictionary:
	var actor := _combatant(actor_id)
	if actor == null:
		return _fail(&"unknown_combatant", &"move", actor_id)
	var gate := _turn_gate(actor, &"move")
	if not gate.is_empty():
		return gate
	if actor.move_used:
		return _fail(&"move_used", &"move", actor_id)
	var blocked: Array[Vector2i] = []
	for cell in _session.occupied_cells():
		var occupant := _session.combatant_at(cell)
		if occupant != null and occupant != actor:
			blocked.append(cell)
	var reachable := _session.combat_grid.get_reachable_cells(
		actor.cell, actor.elevation, actor.move_budget,
		actor.height, actor.max_step_height, blocked)
	if not reachable.has(dest):
		return _fail(&"unreachable", &"move", actor_id)
	var cost: int = reachable[dest]
	_session.move_combatant_to(actor, dest, cost)
	actor.move_used = true
	return _ok(&"move", actor_id, &"", {
		"cell": dest, "elevation": actor.elevation, "cost": cost})

# ------------------------------------------------------------------
# Basic attack
# ------------------------------------------------------------------

## Basic attack: Chebyshev range 1, requires LOS, 2 damage, consumes
## the Act only on success.
func attack(actor_id: StringName, target_id: StringName) -> Dictionary:
	var actor := _combatant(actor_id)
	if actor == null:
		return _fail(&"unknown_combatant", &"attack", actor_id)
	var gate := _turn_gate(actor, &"attack")
	if not gate.is_empty():
		return gate
	if actor.act_used:
		return _fail(&"act_used", &"attack", actor_id)
	var target := _session.get_combatant(target_id)
	if target == null:
		return _fail(&"unknown_target", &"attack", actor_id, target_id)
	if not target.is_alive():
		return _fail(&"target_defeated", &"attack", actor_id, target_id)
	if target.team == actor.team:
		return _fail(&"same_team", &"attack", actor_id, target_id)
	if CombatGrid.get_distance(actor.cell, target.cell) != ATTACK_RANGE:
		return _fail(&"out_of_range", &"attack", actor_id, target_id)
	var grid := _session.combat_grid
	if not grid.has_line_of_sight(actor.cell, actor.elevation, actor.height,
			target.cell, target.elevation, target.height):
		return _fail(&"no_los", &"attack", actor_id, target_id)
	var damage := target.apply_damage(ATTACK_DAMAGE)
	actor.act_used = true
	_session.on_attack_resolved(actor, target, damage)
	return _ok(&"attack", actor_id, target_id, {
		"damage": damage, "target_hp": target.hp,
		"target_defeated": not target.is_alive()})

# ------------------------------------------------------------------
# Internals
# ------------------------------------------------------------------

func _combatant(combatant_id: StringName) -> Combatant:
	if _session == null:
		return null
	return _session.get_combatant(combatant_id)

## Shared gate: session active, actor alive, actor's turn. Returns an
## empty Dictionary when the action may proceed.
func _turn_gate(actor: Combatant, action: StringName) -> Dictionary:
	if _session == null or _session.state != CombatSession.State.ACTIVE:
		return _fail(&"not_active", action, actor.id if actor != null else &"")
	if not actor.is_alive():
		return _fail(&"actor_defeated", action, actor.id)
	if not _session.is_turn(actor.id):
		return _fail(&"out_of_turn", action, actor.id)
	return {}

func _ok(action: StringName, actor_id: StringName, target_id: StringName,
		extra: Dictionary = {}) -> Dictionary:
	var result := {
		"ok": true, "reason": &"", "action": action,
		"actor_id": actor_id, "target_id": target_id}
	for key in extra:
		result[key] = extra[key]
	return result

func _fail(reason: StringName, action: StringName, actor_id: StringName,
		target_id: StringName = &"") -> Dictionary:
	return {
		"ok": false, "reason": reason, "action": action,
		"actor_id": actor_id, "target_id": target_id}
