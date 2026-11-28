extends SceneTree

## MutantCursed smoke test: unlock table, per-encounter skillsets,
## every ability's rules (Frenzy, Putrid Phlegm, Drowsiness, Hope,
## Little Sacrifice), equipment filtering, and persistence through
## the player_state.json "progression" block.
##
## Combat fixtures reuse the deterministic 8x8 room from
## CombatSessionSmokeTest (world = local + (50,50)). Persistence
## redirects FloorSaveSystem.save_root and RoomSaveSystem.save_dir to
## a user://smoke_* scratch dir — the real saves are never touched.

const ROOM_SCENE := "res://Scenes/World/Room.tscn"
const BLOCK_SCENE := "res://Scenes/Objects/Block.tscn"
const GRID_PATH := "res://Resources/IsometricGrid/TestGrid.tres"
const BLOCK_CATALOG_PATH := "res://Resources/BlockCatalog.tres"
const FURNITURE_CATALOG_PATH := "res://Resources/FurnitureCatalog.tres"
const TILE_CATALOG_PATH := "res://Resources/TileCatalog.tres"
const SMOKE_DIR := "user://smoke_mutant_cursed"
const ROOM_ORIGIN := Vector2i(50, 50)
const ROOM_SIZE := Vector2i(8, 8)

var _room: Room
var _blocks: BlockLayer
var _cg: CombatGrid
var _frames := 0
var _failures: Array[String] = []
var _saved_floor_root := ""
var _saved_save_dir := ""

func _initialize() -> void:
	_grid_setup()
	# Redirect ALL save writes to the scratch dir before any
	# CharacterProgression node is created.
	_saved_floor_root = FloorSaveSystem.save_root
	_saved_save_dir = RoomSaveSystem.save_dir
	FloorSaveSystem.save_root = SMOKE_DIR.path_join("floors")
	RoomSaveSystem.save_dir = SMOKE_DIR.path_join("saves")
	# The scratch dir persists across runs — wipe it so "fresh
	# profile" assertions see a clean slate every time.
	_wipe_dir(SMOKE_DIR)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(SMOKE_DIR))

func _wipe_dir(path: String) -> void:
	var abs := ProjectSettings.globalize_path(path)
	if not DirAccess.dir_exists_absolute(abs):
		return
	var dir := DirAccess.open(abs)
	if dir == null:
		return
	dir.list_dir_begin()
	var entry := dir.get_next()
	while entry != "":
		var child := abs.path_join(entry)
		if dir.current_is_dir():
			_wipe_dir(child)
		else:
			DirAccess.remove_absolute(child)
		entry = dir.get_next()
	dir.list_dir_end()
	DirAccess.remove_absolute(abs)

func _grid_setup() -> void:
	var grid := load(GRID_PATH) as IsometricGrid
	_room = (load(ROOM_SCENE) as PackedScene).instantiate() as Room
	_room.grid = grid
	_room.size = ROOM_SIZE
	_room.cell_origin = ROOM_ORIGIN
	var tile_catalog := load(TILE_CATALOG_PATH) as TileCatalog
	if tile_catalog != null:
		_room.default_tile = tile_catalog.get_definition(&"floor_iso")
	root.add_child(_room)

	_blocks = BlockLayer.new()
	_blocks.name = "BlockLayer"
	_blocks.grid = grid
	_blocks.room = _room
	_blocks.room_size = ROOM_SIZE
	_blocks.cell_origin = ROOM_ORIGIN
	_blocks.compact_depth = true
	_blocks.block_scene = load(BLOCK_SCENE) as PackedScene
	_blocks.block_catalog = load(BLOCK_CATALOG_PATH) as BlockCatalog
	_blocks.furniture_catalog = load(FURNITURE_CATALOG_PATH) as FurnitureCatalog
	_room.add_child(_blocks)
	_room.block_layer = _blocks

	_cg = CombatGrid.new()
	_cg.setup(_blocks, _room)

