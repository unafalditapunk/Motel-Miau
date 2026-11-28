extends SceneTree

## CombatHotbar smoke test: drives a real Player + CombatManager +
## CharacterProgression through the new hotbar UI — slot building,
## number-key selection, click activation, armed targeting, immediate
## self-abilities (Somnolencia), Escape cancel, unavailable-state
## reasons, and teardown hiding the hotbar.
##
## Same deterministic 8x8 room fixture as CombatEncounterSmokeTest
## (world = local + (50,50)); player local (3,4), enemy local (5,5)
## — Chebyshev distance 2, inside Putrid Phlegm's range 3 but outside
## Frenzy's range 1 (tests teleport the combatants adjacent later).
## enemy_turn_delay is raised; the test calls enemy_take_turn()
## directly. Saves are redirected to a wiped user:// smoke dir.

const ROOM_SCENE := "res://Scenes/World/Room.tscn"
const BLOCK_SCENE := "res://Scenes/Objects/Block.tscn"
const PLAYER_SCENE := "res://Scenes/Player/Player.tscn"
const GRID_PATH := "res://Resources/IsometricGrid/TestGrid.tres"
const BLOCK_CATALOG_PATH := "res://Resources/BlockCatalog.tres"
const FURNITURE_CATALOG_PATH := "res://Resources/FurnitureCatalog.tres"
const TILE_CATALOG_PATH := "res://Resources/TileCatalog.tres"
const SMOKE_DIR := "user://smoke_combat_hotbar"
const ROOM_ORIGIN := Vector2i(50, 50)
const ROOM_SIZE := Vector2i(8, 8)

var _room: Room
var _blocks: BlockLayer
var _grid: IsometricGrid
var _player: Player
var _manager: CombatManager
var _progression: CharacterProgression
var _frames := 0
var _failures: Array[String] = []
var _saved_floor_root := ""
var _saved_save_dir := ""

func _initialize() -> void:
	_grid = load(GRID_PATH) as IsometricGrid
	_room = (load(ROOM_SCENE) as PackedScene).instantiate() as Room
	_room.grid = _grid
	_room.size = ROOM_SIZE
	_room.cell_origin = ROOM_ORIGIN
	var tile_catalog := load(TILE_CATALOG_PATH) as TileCatalog
	if tile_catalog != null:
		_room.default_tile = tile_catalog.get_definition(&"floor_iso")
	root.add_child(_room)

	_blocks = BlockLayer.new()
	_blocks.name = "BlockLayer"
	_blocks.grid = _grid
	_blocks.room = _room
	_blocks.room_size = ROOM_SIZE
	_blocks.cell_origin = ROOM_ORIGIN
	_blocks.compact_depth = true
	_blocks.block_scene = load(BLOCK_SCENE) as PackedScene
	_blocks.block_catalog = load(BLOCK_CATALOG_PATH) as BlockCatalog
	_blocks.furniture_catalog = load(FURNITURE_CATALOG_PATH) as FurnitureCatalog
	_room.add_child(_blocks)
	_room.block_layer = _blocks

	_player = (load(PLAYER_SCENE) as PackedScene).instantiate() as Player
	_player.grid = _grid
	_player.block_layer = _blocks
	_player.room = _room
	_player.room_size = ROOM_SIZE
	_player.room_world = null
	_player.grid_position = Vector2i(3, 4)
	_player.elevation = 0.0
	root.add_child(_player)

	# Clean progression: level 3 -> Frenzy, Putrid Phlegm,
	# Somnolencia equipped (auto-equip on level-up).
	_saved_floor_root = FloorSaveSystem.save_root
	_saved_save_dir = RoomSaveSystem.save_dir
	FloorSaveSystem.save_root = SMOKE_DIR.path_join("floors")
	RoomSaveSystem.save_dir = SMOKE_DIR.path_join("saves")
	_wipe_dir(SMOKE_DIR)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(SMOKE_DIR))
	_progression = CharacterProgression.new()
	_progression.name = "CharacterProgression"
	root.add_child(_progression)
	_progression.set_level(3)

	_manager = CombatManager.new()
	_manager.name = "CombatManager"
	root.add_child(_manager)
	_manager.bind_player(_player)
	_manager.character_progression = _progression
	_manager.enemy_turn_delay = 3600.0
	_player.combat_move_duration = 0.01

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

