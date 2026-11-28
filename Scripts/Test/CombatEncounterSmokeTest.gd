extends SceneTree

## CombatEncounter smoke test: drives a real Player node and a
## CombatManager through the first playable encounter — interaction
## range, E-to-start (once), combat movement syncing the player,
## the deterministic enemy turn, attack/victory/defeat teardown, and
## the input guards. Same deterministic 8x8 room fixture as
## CombatSessionSmokeTest (world = local + (50,50)); the enemy sits at
## local (5,5), the player walks local (2,4) -> (3,4) to get in range.
##
## enemy_turn_delay is raised so the scheduled AI never fires; the
## test calls enemy_take_turn() directly for determinism.

const ROOM_SCENE := "res://Scenes/World/Room.tscn"
const BLOCK_SCENE := "res://Scenes/Objects/Block.tscn"
const PLAYER_SCENE := "res://Scenes/Player/Player.tscn"
const GRID_PATH := "res://Resources/IsometricGrid/TestGrid.tres"
const BLOCK_CATALOG_PATH := "res://Resources/BlockCatalog.tres"
const FURNITURE_CATALOG_PATH := "res://Resources/FurnitureCatalog.tres"
const TILE_CATALOG_PATH := "res://Resources/TileCatalog.tres"
const ROOM_ORIGIN := Vector2i(50, 50)
const ROOM_SIZE := Vector2i(8, 8)

var _room: Room
var _blocks: BlockLayer
var _grid: IsometricGrid
var _player: Player
var _manager: CombatManager
var _frames := 0
var _phase := 0
var _wait_frames := 0
var _failures: Array[String] = []

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

	var chair := _blocks.furniture_catalog.get_definition(&"chair")
	_blocks.place_furniture(chair, Vector2i(3, 3), 0.0, 0)
	var standard := _blocks.get_definition(&"standard_block")
	_blocks.place_block(standard, Vector2i(3, 0), 0.0)
	_blocks.place_block(standard, Vector2i(3, 0), 1.0)

	_player = (load(PLAYER_SCENE) as PackedScene).instantiate() as Player
	_player.grid = _grid
	_player.block_layer = _blocks
	_player.room = _room
	_player.room_size = ROOM_SIZE
	_player.room_world = null
	_player.grid_position = Vector2i(2, 4)
	_player.elevation = 0.0
	root.add_child(_player)

	_manager = CombatManager.new()
	_manager.name = "CombatManager"
	root.add_child(_manager)
	_manager.bind_player(_player)
	_manager.enemy_turn_delay = 3600.0
	# Fast steps so the animated path finishes within a few frames.
	_player.combat_move_duration = 0.01

func _process(_delta: float) -> bool:
	_frames += 1
	if _frames < 3:
		return false
	if _phase == 0:
		_phase = 1
		_run_phase0()
	elif _phase == 1:
		# Wait for the combat walk animation to drain (real-time
		# duration), with a generous frame cap.
		if _player.combat_move_active and _wait_frames < 600:
			_wait_frames += 1
			return false
		_run_phase1()
		_report()
		quit()
		return true
	return false

func _run_phase0() -> void:
	_test_enemy_spawn_and_prompt()
	_test_encounter_start()
	_test_combat_move_starts_animation()

func _run_phase1() -> void:
	_test_combat_move_completes()
	_test_enemy_turn()
	_test_attack_and_victory()
	_test_defeat_and_cleanup()
	_test_input_guards_after()

func _expect(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)

func _w(local: Vector2i) -> Vector2i:
	return local + ROOM_ORIGIN

func _report() -> void:
	if _failures.is_empty():
		print("COMBAT_ENCOUNTER_SMOKE: OK")
	else:
		for failure in _failures:
			printerr("COMBAT_ENCOUNTER_SMOKE FAIL: " + failure)
		print("COMBAT_ENCOUNTER_SMOKE: %d failure(s)" % _failures.size())

# ------------------------------------------------------------------
# Interaction
# ------------------------------------------------------------------

func _test_enemy_spawn_and_prompt() -> void:
	var enemy := _manager.spawn_enemy_at(_room, Vector2i(5, 5))
	_expect(enemy != null, "spawn_enemy_at should create the enemy")
	if enemy == null:
		return
	_expect(enemy.world_cell == _w(Vector2i(5, 5)), "enemy world cell wrong")
	# Player at local (2,4) -> world (52,54); enemy (55,55): dist 3.
	_expect(not _manager._can_interact(), "prompt should be off out of range")
	_player.place_at(Vector2i(3, 4), 0.0)
	_expect(_manager._can_interact(), "prompt should be on in range")