func _process(_delta: float) -> bool:
	_frames += 1
	if _frames < 2:
		return false
	_run_checks()
	FloorSaveSystem.save_root = _saved_floor_root
	RoomSaveSystem.save_dir = _saved_save_dir
	_report()
	quit()
	return true

func _expect(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)

func _w(local: Vector2i) -> Vector2i:
	return local + ROOM_ORIGIN

func _mk(id: StringName, team: StringName, local: Vector2i,
		hp := 10, budget := 4) -> Combatant:
	return Combatant.new(id, String(id), team, _w(local), hp, 0.0, 2.0, budget, 1.0)

## Fresh session + resolver duel: "a" heroes at (2,4), "b" foes at
## (3,4) — adjacent. Returns [session, resolver, a, b].
func _duel() -> Array:
	var s := CombatSession.new()
	s.setup(_cg)
	var a := _mk(&"a", &"heroes", Vector2i(2, 4))
	var b := _mk(&"b", &"foes", Vector2i(3, 4))
	s.add_combatant(a)
	s.add_combatant(b)
	s.start()
	var r := CombatActionResolver.new()
	r.setup(s)
	return [s, r, a, b]

## Duel where the hero carries the given skillset.
func _duel_with(skillset: CombatSkillset) -> Array:
	var parts := _duel()
	var a: Combatant = parts[2]
	a.skillset = skillset
	return parts

func _run_checks() -> void:
	_test_unlocks()
	_test_locked_abilities()
	_test_frenzy()
	_test_putrid_phlegm()
	_test_drowsiness()
	_test_drowsiness_bonus_on_abilities()
	_test_hope()
	_test_little_sacrifice()
	_test_equipment_rules()
	_test_persistence()
	_test_legacy_save_compat()
	_test_equip_blocked_in_combat()

# ------------------------------------------------------------------
# Unlocks
# ------------------------------------------------------------------

func _test_unlocks() -> void:
	_expect(AbilityCatalog.unlocked_at_level(1) == [&"frenzy"],
		"level 1 must unlock only Frenzy: %s" % str(AbilityCatalog.unlocked_at_level(1)))
	_expect(AbilityCatalog.unlocked_at_level(2) == [&"frenzy", &"putrid_phlegm"],
		"level 2 must add Putrid Phlegm")
	_expect(AbilityCatalog.unlocked_at_level(3) == [&"frenzy", &"putrid_phlegm", &"drowsiness"],
		"level 3 must add Drowsiness")
	_expect(AbilityCatalog.unlocked_at_level(4) == [&"frenzy", &"putrid_phlegm", &"drowsiness", &"hope"],
		"level 4 must add Hope")
	_expect(AbilityCatalog.unlocked_at_level(5).has(&"little_sacrifice"),
		"level 5 must add Little Sacrifice")
	_expect(AbilityCatalog.unlocked_at_level(5).has(&"hope"),
		"level 5 must keep Hope")
	# Levels clamp at the discipline max.
	_expect(AbilityCatalog.unlocked_at_level(99).size() == 5,
		"levels above max must clamp")
	_expect(AbilityCatalog.unlocked_at_level(0) == [&"frenzy"],
		"level 0 must clamp to 1")

# ------------------------------------------------------------------
# Locked abilities
# ------------------------------------------------------------------

