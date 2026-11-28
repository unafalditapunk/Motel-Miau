class_name CombatSkillset
extends RefCounted

## Per-encounter combat abilities for one Combatant. Seeded from the
## persistent CharacterProgression at encounter start (equipped ∩
## unlocked-at-level); all temporary state — Drowsiness bonus, Hope
## turn counter, ultimate uses — lives here and dies with the
## combatant, so nothing encounter-scoped ever reaches the save file.
##
## Enemies simply have skillset == null: they keep the basic attack
## and move, exactly like before disciplines existed.
##
## Passive rule: Hope only ticks while the owner's main discipline is
## Mutant Cursed — the only discipline that exists, but the check is
## real so future disciplines gate their own passives the same way.

const HOPE_HEAL := 4
const HOPE_EVERY_TURNS := 3
const DROWSINESS_BONUS := 2

var discipline_id: StringName = AbilityCatalog.MUTANT_CURSED
## True when this discipline is the owner's MAIN discipline. Passives
## require it; unlocked actives do not.
var is_main := true
## Ability ids usable this encounter (equipped ∩ unlocked at seed).
var available: Array[StringName] = []
## Unlocked passives for this discipline — always on while is_main,
## never equippable, never clickable.
var passives: Array[StringName] = []
## Pending Drowsiness bonus: 0 or DROWSINESS_BONUS. Cannot stack.
var drowsiness_bonus := 0
## Completed turns owned by this combatant (Hope counter).
var turns_completed := 0
## Remaining uses per limited ability (e.g. little_sacrifice: 1).
var uses_left := {}

## Builds a skillset from a progression snapshot. equipped_ids are
## filtered against unlocked_at_level so a stale/hand-edited save can
## never arm a locked ability.
static func from_progression(progression: CharacterProgression) -> CombatSkillset:
	var skillset := CombatSkillset.new()
	if progression == null:
		return skillset
	skillset.discipline_id = progression.main_discipline
	skillset.is_main = true
	var unlocked := AbilityCatalog.unlocked_at_level(progression.level)
	for ability_id in progression.equipped:
		if unlocked.has(ability_id) and not skillset.available.has(ability_id):
			skillset.available.append(ability_id)
	for ability_id in unlocked:
		var def := AbilityCatalog.ability(ability_id)
		if StringName(def.get("kind", &"")) == &"passive":
			skillset.passives.append(ability_id)
	for ability_id in skillset.available:
		var def := AbilityCatalog.ability(ability_id)
		var max_uses := int(def.get("max_uses", 0))
		if max_uses > 0:
			skillset.uses_left[ability_id] = max_uses
	return skillset

## Fallback for tests/fixtures that want a fully-loaded skillset
## without a progression node.
static func debug_full(discipline: StringName = AbilityCatalog.MUTANT_CURSED) -> CombatSkillset:
	var skillset := CombatSkillset.new()
	skillset.discipline_id = discipline
	skillset.is_main = true
	for ability_id in AbilityCatalog.unlocked_at_level(5):
		var def := AbilityCatalog.ability(ability_id)
		if StringName(def.get("kind", &"")) == &"passive":
			skillset.passives.append(ability_id)
		else:
			skillset.available.append(ability_id)
		var max_uses := int(def.get("max_uses", 0))
		if max_uses > 0:
			skillset.uses_left[ability_id] = max_uses
	return skillset

func has(ability_id: StringName) -> bool:
	return available.has(ability_id)

func uses_remaining(ability_id: StringName) -> int:
	return int(uses_left.get(ability_id, 0))

func is_unlimited(ability_id: StringName) -> bool:
	return not uses_left.has(ability_id)

func consume_use(ability_id: StringName) -> void:
	if uses_left.has(ability_id):
		uses_left[ability_id] = maxi(int(uses_left[ability_id]) - 1, 0)

## Hope passive gate: unlocked AND main discipline AND not on
## cooldown — checked by the session hook, which owns turn counting.
func hope_unlocked() -> bool:
	return is_main and passives.has(&"hope")

## Called by CombatSession when this combatant's turn ends. Heals
## HOPE_HEAL every HOPE_EVERY_TURNS completed turns, clamped to max.
func on_turn_completed(combatant: Combatant) -> void:
	if combatant == null or not combatant.is_alive() or not hope_unlocked():
		return
	turns_completed += 1
	if turns_completed % HOPE_EVERY_TURNS == 0:
		combatant.heal(HOPE_HEAL)

## Adds the pending Drowsiness bonus to an attack's damage and
## consumes it. Returns the bonus actually applied (0 when none was
## pending — the bonus never survives a non-attack or a failed use).
func consume_attack_bonus() -> int:
	var bonus := drowsiness_bonus
	drowsiness_bonus = 0
	return bonus