# ------------------------------------------------------------------
# Encounter start
# ------------------------------------------------------------------

func _test_encounter_start() -> void:
	_expect(_manager.try_interact(), "E in range should start the encounter")
	var session := _manager.session
	_expect(session != null and session.state == CombatSession.State.ACTIVE,
		"session should be ACTIVE after interact")
	_expect(not _manager.try_interact(), "second interact must not duplicate")
	_expect(_manager.session == session, "second interact changed the session")
	var pc := _manager.player_combatant()
	var ec := _manager.enemy_combatant()
	_expect(pc != null and pc.id == CombatManager.PLAYER_ID, "player combatant missing")
	_expect(ec != null and ec.id == CombatManager.ENEMY_ID, "enemy combatant missing")
	_expect(pc != null and pc.cell == _w(Vector2i(3, 4)), "player combatant cell wrong")
	_expect(ec != null and ec.cell == _w(Vector2i(5, 5)), "enemy combatant cell wrong")
	_expect(pc != null and pc.team == CombatManager.PLAYER_TEAM
		and ec != null and ec.team == CombatManager.ENEMY_TEAM, "teams wrong")
	_expect(_manager.player_turn_active(), "player should move first")
	_expect(_manager.ui.is_combat_visible(), "combat UI should be visible")
	_expect(CombatManager.any_active(self), "any_active should report combat")
	_expect(_player._world_ui_blocked(), "exploration input should be locked")

# ------------------------------------------------------------------
# Combat movement (player)
# ------------------------------------------------------------------

func _test_combat_move_starts_animation() -> void:
	var session := _manager.session
	if session == null:
		_expect(false, "no session for movement test")
		return
	var reachable := _manager.reachable_for_player()
	_expect(not reachable.is_empty(), "reachable cells should be non-empty")
	var dest := _w(Vector2i(2, 4))
	_expect(reachable.has(dest), "adjacent cell should be reachable")
	var result := _manager.player_move_to(dest)
	_expect(bool(result.get("ok", false)), "combat move should succeed")
	# Logical position commits immediately; the walk animates after.
	var pc := _manager.player_combatant()
	_expect(pc != null and pc.cell == dest, "combatant world cell not updated")
	_expect(_player.combat_move_active, "walk animation should be playing")
	_expect(_manager.player_visual_busy(), "player_visual_busy should report anim")
	# Locked while animating: second move, attack, and end turn refuse.
	var again := _manager.player_move_to(_w(Vector2i(3, 4)))
	_expect(not bool(again.get("ok", true)) and again.get("reason") == &"moving",
		"second move during animation must fail with 'moving'")
	var attack := _manager.player_attack()
	_expect(not bool(attack.get("ok", true)) and attack.get("reason") == &"moving",
		"attack during animation must fail with 'moving'")
	_manager.player_end_turn()
	_expect(session.is_turn(CombatManager.PLAYER_ID),
		"end turn during animation must be refused")
	# grid_position commits per step (same convention as exploration
	# _start_move): for this 1-step path it is already the destination.
	_expect(_player.grid_position == Vector2i(2, 4),
		"grid_position should track the step being walked")

func _test_combat_move_completes() -> void:
	var dest := _w(Vector2i(2, 4))
	_expect(not _player.combat_move_active, "walk animation should have finished")
	_expect(not _manager.player_visual_busy(), "player_visual_busy should clear")
	_expect(_player.grid_position == Vector2i(2, 4), "player local cell not updated")
	var pc := _manager.player_combatant()
	if pc == null:
		_expect(false, "player combatant missing after move")
		return
	_expect(pc.cell == dest, "combatant world cell mismatch")
	# Visual sync: the sprite must land exactly on the cell anchor.
	var expected := _grid.grid_to_screen_position(Vector2(dest), pc.elevation)
	_expect(_player.position.distance_to(expected) < 0.01,
		"player visual did not land on combat cell")
	var session := _manager.session
	if session == null:
		return
	_expect(pc.move_used, "move should consume the move")
	var attack := _manager.player_attack()
	_expect(not bool(attack.get("ok", true)), "out-of-range attack must fail")
	_expect(attack.get("reason") == &"out_of_range", "attack reason should be out_of_range")
	_expect(not pc.act_used, "failed attack must not consume the Act")