func _test_locked_abilities() -> void:
	# A level-1 skillset only contains Frenzy.
	var prog := CharacterProgression.new()
	root.add_child(prog)
	prog.level = 1
	prog.equipped = [&"frenzy"]
	var skillset := CombatSkillset.from_progression(prog)
	_expect(skillset.has(&"frenzy"), "level-1 skillset must have Frenzy")
	_expect(not skillset.has(&"putrid_phlegm"), "level-1 must not have Phlegm")
	_expect(not skillset.has(&"drowsiness"), "level-1 must not have Drowsiness")
	_expect(not skillset.has(&"little_sacrifice"), "level-1 must not have Sacrifice")
	var parts := _duel_with(skillset)
	var r: CombatActionResolver = parts[1]
	var a: Combatant = parts[2]
	var b: Combatant = parts[3]
	# Even if the UI tried, the resolver rejects locked abilities.
	for locked_id in [&"putrid_phlegm", &"drowsiness", &"little_sacrifice", &"hope"]:
		var res := r.use_ability(&"a", &"b", locked_id)
		_expect(not res["ok"] and res["reason"] == &"ability_unavailable",
			"locked ability %s must fail: %s" % [locked_id, str(res)])
	# Unknown ids fail distinctly.
	var unknown := r.use_ability(&"a", &"b", &"fireball")
	_expect(not unknown["ok"] and unknown["reason"] == &"ability_unavailable",
		"unknown ability must fail as unavailable")
	# Passives can never be used actively.
	var passive := CombatSkillset.debug_full()
	var parts2 := _duel_with(passive)
	var r2: CombatActionResolver = parts2[1]
	var hope_use := r2.use_ability(&"a", &"b", &"hope")
	_expect(not hope_use["ok"] and hope_use["reason"] == &"ability_unavailable",
		"passive Hope must not be usable: %s" % str(hope_use))
	prog.queue_free()

# ------------------------------------------------------------------
# Frenzy / Putrid Phlegm
# ------------------------------------------------------------------

func _test_frenzy() -> void:
	var parts := _duel_with(CombatSkillset.debug_full())
	var r: CombatActionResolver = parts[1]
	var a: Combatant = parts[2]
	var b: Combatant = parts[3]
	var res := r.use_ability(&"a", &"b", &"frenzy")
	_expect(res["ok"], "frenzy should succeed: %s" % str(res))
	_expect(res["damage"] == 2 and b.hp == 8, "frenzy must deal exactly 2")
	_expect(a.act_used, "frenzy must consume the Act")
	# Second action same turn rejected.
	var second := r.use_ability(&"a", &"b", &"frenzy")
	_expect(not second["ok"] and second["reason"] == &"act_used",
		"second ability must be rejected")
	# Out of range: move b two cells away on a fresh duel.
	var parts2 := _duel_with(CombatSkillset.debug_full())
	var s2: CombatSession = parts2[0]
	var r2: CombatActionResolver = parts2[1]
	var b2: Combatant = parts2[3]
	s2.move_combatant_to(b2, _w(Vector2i(5, 4)), 0)
	var far := r2.use_ability(&"a", &"b", &"frenzy")
	_expect(not far["ok"] and far["reason"] == &"out_of_range",
		"frenzy beyond range 1 must fail: %s" % str(far))

func _test_putrid_phlegm() -> void:
	# Range 3 boundary: place foe at Chebyshev distance 3.
	var s := CombatSession.new()
	s.setup(_cg)
	var a := _mk(&"a", &"heroes", Vector2i(2, 4))
	var b := _mk(&"b", &"foes", Vector2i(5, 4))
	s.add_combatant(a)
	s.add_combatant(b)
	s.start()
	var r := CombatActionResolver.new()
	r.setup(s)
	a.skillset = CombatSkillset.debug_full()
	var res := r.use_ability(&"a", &"b", &"putrid_phlegm")
	_expect(res["ok"], "phlegm at range 3 should succeed: %s" % str(res))
	_expect(res["damage"] == 1 and b.hp == 9, "phlegm must deal exactly 1")
	# Distance 4 fails.
	var s2 := CombatSession.new()
	s2.setup(_cg)
	var a2 := _mk(&"a", &"heroes", Vector2i(2, 4))
	var b2 := _mk(&"b", &"foes", Vector2i(6, 4))
	s2.add_combatant(a2)
	s2.add_combatant(b2)
	s2.start()
	var r2 := CombatActionResolver.new()
	r2.setup(s2)
	a2.skillset = CombatSkillset.debug_full()
	var far := r2.use_ability(&"a", &"b", &"putrid_phlegm")
	_expect(not far["ok"] and far["reason"] == &"out_of_range",
		"phlegm at range 4 must fail: %s" % str(far))
	_expect(not a2.act_used, "failed ability must not consume the Act")