func _process(_delta: float) -> bool:
	_frames += 1
	if _frames < 3:
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

func _key(keycode: Key) -> InputEventKey:
	var event := InputEventKey.new()
	event.keycode = keycode
	event.physical_keycode = keycode
	event.pressed = true
	event.echo = false
	return event

func _ui() -> CombatUI:
	return _manager.ui

func _enemy_cell() -> Vector2i:
	return _manager.enemy_combatant().cell

## Ends the player turn and resolves the deterministic enemy turn,
## returning control to the player.
func _pass_turn() -> void:
	_manager.player_end_turn()
	_manager.enemy_take_turn()

func _run_checks() -> void:
	_test_encounter_and_slots()
	_test_number_key_targeting()
	_test_out_of_range_rejected()
	_test_escape_cancels()
	_test_drowsiness_key()
	_test_bonus_damage_via_hotbar()
	_test_unavailable_reason()
	_test_victory_hides_hotbar()

# ------------------------------------------------------------------
# Encounter + slot building
# ------------------------------------------------------------------

func _test_encounter_and_slots() -> void:
	var enemy := _manager.spawn_enemy_at(_room, Vector2i(5, 5))
	_expect(enemy != null, "enemy should spawn")
	_expect(_manager.try_interact(), "encounter should start")
	# HP headroom: the enemy AI hits for 2 every round and the test
	# needs it alive until the victory check.
	var ec := _manager.enemy_combatant()
	ec.max_hp = 30
	ec.hp = 30
	var ui := _ui()
	_expect(ui.is_combat_visible(), "combat UI should be visible")
	_expect(ui._hotbar.visible, "hotbar should be visible")
	# Level 3 progression equips three abilities in unlock order.
	_expect(ui._slot_ids == [&"frenzy", &"putrid_phlegm", &"drowsiness"],
		"slot ids wrong: %s" % str(ui._slot_ids))
	_expect(ui._slot_buttons.size() == 3, "expected 3 slot buttons")
	_expect(ui._slot_numbers[0].text == "1"
		and ui._slot_numbers[2].text == "3", "slot numbers wrong")

# ------------------------------------------------------------------
# Number-key selection + targeting
# ------------------------------------------------------------------

func _test_number_key_targeting() -> void:
	var ui := _ui()
	# KEY_2 arms Putrid Phlegm (index 1); distance 2 <= range 3.
	ui._unhandled_input(_key(KEY_2))
	_expect(ui.armed_ability == &"putrid_phlegm",
		"key 2 should arm phlegm, got %s" % ui.armed_ability)
	_expect(ui.target_mode == CombatUI.TargetMode.ATTACK,
		"arming should enter ATTACK target mode")
	# Click the enemy's cell -> resolver validates and executes.
	var ec := _manager.enemy_combatant()
	var hp_before: int = ec.hp
	_expect(_manager.handle_world_click(_enemy_cell()), "enemy click should be handled")
	_expect(ec.hp == hp_before - 1, "phlegm should deal 1 damage")
	_expect(_manager.player_combatant().act_used, "act should be consumed")
	_expect(ui.armed_ability == &"" and ui.target_mode == CombatUI.TargetMode.IDLE,
		"successful use should release the armed ability")
	_pass_turn()

func _test_out_of_range_rejected() -> void:
	var ui := _ui()
	# The enemy AI closed to melee during _pass_turn — reset to a
	# deterministic distance-2 setup first.
	var pc := _manager.player_combatant()
	var ec := _manager.enemy_combatant()
	_manager.session.move_combatant_to(pc, _w(Vector2i(3, 4)), 0)
	_manager.session.move_combatant_to(ec, _w(Vector2i(5, 5)), 0)
	# KEY_1 arms Frenzy (range 1); distance 2 must reject the click.
	ui._unhandled_input(_key(KEY_1))
	_expect(ui.armed_ability == &"frenzy", "key 1 should arm frenzy")
	var hp_before: int = ec.hp
	_manager.handle_world_click(_enemy_cell())
	_expect(ec.hp == hp_before, "out-of-range click must not deal damage")
	_expect(ui.armed_ability == &"frenzy",
		"failed targeting should keep the ability armed")
	# Teleport both combatants adjacent, then the same click works.
	_manager.session.move_combatant_to(pc, _w(Vector2i(4, 5)), 0)
	_manager.session.move_combatant_to(ec, _w(Vector2i(5, 4)), 0)
	_manager.handle_world_click(_enemy_cell())
	_expect(ec.hp == hp_before - 2, "adjacent frenzy should deal 2")
	_pass_turn()

