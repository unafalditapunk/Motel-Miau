class_name CharacterProgression
extends Node

## Persistent character progression for the local player: Mutant
## Cursed level, main discipline, and equipped abilities.
##
## Storage: a "progression" block inside player_state.json — the file
## the world already writes per floor — mirrored into every existing
## floor save dir (user://floors/<id>/) plus the legacy saves dir, so
## whichever floor boots reads the freshest copy. player_state.json
## is per-floor but progression is global character data; mirroring
## keeps every copy identical. Missing/corrupt/absent data falls
## back to a fresh level-1 profile, and old saves without the block
## load untouched.
##
## There is no XP economy yet — level is set through set_level()
## (tests, future rewards). Unlocks derive from level via
## AbilityCatalog; nothing here auto-levels for ability use.

signal progression_changed

const PROGRESSION_VERSION := 1
const DEFAULT_DISCIPLINE := AbilityCatalog.MUTANT_CURSED

var level := 1
var main_discipline: StringName = DEFAULT_DISCIPLINE
## Equipped ability ids (actives/ultimates only — passives like Hope
## are always on while their discipline is main).
var equipped: Array[StringName] = []

func _ready() -> void:
	add_to_group(&"character_progressions")
	if not load_from_disk():
		# Fresh profile: level 1 with its starter ability equipped.
		equipped = _default_equipped()

## First progression node in the tree, or null (tests may run without
## one — combat then falls back to basic-attack-only skillsets).
static func find(tree: SceneTree) -> CharacterProgression:
	if tree == null:
		return null
	for node in tree.get_nodes_in_group(&"character_progressions"):
		var progression := node as CharacterProgression
		if progression != null:
			return progression
	return null

# ------------------------------------------------------------------
# Queries
# ------------------------------------------------------------------

func unlocked_ids() -> Array[StringName]:
	return AbilityCatalog.unlocked_at_level(level)

func is_unlocked(ability_id: StringName) -> bool:
	return unlocked_ids().has(ability_id)

func is_equipped(ability_id: StringName) -> bool:
	return equipped.has(ability_id)

## Equippable = unlocked AND not a passive (passives need no slot).
func can_equip(ability_id: StringName) -> bool:
	if not is_unlocked(ability_id) or equipped.has(ability_id):
		return false
	var def := AbilityCatalog.ability(ability_id)
	return not def.is_empty() and StringName(def.get("kind", &"")) != &"passive"

func equip(ability_id: StringName) -> bool:
	if not can_equip(ability_id):
		return false
	equipped.append(ability_id)
	_changed()
	return true

func unequip(ability_id: StringName) -> bool:
	var index := equipped.find(ability_id)
	if index < 0:
		return false
	equipped.remove_at(index)
	_changed()
	return true

## Sets the discipline level (1..max). Newly unlocked active/ultimate
## abilities auto-equip — a level-up should hand the player its new
## toy; passives never enter the equip list. Locked ids are dropped
## from equipped if the level ever decreases.
func set_level(new_level: int) -> void:
	var max_level := int(AbilityCatalog.discipline_info(main_discipline) \
		.get("max_level", 1))
	level = clampi(new_level, 1, max_level)
	var unlocked := unlocked_ids()
	var kept: Array[StringName] = []
	for ability_id in equipped:
		if unlocked.has(ability_id):
			kept.append(ability_id)
	for ability_id in unlocked:
		var def := AbilityCatalog.ability(ability_id)
		if StringName(def.get("kind", &"")) != &"passive" \
				and not kept.has(ability_id) \
				and not equipped.has(ability_id):
			kept.append(ability_id)
	equipped = kept
	_changed()

func reset_to_default() -> void:
	level = 1
	main_discipline = DEFAULT_DISCIPLINE
	equipped = _default_equipped()
	_changed()

## Fresh-profile equipped set: every unlocked non-passive ability.
func _default_equipped() -> Array[StringName]:
	var result: Array[StringName] = []
	for ability_id in unlocked_ids():
		var def := AbilityCatalog.ability(ability_id)
		if StringName(def.get("kind", &"")) != &"passive":
			result.append(ability_id)
	return result

func _changed() -> void:
	flush()
	progression_changed.emit()

# ------------------------------------------------------------------
# Serialization
# ------------------------------------------------------------------