# ------------------------------------------------------------------
# Drowsiness
# ------------------------------------------------------------------

func _test_drowsiness() -> void:
	var parts := _duel_with(CombatSkillset.debug_full())
	var s: CombatSession = parts[0]
	var r: CombatActionResolver = parts[1]
	var a: Combatant = parts[2]
	var skillset: CombatSkillset = a.skillset
	var res := r.use_ability(&"a", &"b", &"drowsiness")
	_expect(res["ok"], "drowsiness should succeed: %s" % str(res))
	_expect(bool(res.get("ends_turn", false)), "drowsiness must end the turn")
	_expect(skillset.drowsiness_bonus == CombatSkillset.DROWSINESS_BONUS,
		"drowsiness must grant +%d" % CombatSkillset.DROWSINESS_BONUS)
	_expect(a.act_used, "drowsiness consumes the Act")
	# The manager ends the turn on ends_turn; simulate it here.
	s.end_turn()
	_expect(s.is_turn(&"b"), "turn should pass after drowsiness")
	# The bonus survives until the player's NEXT attack — b's turn
	# doesn't consume it.
	_expect(skillset.drowsiness_bonus == CombatSkillset.DROWSINESS_BONUS,
		"bonus must persist through the enemy turn")
	s.end_turn()
	# Next basic attack consumes it: 2 + 2 = 4 damage.
	var b: Combatant = parts[3]
	var hp_before: int = b.hp
	var atk := r.attack(&"a", &"b")
	_expect(atk["ok"], "attack after drowsiness failed: %s" % str(atk))
	_expect(atk["bonus_damage"] == CombatSkillset.DROWSINESS_BONUS,
		"attack must report the bonus: %s" % str(atk))
	_expect(b.hp == hp_before - 4, "attack should deal 4 (2+2)")
	_expect(skillset.drowsiness_bonus == 0, "bonus must be consumed")
	# Cannot stack: a second drowsiness after re-arming fails while
	# a bonus is pending.
	var parts2 := _duel_with(CombatSkillset.debug_full())
	var s2: CombatSession = parts2[0]
	var r2: CombatActionResolver = parts2[1]
	var a2: Combatant = parts2[2]
	var sk2: CombatSkillset = a2.skillset
	_expect(r2.use_ability(&"a", &"b", &"drowsiness")["ok"], "first drowsiness failed")
	s2.end_turn()
	s2.end_turn()
	# Still a's turn with bonus pending: a second drowsiness must fail.
	var again := r2.use_ability(&"a", &"b", &"drowsiness")
	_expect(not again["ok"] and again["reason"] == &"effect_pending",
		"drowsiness must not stack: %s" % str(again))
	# The bonus survives movement.
	var parts3 := _duel_with(CombatSkillset.debug_full())
	var s3: CombatSession = parts3[0]
	var r3: CombatActionResolver = parts3[1]
	var a3: Combatant = parts3[2]
	var sk3: CombatSkillset = a3.skillset
	r3.use_ability(&"a", &"b", &"drowsiness")
	s3.end_turn()
	s3.end_turn()
	r3.move(&"a", _w(Vector2i(1, 4)))
	_expect(sk3.drowsiness_bonus == CombatSkillset.DROWSINESS_BONUS,
		"movement must not consume the bonus")

# ------------------------------------------------------------------
# Drowsiness bonus on damage abilities
# ------------------------------------------------------------------