# ------------------------------------------------------------------
# Escape + Drowsiness
# ------------------------------------------------------------------

func _test_escape_cancels() -> void:
	var ui := _ui()
	ui._unhandled_input(_key(KEY_1))
	_expect(ui.armed_ability == &"frenzy", "frenzy should arm")
	ui._unhandled_input(_key(KEY_ESCAPE))
	_expect(ui.target_mode == CombatUI.TargetMode.IDLE
		and ui.armed_ability == &"",
		"escape should cancel targeting")

func _test_drowsiness_key() -> void:
	var ui := _ui()
	var session := _manager.session
	# KEY_3 is Somnolencia: self/no-range -> resolves immediately,
	# ends the turn, grants the +2 bonus.
	ui._unhandled_input(_key(KEY_3))
	var pc := _manager.player_combatant()
	_expect(pc.skillset.drowsiness_bonus == CombatSkillset.DROWSINESS_BONUS,
		"drowsiness should grant the bonus")
	_expect(session.is_turn(CombatManager.ENEMY_ID),
		"drowsiness should end the turn immediately")
	# The bonus survives the enemy turn and empowers the next attack.
	_manager.enemy_take_turn()
	_expect(session.is_turn(CombatManager.PLAYER_ID),
		"turn should return to the player")
	_expect(pc.skillset.drowsiness_bonus == CombatSkillset.DROWSINESS_BONUS,
		"bonus must persist through the enemy turn")

# ------------------------------------------------------------------
# Bonus damage through the hotbar
# ------------------------------------------------------------------

func _test_bonus_damage_via_hotbar() -> void:
	var ui := _ui()
	var ec := _manager.enemy_combatant()
	var hp_before: int = ec.hp
	# KEY_1 -> Frenzy, now adjacent from the earlier teleport.
	ui._unhandled_input(_key(KEY_1))
	_manager.handle_world_click(_enemy_cell())
	_expect(ec.hp == hp_before - 4,
		"frenzy should deal 4 (2+2 bonus), got %d->%d" % [hp_before, ec.hp])
	_expect(_manager.player_combatant().skillset.drowsiness_bonus == 0,
		"bonus must be consumed")
	_pass_turn()

# ------------------------------------------------------------------
# Unavailable states
# ------------------------------------------------------------------

func _test_unavailable_reason() -> void:
	var ui := _ui()
	# Use the act, then pressing any ability key must surface a reason
	# instead of executing.
	ui._unhandled_input(_key(KEY_1))
	_manager.handle_world_click(_enemy_cell())
	var status_before: String = ui._status.text
	ui._unhandled_input(_key(KEY_2))
	_expect(ui._status.text != "" and ui._status.text != status_before
		or ui._status.text == ui.format_reason(&"act_used"),
		"unusable slot should show a reason, got '%s'" % ui._status.text)
	_expect(ui.armed_ability == &"",
		"unusable slot must not arm")
	# Fresh turn for the victory check (the Act was spent above).
	_pass_turn()

# ------------------------------------------------------------------
# Victory teardown
# ------------------------------------------------------------------

func _test_victory_hides_hotbar() -> void:
	var ui := _ui()
	var ec := _manager.enemy_combatant()
	if ec == null:
		_expect(false, "enemy missing for victory test")
		return
	ec.hp = 1
	ui._unhandled_input(_key(KEY_1))
	_manager.handle_world_click(_enemy_cell())
	_expect(_manager.session == null, "lethal hit should end the encounter")
	_expect(not ui._hotbar.visible, "hotbar should hide after victory")
	_expect(not ui.is_combat_visible(), "combat UI should hide")

func _report() -> void:
	if _failures.is_empty():
		print("COMBAT_HOTBAR_SMOKE: OK")
	else:
		for failure in _failures:
			push_error("COMBAT_HOTBAR_SMOKE FAIL: " + failure)
		print("COMBAT_HOTBAR_SMOKE: FAILED (%d)" % _failures.size())