func to_dict() -> Dictionary:
	var ids: Array = []
	for ability_id in equipped:
		ids.append(String(ability_id))
	return {
		"version": PROGRESSION_VERSION,
		"level": level,
		"main_discipline": String(main_discipline),
		"equipped": ids,
	}

func from_dict(data: Dictionary) -> void:
	level = clampi(int(data.get("level", 1)), 1,
		int(AbilityCatalog.discipline_info(DEFAULT_DISCIPLINE).get("max_level", 1)))
	var discipline := StringName(data.get("main_discipline", DEFAULT_DISCIPLINE))
	main_discipline = discipline if AbilityCatalog.discipline_info(discipline) \
			.has("display_name") else DEFAULT_DISCIPLINE
	var unlocked := unlocked_ids()
	equipped = []
	for raw in data.get("equipped", []):
		var ability_id := StringName(raw)
		var def := AbilityCatalog.ability(ability_id)
		# Drop unknown ids (forward compat) and passives/locked ids.
		if not def.is_empty() and unlocked.has(ability_id) \
				and StringName(def.get("kind", &"")) != &"passive" \
				and not equipped.has(ability_id):
			equipped.append(ability_id)

# ------------------------------------------------------------------
# Persistence (player_state.json "progression" block, mirrored)
# ------------------------------------------------------------------

## Reads the progression block from the best available
## player_state.json: active floor first, then any floor dir, then
## the legacy saves dir. Returns false when nothing was found (fresh
## defaults stay in place).
func load_from_disk() -> bool:
	for path in _candidate_player_state_paths():
		var data := _read_json(path)
		var block: Variant = data.get("progression")
		if block is Dictionary and int((block as Dictionary).get("version", 0)) \
				== PROGRESSION_VERSION:
			from_dict(block as Dictionary)
			return true
	return false

## Writes the progression block into player_state.json of every
## existing floor dir plus the legacy saves dir. Read-modify-write so
## position/room fields and future sections survive. Returns the
## number of files written.
func flush() -> int:
	var written := 0
	for dir_path in _save_dirs():
		var path := dir_path.path_join("player_state.json")
		var data := _read_json(path)
		data["version"] = RoomSaveSystem.VERSION
		data["progression"] = to_dict()
		if _write_json(path, data):
			written += 1
	return written

## Ordered player_state.json candidates for loading: the active
## floor's dir first (the floor the game actually booted into), then
## every other floor dir, then the legacy saves dir.
func _candidate_player_state_paths() -> Array[String]:
	var paths: Array[String] = []
	var dirs := _save_dirs()
	var preferred := ""
	var floor_manager := get_tree().get_first_node_in_group(&"floor_managers") as FloorManager
	if floor_manager != null and floor_manager.active_floor != null:
		preferred = FloorSaveSystem.floor_dir(floor_manager.active_floor.floor_id)
	if not preferred.is_empty() and dirs.has(preferred):
		dirs.erase(preferred)
		dirs.push_front(preferred)
	for dir_path in dirs:
		paths.append(dir_path.path_join("player_state.json"))
	return paths

## Every directory that can hold a player_state.json: floor save dirs
## under FloorSaveSystem.save_root plus the legacy RoomSaveSystem dir.
func _save_dirs() -> Array[String]:
	var dirs: Array[String] = []
	var root := DirAccess.open(FloorSaveSystem.save_root)
	if root != null:
		root.list_dir_begin()
		var entry := root.get_next()
		while entry != "":
			if root.current_is_dir() and not entry.begins_with("."):
				dirs.append(FloorSaveSystem.save_root.path_join(entry))
			entry = root.get_next()
		root.list_dir_end()
	if not dirs.has(RoomSaveSystem.save_dir):
		dirs.append(RoomSaveSystem.save_dir)
	return dirs

func _read_json(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return {}
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	file.close()
	return parsed if parsed is Dictionary else {}

func _write_json(path: String, data: Dictionary) -> bool:
	var dir_path := path.get_base_dir()
	if DirAccess.make_dir_recursive_absolute(dir_path) != OK \
			and DirAccess.dir_exists_absolute(dir_path) == false:
		push_warning("CharacterProgression: cannot create '%s'." % dir_path)
		return false
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		push_warning("CharacterProgression: cannot write '%s'." % path)
		return false
	file.store_string(JSON.stringify(data, "\t"))
	file.close()
	return true