func _test_drowsiness_bonus_on_abilities() -> void:
	var parts := _duel_with(CombatSkillset.debug_full())
	var s: CombatSession = parts[0]
	var r: CombatActionResolver = parts[1]
	var a: Combatant = parts[2]
	var b: Combatant = parts[3]
	var sk: CombatSkillset = a.skillset
	r.use_ability(&"a", &"b", &"drowsiness")
	s.end_turn()
	s.end_turn()
	# Frenzy: 2 + 2 = 4.
	var frenzy := r.use_ability(&"a", &"b", &"frenzy")
	_expect(frenzy["ok"], "frenzy after drowsiness failed: %s" % str(frenzy))
	_expect(frenzy["damage"] == 4 and frenzy["bonus_damage"] == 2,
		"frenzy must deal 4 with bonus: %s" % str(frenzy))
	_expect(sk.drowsiness_bonus == 0, "bonus must be consumed by frenzy")
	# Re-arm, then Putrid Phlegm at range: move b away first? b is at
	# (3,4) adjacent — phlegm range 3 covers it. 1 + 2 = 3.
	var parts2 := _duel_with(CombatSkillset.debug_full())
	var s2: CombatSession = parts2[0]
	var r2: CombatActionResolver = parts2[1]
	var a2: Combatant = parts2[2]
	var b2: Combatant = parts2[3]
	r2.use_ability(&"a", &"b", &"drowsiness")
	s2.end_turn()
	s2.end_turn()
	var phlegm := r2.use_ability(&"a", &"b", &"putrid_phlegm")
	_expect(phlegm["ok"] and phlegm["damage"] == 3,
		"phlegm must deal 3 with bonus: %s" % str(phlegm))

# ------------------------------------------------------------------
# Hope
# ------------------------------------------------------------------

func _test_hope() -> void:
	var parts := _duel_with(CombatSkillset.debug_full())
	var s: CombatSession = parts[0]
	var a: Combatant = parts[2]
	var sk: CombatSkillset = a.skillset
	_expect(sk.hope_unlocked(), "debug_full skillset must unlock Hope")
	# Give the hero headroom: default fixture HP equals max_hp.
	a.max_hp = 20
	a.hp = 5
	# Three completed owner turns -> +4 HP.
	for i in 3:
		s.end_turn()
		s.end_turn()
	_expect(a.hp == 9, "hope should heal 4 after 3 turns, got %d" % a.hp)
	# Counter keeps ticking: turns 4-6 heal again.
	for i in 3:
		s.end_turn()
		s.end_turn()
	_expect(a.hp == 13, "hope should heal again on the next cycle, got %d" % a.hp)
	# Clamps at max_hp.
	a.hp = 19
	for i in 3:
		s.end_turn()
		s.end_turn()
	_expect(a.hp == a.max_hp, "hope must clamp at max_hp")
	# is_main = false disables the passive entirely.
	var parts2 := _duel_with(CombatSkillset.debug_full())
	var s2: CombatSession = parts2[0]
	var a2: Combatant = parts2[2]
	var sk2: CombatSkillset = a2.skillset
	sk2.is_main = false
	_expect(not sk2.hope_unlocked(), "hope must require main discipline")
	a2.hp = 5
	for i in 3:
		s2.end_turn()
		s2.end_turn()
	_expect(a2.hp == 5, "hope must not heal when not main")
	# Defeated combatants don't tick the counter.
	var sk3 := CombatSkillset.new()
	var dead := _mk(&"dead", &"heroes", Vector2i(0, 0), 5)
	dead.hp = 0
	sk3.passives.append(&"hope")
	sk3.is_main = true
	var before := sk3.turns_completed
	sk3.on_turn_completed(dead)
	_expect(sk3.turns_completed == before, "dead combatant must not tick Hope")

# ------------------------------------------------------------------
# Little Sacrifice
# ------------------------------------------------------------------

