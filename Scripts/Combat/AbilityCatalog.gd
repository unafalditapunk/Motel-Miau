class_name AbilityCatalog
extends RefCounted

## Static catalog of disciplines and their abilities. Data only — no
## state, no nodes. Mutant Cursed is the first (and currently only)
## discipline; adding a future discipline means adding an entry to
## DISCIPLINES plus its ability defs and unlock rows.
##
## Ability def fields:
##   id            StringName — stable id used by saves and skillsets
##   discipline    StringName — owning discipline
##   display_name  String    — UI label (thematic name preserved)
##   kind          StringName — "active" | "passive" | "ultimate"
##   is_attack     bool      — consumes the Drowsiness damage bonus
##   damage        int       — damage dealt to the target (0 = none)
##   range         int       — Chebyshev cells (0 = self/no target)
##   needs_los     bool      — requires line of sight to target
##   self_damage   int       — damage the caster takes on use
##   ends_turn     bool      — the action consumes the whole turn
##   max_uses      int       — per-encounter uses (0 = unlimited)
##   unlock_level  int       — Mutant Cursed level that grants it
##   description   String    — UI tooltip

const MUTANT_CURSED := &"mutant_cursed"

const ABILITIES := {
	&"frenzy": {
		"discipline": MUTANT_CURSED,
		"display_name": "Desenfreno",
		"kind": &"active",
		"is_attack": true,
		"damage": 2,
		"range": 1,
		"needs_los": true,
		"self_damage": 0,
		"ends_turn": false,
		"max_uses": 0,
		"unlock_level": 1,
		"description": "Deals 2 damage to one enemy within 1 cell.",
	},
	&"putrid_phlegm": {
		"discipline": MUTANT_CURSED,
		"display_name": "Gargaja pútrida",
		"kind": &"active",
		"is_attack": true,
		"damage": 1,
		"range": 3,
		"needs_los": true,
		"self_damage": 0,
		"ends_turn": false,
		"max_uses": 0,
		"unlock_level": 2,
		"description": "Deals 1 damage to one enemy within 3 cells.",
	},
	&"drowsiness": {
		"discipline": MUTANT_CURSED,
		"display_name": "Somnolencia",
		"kind": &"active",
		"is_attack": false,
		"damage": 0,
		"range": 0,
		"needs_los": false,
		"self_damage": 0,
		"ends_turn": true,
		"max_uses": 0,
		"unlock_level": 3,
		"description": "Give up your turn. Your next attack deals +2 damage.",
	},
	&"hope": {
		"discipline": MUTANT_CURSED,
		"display_name": "Esperanza",
		"kind": &"passive",
		"is_attack": false,
		"damage": 0,
		"range": 0,
		"needs_los": false,
		"self_damage": 0,
		"ends_turn": false,
		"max_uses": 0,
		"unlock_level": 4,
		"description": "After every 3 of your turns, recover 4 HP.",
	},
	&"little_sacrifice": {
		"discipline": MUTANT_CURSED,
		"display_name": "Pequeño sacrificio",
		"kind": &"ultimate",
		"is_attack": true,
		"damage": 4,
		"range": 1,
		"needs_los": true,
		"self_damage": 4,
		"ends_turn": false,
		"max_uses": 1,
		"unlock_level": 5,
		"description": "Deal 4 damage to an enemy within 1 cell, then take 4 damage yourself.",
	},
}

## Discipline display info. Only Mutant Cursed exists; the shape is
## already a list so future disciplines slot in without schema changes.
const DISCIPLINES := {
	MUTANT_CURSED: {
		"display_name": "Mutant Cursed",
		"max_level": 5,
	},
}

static func ability(ability_id: StringName) -> Dictionary:
	return ABILITIES.get(ability_id, {})

static func is_ability(ability_id: StringName) -> bool:
	return ABILITIES.has(ability_id)

static func discipline_info(discipline_id: StringName) -> Dictionary:
	return DISCIPLINES.get(discipline_id, {})

## Ability ids unlocked at the given Mutant Cursed level, in
## definition order. Levels clamp to the discipline's max_level.
static func unlocked_at_level(level: int) -> Array[StringName]:
	var result: Array[StringName] = []
	var max_level := int(discipline_info(MUTANT_CURSED).get("max_level", 0))
	var clamped := clampi(level, 1, max_level)
	for ability_id in ABILITIES:
		var def: Dictionary = ABILITIES[ability_id]
		if def["discipline"] == MUTANT_CURSED \
				and int(def["unlock_level"]) <= clamped:
			result.append(ability_id)
	return result

## Display order for UI listings — definition order is insertion
## order, which already matches the level progression.
static func all_ability_ids() -> Array[StringName]:
	var result: Array[StringName] = []
	for ability_id in ABILITIES:
		result.append(ability_id)
	return result