# ------------------------------------------------------------------
# Enemy turn
# ------------------------------------------------------------------

func _test_enemy_turn() -> void:
	_manager.player_end_turn()
	var session := _manager.session
	_expect(session != null and session.is_turn(CombatManager.ENEMY_ID),
		"turn should pass to the enemy")
	_expect(not _manager.player_turn_active(), "player turn should be over")
	var pc := _manager.player_combatant()
	var ec := _manager.enemy_combatant()
	var hp_before: int = pc.hp if pc != null else -1
	var cell_before: Vector2i = ec.cell if ec != null else Vector2i.ZERO
	_manager.enemy_take_turn()
	_expect(session != null and session.is_turn(CombatManager.PLAYER_ID),
		"turn should return to the player")
	_expect(ec != null and (ec.cell != cell_before or (pc != null and pc.hp < hp_before)),
		"enemy should have moved or attacked")
	if ec != null:
		_expect(_manager.enemy.world_cell == ec.cell, "enemy visual did not sync")
	_expect(pc != null and not pc.move_used and not pc.act_used,
		"new turn should reset move/act")

# ------------------------------------------------------------------
# Attack + victory
# ------------------------------------------------------------------

func _test_attack_and_victory() -> void:
	var session := _manager.session
	var pc := _manager.player_combatant()
	var ec := _manager.enemy_combatant()
	if session == null or pc == null or ec == null:
		_expect(false, "missing combatants for attack test")
		return
	# Deterministic adjacency: teleport both combatants next to each
	# other on open floor (world (52,55) / (53,55)).
	session.move_combatant_to(pc, _w(Vector2i(2, 5)), 0)
	session.move_combatant_to(ec, _w(Vector2i(3, 5)), 0)
	ec.hp = 2
	var hp_before: int = ec.hp
	var result := _manager.player_attack()
	_expect(bool(result.get("ok", false)), "adjacent attack should succeed")
	_expect(ec.hp == hp_before - CombatActionResolver.ATTACK_DAMAGE,
		"attack should deal exactly ATTACK_DAMAGE")
	_expect(pc.act_used, "successful attack must consume the Act")
	_expect(session.state == CombatSession.State.VICTORY,
		"lethal attack should end the encounter in VICTORY")
	_expect(_manager.session == null, "session should be torn down")
	_expect(_manager.enemy == null, "enemy should be despawned")
	_expect(not CombatManager.any_active(self), "any_active should clear")
	_expect(not _player._world_ui_blocked(), "exploration input should return")
	_expect(not _manager.ui.is_combat_visible(), "combat panel should hide")

# ------------------------------------------------------------------
# Defeat + cleanup
# ------------------------------------------------------------------

func _test_defeat_and_cleanup() -> void:
	# Fresh encounter: new enemy, player steps next to it.
	var enemy := _manager.spawn_enemy_at(_room, Vector2i(6, 6))
	_expect(enemy != null, "second enemy should spawn")
	if enemy == null:
		return
	_player.place_at(Vector2i(5, 6), 0.0)
	_expect(_manager.try_interact(), "second encounter should start")
	var session := _manager.session
	var pc := _manager.player_combatant()
	var ec := _manager.enemy_combatant()
	if session == null or pc == null or ec == null:
		_expect(false, "second encounter missing combatants")
		return
	pc.hp = 2
	_manager.player_end_turn()
	_expect(session.is_turn(CombatManager.ENEMY_ID), "enemy should get the turn")
	_manager.enemy_take_turn()
	_expect(session.state == CombatSession.State.VICTORY
		and session.winning_team == CombatManager.ENEMY_TEAM,
		"enemy win should be VICTORY for the enemy team")
	_expect(_manager.session == null and _manager.enemy == null,
		"defeat should tear down the encounter")
	_expect(not CombatManager.any_active(self), "any_active should clear after defeat")
	_expect(not _player._world_ui_blocked(), "input should be restored after defeat")

# ------------------------------------------------------------------
# Post-combat exploration
# ------------------------------------------------------------------

func _test_input_guards_after() -> void:
	# Normal movement works again: a cardinal step through the real
	# Player path must succeed on open floor.
	var before := _player.grid_position
	_expect(_player.move_to(before + Vector2i(0, 1)),
		"player should move normally after combat")
	_expect(_player.grid_position == before + Vector2i(0, 1),
		"player position should advance")
	# And combat cannot restart without a live enemy in range.
	_expect(not _manager._can_interact(), "no prompt without an enemy")