func _test_little_sacrifice() -> void:
	var parts := _duel_with(CombatSkillset.debug_full())
	var s: CombatSession = parts[0]
	var r: CombatActionResolver = parts[1]
	var a: Combatant = parts[2]
	var b: Combatant = parts[3]
	var sk: CombatSkillset = a.skillset
	var a_hp: int = a.hp
	var b_hp: int = b.hp
	var res := r.use_ability(&"a", &"b", &"little_sacrifice")
	_expect(res["ok"], "sacrifice should succeed: %s" % str(res))
	_expect(res["damage"] == 4 and b.hp == b_hp - 4, "target must lose 4")
	_expect(res["self_damage"] == 4 and a.hp == a_hp - 4,
		"caster must lose 4: %s" % str(res))
	_expect(sk.uses_remaining(&"little_sacrifice") == 0,
		"sacrifice use must be consumed")
	# Second use same encounter rejected.
	s.end_turn()
	s.end_turn()
	var again := r.use_ability(&"a", &"b", &"little_sacrifice")
	_expect(not again["ok"] and again["reason"] == &"no_uses",
		"second sacrifice must fail: %s" % str(again))
	# Simultaneous defeat -> coherent DRAW, not order-dependent.
	var parts2 := _duel_with(CombatSkillset.debug_full())
	var s2: CombatSession = parts2[0]
	var r2: CombatActionResolver = parts2[1]
	var a2: Combatant = parts2[2]
	var b2: Combatant = parts2[3]
	a2.hp = 4
	b2.hp = 4
	var double := r2.use_ability(&"a", &"b", &"little_sacrifice")
	_expect(double["ok"], "double-KO sacrifice should resolve: %s" % str(double))
	_expect(not a2.is_alive() and not b2.is_alive(), "both must be dead")
	_expect(s2.state == CombatSession.State.DRAW,
		"double KO must be DRAW, got %s" % CombatSession.State.keys()[s2.state])
	_expect(s2.end_reason == CombatSession.EndReason.DRAW,
		"double KO end reason must be DRAW")

# ------------------------------------------------------------------
# Equipment rules
# ------------------------------------------------------------------

func _test_equipment_rules() -> void:
	var prog := CharacterProgression.new()
	root.add_child(prog)
	# Fresh profile: level 1, Frenzy equipped.
	_expect(prog.level == 1, "fresh progression must be level 1")
	_expect(prog.is_equipped(&"frenzy"), "frenzy must start equipped")
	_expect(not prog.is_equipped(&"putrid_phlegm"), "phlegm must start unequipped")
	# Locked abilities cannot be equipped.
	_expect(not prog.can_equip(&"putrid_phlegm"), "locked ability must not be equippable")
	_expect(not prog.equip(&"putrid_phlegm"), "equip of locked must fail")
	_expect(not prog.is_equipped(&"putrid_phlegm"), "locked equip must not stick")
	# Passives can never be equipped.
	prog.set_level(4)
	_expect(not prog.can_equip(&"hope"), "passive must not be equippable")
	_expect(not prog.equip(&"hope"), "passive equip must fail")
	# Unlock at level 2: set_level auto-equips newly unlocked actives,
	# so an already-equipped ability reports can_equip == false — that
	# is correct (it is in use, not locked). Unequip first.
	prog.set_level(2)
	_expect(prog.is_equipped(&"putrid_phlegm"), "level-up should auto-equip phlegm")
	prog.unequip(&"putrid_phlegm")
	_expect(prog.can_equip(&"putrid_phlegm"), "unlocked ability must be equippable")
	_expect(prog.equip(&"putrid_phlegm"), "equip of unlocked must succeed")
	prog.unequip(&"putrid_phlegm")
	_expect(not prog.is_equipped(&"putrid_phlegm"), "unequip must work")
	# Locked ids are dropped if level decreases.
	prog.set_level(1)
	_expect(not prog.is_equipped(&"putrid_phlegm"), "level-down must drop locked equips")
	prog.queue_free()

# ------------------------------------------------------------------
# Persistence
# ------------------------------------------------------------------

