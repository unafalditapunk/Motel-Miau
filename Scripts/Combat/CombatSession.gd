class_name CombatSession
extends RefCounted

## One active encounter: owns its combatants, turn order, round counter,
## encounter state, and the session-level combatant occupancy map
## (world_cell -> Combatant). This occupancy is deliberately separate
## from BlockLayer — world geometry blocks via CombatGrid, combatants
## block each other here.
##
## Turn model (Model A — One Act + One Move): registration order decides
## initiative for now; each living combatant's turn resets its
## act_used/move_used flags. Defeated combatants are skipped during
## advancement; victory is checked after every defeat.
##
## No UI, Player, MultiplayerManager, FloorManager, or save dependencies.

signal encounter_started
signal turn_changed(combatant: Combatant, round: int)
signal round_changed(round: int)
signal combatant_moved(combatant: Combatant, from_cell: Vector2i, to_cell: Vector2i, cost: int)
signal attack_resolved(actor: Combatant, target: Combatant, damage: int, target_hp: int)
signal combatant_defeated(combatant: Combatant)
signal encounter_ended(state: int, end_reason: int, winning_team: StringName)

enum State { SETUP, ACTIVE, VICTORY, DRAW, ENDED }
enum EndReason { NONE, VICTORY, DRAW, CANCELLED }

var combat_grid: CombatGrid
var state: State = State.SETUP
var end_reason: EndReason = EndReason.NONE
var winning_team: StringName = &""
var round_number := 0
var turn_index := -1
var turn_order: Array[Combatant] = []
var combatants: Array[Combatant] = []

var _by_id := {}
var _occupancy := {}

func setup(grid: CombatGrid) -> void:
	combat_grid = grid

func is_ready() -> bool:
	return combat_grid != null and combat_grid.is_ready()

# ------------------------------------------------------------------
# Registration
# ------------------------------------------------------------------

## Adds a combatant during SETUP. Validates unique id, non-empty team,
## positive HP, a standable world cell, and cell exclusivity. On
## success the combatant's elevation is snapped to the cell surface so
## LOS/attack heights stay consistent with its footing.
func add_combatant(combatant: Combatant) -> bool:
	if state != State.SETUP:
		push_error("CombatSession: cannot add combatants after start.")
		return false
	if combatant == null:
		push_error("CombatSession: null combatant.")
		return false
	if combatant.id == &"" or _by_id.has(combatant.id):
		push_error("CombatSession: duplicate or empty combatant id '%s'." % combatant.id)
		return false
	if combatant.team == &"":
		push_error("CombatSession: combatant '%s' has no team." % combatant.id)
		return false
	if combatant.max_hp <= 0 or not combatant.is_alive():
		push_error("CombatSession: combatant '%s' has invalid HP." % combatant.id)
		return false
	if not is_ready() or not combat_grid.can_stand(combatant.cell, combatant.height):
		push_error("CombatSession: combatant '%s' cell %s is not standable." % [combatant.id, combatant.cell])
		return false
	if _occupancy.has(combatant.cell):
		push_error("CombatSession: cell %s already occupied." % combatant.cell)
		return false
	combatant.elevation = combat_grid.stand_elevation_at(combatant.cell)
	combatants.append(combatant)
	_by_id[combatant.id] = combatant
	_occupancy[combatant.cell] = combatant
	return true

# ------------------------------------------------------------------
# Lifecycle
# ------------------------------------------------------------------

## Starts the encounter: requires at least two combatants on at least
## two opposing teams. Turn order is registration order; round 1.
func start() -> bool:
	if state != State.SETUP:
		return false
	if combatants.size() < 2:
		push_error("CombatSession: need at least 2 combatants, got %d." % combatants.size())
		return false
	var teams := {}
	for c in combatants:
		teams[c.team] = true
	if teams.size() < 2:
		push_error("CombatSession: need at least 2 opposing teams.")
		return false
	turn_order = combatants.duplicate()
	state = State.ACTIVE
	round_number = 1
	turn_index = -1
	encounter_started.emit()
	_advance_turn()
	return true

## Ends the encounter early (fled, cancelled). Only valid from SETUP or
## ACTIVE; terminal states are final.
func end_encounter() -> bool:
	if state == State.SETUP or state == State.ACTIVE:
		_finish(State.ENDED, EndReason.CANCELLED, &"")
		return true
	return false

func _finish(final_state: State, reason: EndReason, team: StringName) -> void:
	state = final_state
	end_reason = reason
	winning_team = team
	encounter_ended.emit(state, reason, team)

# ------------------------------------------------------------------
# Turns
# ------------------------------------------------------------------

func current_combatant() -> Combatant:
	if turn_index < 0 or turn_index >= turn_order.size():
		return null
	return turn_order[turn_index]

func is_turn(combatant_id: StringName) -> bool:
	var current := current_combatant()
	return current != null and current.id == combatant_id

func get_combatant(combatant_id: StringName) -> Combatant:
	return _by_id.get(combatant_id)

func end_turn() -> bool:
	if state != State.ACTIVE:
		return false
	_advance_turn()
	return true

func _advance_turn() -> void:
	var wrapped := false
	var skips := 0
	while true:
		turn_index += 1
		if turn_index >= turn_order.size():
			turn_index = 0
			round_number += 1
			wrapped = true
		var candidate := turn_order[turn_index]
		if candidate.is_alive():
			break
		skips += 1
		if skips >= turn_order.size():
			break
	if wrapped:
		round_changed.emit(round_number)
	var current := current_combatant()
	if current != null:
		current.reset_turn()
	turn_changed.emit(current, round_number)

# ------------------------------------------------------------------
# Combat resolution hooks (called by CombatActionResolver)
# ------------------------------------------------------------------

## Moves a combatant to a cell already validated by the resolver:
## updates occupancy and elevation atomically, then notifies.
func move_combatant_to(combatant: Combatant, dest: Vector2i, cost: int) -> void:
	var from := combatant.cell
	_occupancy.erase(from)
	combatant.cell = dest
	combatant.elevation = combat_grid.stand_elevation_at(dest)
	_occupancy[dest] = combatant
	combatant_moved.emit(combatant, from, dest, cost)

## Called by the resolver after damage is applied: emits the attack
## event, then handles defeat (frees the cell, checks victory).
func on_attack_resolved(actor: Combatant, target: Combatant, damage: int) -> void:
	attack_resolved.emit(actor, target, damage, target.hp)
	if not target.is_alive():
		notify_combatant_defeated(target)

func notify_combatant_defeated(combatant: Combatant) -> void:
	if not combatant.is_alive() and _occupancy.get(combatant.cell) == combatant:
		_occupancy.erase(combatant.cell)
	combatant_defeated.emit(combatant)
	check_end_conditions()

## Victory/draw evaluation: continues only while at least two teams
## have living members; one team left is a victory, none is a draw.
## Public so tests and future systems can re-evaluate explicitly.
func check_end_conditions() -> void:
	if state != State.ACTIVE:
		return
	var alive_teams := {}
	for c in combatants:
		if c.is_alive():
			alive_teams[c.team] = true
	if alive_teams.size() > 1:
		return
	if alive_teams.is_empty():
		_finish(State.DRAW, EndReason.DRAW, &"")
	else:
		_finish(State.VICTORY, EndReason.VICTORY, alive_teams.keys()[0])

# ------------------------------------------------------------------
# Queries
# ------------------------------------------------------------------

func occupied_cells() -> Array:
	return _occupancy.keys()

func combatant_at(world_cell: Vector2i) -> Combatant:
	return _occupancy.get(world_cell)