func _test_persistence() -> void:
	var prog := CharacterProgression.new()
	root.add_child(prog)
	prog.set_level(5)
	prog.unequip(&"putrid_phlegm")
	prog.unequip(&"drowsiness")
	# flush() ran via _changed(); verify a second node reads it back.
	var prog2 := CharacterProgression.new()
	root.add_child(prog2)
	_expect(prog2.level == 5, "level must persist, got %d" % prog2.level)
	_expect(prog2.main_discipline == AbilityCatalog.MUTANT_CURSED,
		"main discipline must persist")
	_expect(prog2.is_equipped(&"frenzy"), "frenzy must persist equipped")
	_expect(not prog2.is_equipped(&"putrid_phlegm"), "unequip must persist")
	_expect(not prog2.is_equipped(&"drowsiness"), "drowsiness unequip must persist")
	_expect(prog2.is_equipped(&"little_sacrifice"), "sacrifice must persist equipped")
	# Skillset built from the loaded progression matches.
	var sk := CombatSkillset.from_progression(prog2)
	_expect(sk.has(&"frenzy") and not sk.has(&"putrid_phlegm")
		and not sk.has(&"drowsiness") and sk.has(&"little_sacrifice"),
		"skillset must reflect persisted equipment")
	_expect(sk.passives.has(&"hope"), "hope passive must be unlocked at level 5")
	# A tampered save (locked id in equipped) is filtered at load.
	prog2.equipped.append(&"frenzy") # duplicate guard check below
	prog2.equipped = [&"frenzy", &"hope"]
	prog2.flush()
	var prog3 := CharacterProgression.new()
	root.add_child(prog3)
	_expect(prog3.equipped == [&"frenzy"],
		"passive/duplicate ids must be filtered on load: %s" % str(prog3.equipped))
	prog.queue_free()
	prog2.queue_free()
	prog3.queue_free()

func _test_legacy_save_compat() -> void:
	# An old-format player_state.json (position fields only, no
	# "progression" block) must still load, and progression falls
	# back to defaults.
	var dir := RoomSaveSystem.save_dir
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dir))
	var path := dir.path_join("player_state.json")
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string(JSON.stringify({
		"version": RoomSaveSystem.VERSION,
		"room_coordinates": [0, 0],
		"position": [3, 3],
		"elevation": 0.0,
	}))
	file.close()
	var state := RoomSaveSystem.load_player_state()
	_expect(int(state.get("position", Vector2i(-9, -9)).x) == 3,
		"legacy player_state must still load")
	# save_player_state must preserve the progression block.
	var prog := CharacterProgression.new()
	root.add_child(prog)
	prog.set_level(3)
	RoomSaveSystem.save_player_state(Vector2i(0, 0), Vector2i(4, 4), 0.0)
	var reread := _read_json(path)
	_expect(reread.get("progression") is Dictionary,
		"position save must preserve the progression block")
	_expect(int((reread["progression"] as Dictionary).get("level", 0)) == 3,
		"progression level must survive a position save")
	prog.queue_free()
	# A fresh node on the legacy file still reads level 3.
	var prog4 := CharacterProgression.new()
	root.add_child(prog4)
	_expect(prog4.level == 3, "progression must reload after position save")
	prog4.queue_free()

func _read_json(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return {}
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	file.close()
	return parsed if parsed is Dictionary else {}

# ------------------------------------------------------------------
# Equipment blocked during combat
# ------------------------------------------------------------------

func _test_equip_blocked_in_combat() -> void:
	# DisciplinePanel refuses to open while CombatManager.any_active
	# reports a live encounter — that is what guarantees equipment
	# cannot change mid-fight.
	var panel := DisciplinePanel.new()
	root.add_child(panel)
	_expect(panel._can_open(), "panel should open with no combat")
	var manager := CombatManager.new()
	root.add_child(manager)
	var s := CombatSession.new()
	s.setup(_cg)
	var a := _mk(&"pa", &"heroes", Vector2i(0, 0))
	var b := _mk(&"pb", &"foes", Vector2i(1, 0))
	s.add_combatant(a)
	s.add_combatant(b)
	s.start()
	manager.session = s
	_expect(CombatManager.any_active(self), "any_active should see the session")
	_expect(not panel._can_open(), "panel must not open during combat")
	manager.session = null
	manager.queue_free()
	panel.queue_free()

func _report() -> void:
	if _failures.is_empty():
		print("MUTANT_CURSED_SMOKE: OK")
	else:
		for failure in _failures:
			push_error("MUTANT_CURSED_SMOKE FAIL: " + failure)
		print("MUTANT_CURSED_SMOKE: FAILED (%d)" % _failures.size())
