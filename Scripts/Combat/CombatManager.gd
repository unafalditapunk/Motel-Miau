class_name CombatManager
extends Node2D

## First playable encounter orchestrator. Bridges the real Player and
## a prototype CombatEnemy into a CombatSession/CombatActionResolver
## fight, drives the CombatUI, runs the deterministic enemy turn, and
## restores exploration when the encounter ends.
##
## Single-player prototype scope: no combat RPCs, no persistence, no
## generalized interaction framework. Multiplayer peers (mode != OFF)
## never spawn enemies and refuse to start encounters — the manager
## exists but stays inert on dedicated servers and clients.

const INTERACT_KEY := KEY_E
const INTERACT_RANGE := 2
const PLAYER_ID := &"player"
const ENEMY_ID := &"enemy"
const PLAYER_TEAM := &"players"
const ENEMY_TEAM := &"enemies"
const PLAYER_HP := 20
const ENEMY_HP := 8
const MOVE_BUDGET := 4
## Move-mode cell markers (Assets/Sprites/Combat/Tiles). Purely
## cosmetic — they never feed back into combat rules.
const WALKABLE_TILE_PATH := "res://Assets/Sprites/Combat/Tiles/valid_walkable_cell_tile.png"
const PATH_TILE_PATH := "res://Assets/Sprites/Combat/Tiles/preview_walkable_path_cell_tile.png"
## Delay before the prototype enemy acts, so the player can read the
## turn change. Tests raise this and drive enemy_take_turn() directly.
var enemy_turn_delay := 0.45

var player: Player
var enemy: CombatEnemy
## Persistent character progression (CharacterProgression node).
## Null in tests/fixtures — the player then fights with an empty
## skillset (basic attack only), exactly like pre-discipline builds.
var character_progression: CharacterProgression
var session: CombatSession
var resolver: CombatActionResolver
var combat_grid: CombatGrid
var ui: CombatUI
var highlights: CombatHighlights

var _player_combatant: Combatant
var _enemy_combatant: Combatant
var _enemy_thinking := false
var _floor_manager: FloorManager
var _floor_hooked := false
## World-cell path (incl. origin) computed just before resolver.move;
## _on_combatant_moved consumes it to drive the player's walk
## animation instead of a place_at teleport. Empty = no anim pending.
var _pending_player_path: Array[Vector2i] = []
## Room the active encounter belongs to; teardown only re-syncs the
## player visual when they never left it (floor switches re-place
## the player themselves).
var _combat_room: Room
## Edge detector for the walk animation: the UI disables its buttons
## while player_visual_busy() is true, but no session signal fires
## when the path drains — refresh on the busy->idle transition.
var _player_anim_was_busy := false
## Reachable-cell cache filled by refresh_highlights while MOVE
## targeting is armed; the hover path preview reuses it so the BFS
## runs once per mode entry, not per mouse frame.
var _reachable_cache := {}
## Last hovered cell the path preview was computed for; recomputes
## only when the cursor actually changes cells.
var _preview_cell := Vector2i.ZERO
var _preview_valid := false
var _walkable_tile: Texture2D
var _path_tile: Texture2D

func _ready() -> void:
	add_to_group(&"combat_managers")
	ui = CombatUI.new()
	ui.name = "CombatUI"
	add_child(ui)
	ui.bind(self)
	highlights = CombatHighlights.new()
	highlights.name = "CombatHighlights"
	# z_index clamps at ±4096; entities depth-sort into the same
	# range, so top-of-range plus later tree order keeps the tints
	# above sprites. Translucent fills keep the scene visible.
	highlights.z_index = 4096
	add_child(highlights)
	_walkable_tile = _load_tile(WALKABLE_TILE_PATH)
	_path_tile = _load_tile(PATH_TILE_PATH)

static func _load_tile(path: String) -> Texture2D:
	# exists() guard: load() logs an engine error per missing file.
	if not ResourceLoader.exists(path):
		push_warning("CombatManager: missing combat tile '%s'." % path)
		return null
	return load(path) as Texture2D

func bind_player(p: Player) -> void:
	player = p
	_ensure_floor_hook()

## The floor_switched hook needs the SceneTree, which isn't available
## when bind_player runs before the node enters the tree (tests add
## the manager during SceneTree._initialize). Retry from _process.
func _ensure_floor_hook() -> void:
	if _floor_hooked or not is_inside_tree():
		return
	_floor_hooked = true
	_floor_manager = get_tree().get_first_node_in_group(&"floor_managers") as FloorManager
	if _floor_manager != null \
			and not _floor_manager.floor_switched.is_connected(_on_floor_switched):
		_floor_manager.floor_switched.connect(_on_floor_switched)

static func find_manager(tree: SceneTree) -> CombatManager:
	if tree == null:
		return null
	for node in tree.get_nodes_in_group(&"combat_managers"):
		var manager := node as CombatManager
		if manager != null:
			return manager
	return null

## True while any encounter is ACTIVE. Player movement, building
## input, and modal panels check this to lock down exploration.
static func any_active(tree: SceneTree) -> bool:
	if tree == null:
		return false
	for node in tree.get_nodes_in_group(&"combat_managers"):
		var manager := node as CombatManager
		if manager != null and manager.session != null \
				and manager.session.state == CombatSession.State.ACTIVE:
			return true
	return false

func _process(_delta: float) -> void:
	_ensure_floor_hook()
	_update_prompt()
	_update_move_preview()
	var busy := player_visual_busy()
	if _player_anim_was_busy and not busy and ui != null \
			and session != null and session.state == CombatSession.State.ACTIVE:
		ui.refresh()
	_player_anim_was_busy = busy

func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventKey):
		return
	var key_event := event as InputEventKey
	if not key_event.pressed or key_event.echo:
		return
	if key_event.physical_keycode != INTERACT_KEY \
			and key_event.keycode != INTERACT_KEY:
		return
	if try_interact():
		get_viewport().set_input_as_handled()

# ------------------------------------------------------------------
# Interaction (E — Enfrentar)
# ------------------------------------------------------------------

func _update_prompt() -> void:
	if ui == null:
		return
	if enemy == null or not is_instance_valid(enemy):
		ui.set_prompt(Vector2.ZERO, false)
		return
	var prompt_on := _can_interact()
	if prompt_on:
		var screen_pos := get_viewport().get_canvas_transform() * enemy.global_position
		ui.set_prompt(screen_pos, true)
	else:
		ui.set_prompt(Vector2.ZERO, false)

func _can_interact() -> bool:
	if enemy == null or not is_instance_valid(enemy):
		return false
	if session != null:
		return false
	if player == null or not is_instance_valid(player) or player.room == null:
		return false
	if player.room != enemy.room or player._is_moving:
		return false
	if not _mp_allows_combat() or _modal_open():
		return false
	return CombatGrid.get_distance(_player_world_cell(), enemy.world_cell) <= INTERACT_RANGE

func _modal_open() -> bool:
	var tree := get_tree()
	if FloorPanel.any_open(tree) or AvatarPanel.any_open(tree) \
			or DisciplinePanel.any_open(tree) \
			or FloorEditor.any_active(tree) or TransitionOverlay.any_active(tree):
		return true
	var controller := tree.get_first_node_in_group(&"block_placement_controller") as BlockPlacementController
	return controller != null and controller.construction_mode

func _mp_allows_combat() -> bool:
	var mm := get_tree().get_first_node_in_group(&"multiplayer_manager") as MultiplayerManager
	return mm == null or mm.mode == MultiplayerManager.Mode.OFF

## Attempts to start the encounter. Returns false (no side effects)
## when out of range, mid-motion, in a modal, in multiplayer, or when
## a session is already running — repeated E presses can't duplicate.
func try_interact() -> bool:
	if not _can_interact():
		return false
	return start_encounter()

func start_encounter() -> bool:
	if not _can_interact():
		return false
	var room := player.room
	if room == null or player.block_layer == null or room.grid == null:
		return false

	combat_grid = CombatGrid.new()
	combat_grid.setup(player.block_layer, room)
	session = CombatSession.new()
	session.setup(combat_grid)
	_player_combatant = Combatant.new(PLAYER_ID, "You", PLAYER_TEAM,
		_player_world_cell(), PLAYER_HP, player.elevation,
		player.height_units, MOVE_BUDGET, player.max_step_height)
	# Per-encounter skillset: equipped ∩ unlocked, temp effects die
	# with the combatant on teardown.
	_player_combatant.skillset = CombatSkillset.from_progression(
		character_progression)
	_enemy_combatant = Combatant.new(ENEMY_ID, enemy.display_name, ENEMY_TEAM,
		enemy.world_cell, ENEMY_HP, enemy.elevation,
		enemy.height_units, MOVE_BUDGET, 1.0)
	# Signals connect before start(): start() emits the opening
	# turn_changed, and the UI must see it.
	session.turn_changed.connect(_on_turn_changed)
	session.combatant_moved.connect(_on_combatant_moved)
	session.attack_resolved.connect(_on_attack_resolved)
	session.encounter_ended.connect(_on_encounter_ended)
	# Player registers first: registration order is turn order, so the
	# player always opens the fight.
	if not session.add_combatant(_player_combatant) \
			or not session.add_combatant(_enemy_combatant) \
			or not session.start():
		_teardown_session()
		return false
	resolver = CombatActionResolver.new()
	resolver.setup(session)
	_combat_room = room
	# CombatHighlights._draw early-returns without a grid.
	highlights.grid = room.grid
	ui.begin()
	return true

# ------------------------------------------------------------------
# Session events
# ------------------------------------------------------------------

func _on_turn_changed(combatant: Combatant, _round: int) -> void:
	if ui != null:
		ui.refresh()
	if combatant != null and combatant.id == ENEMY_ID \
			and session != null and session.state == CombatSession.State.ACTIVE:
		_schedule_enemy_turn()

func _on_combatant_moved(combatant: Combatant, from: Vector2i,
		to: Vector2i, _cost: int) -> void:
	if combatant.id == PLAYER_ID and player != null and player.room != null:
		if _pending_player_path.size() > 1:
			# resolver.move already committed the logical destination;
			# walk the sprite through the validated path cell by cell.
			var steps: Array = []
			for i in range(1, _pending_player_path.size()):
				var w: Vector2i = _pending_player_path[i]
				steps.append({
					"cell": w - player.room.cell_origin,
					"elev": combat_grid.stand_elevation_at(w) if combat_grid != null else 0.0,
				})
			player.start_combat_path(steps)
			_pending_player_path = []
		else:
			# No path (teleport-style moves, tests): snap as before.
			player.place_at(to - player.room.cell_origin, combatant.elevation)
	elif combatant.id == ENEMY_ID and enemy != null:
		var path := _path_between(combatant, from, to)
		if path.size() > 1:
			enemy.animate_to_path(path)
		else:
			enemy.place_at_world(to, combatant.elevation)
	if ui != null:
		ui.refresh()

func _on_attack_resolved(actor: Combatant, target: Combatant,
		damage: int, target_hp: int) -> void:
	if ui != null:
		ui.set_status("%s hits %s for %d (%d left)" % [
			actor.display_name, target.display_name, damage, target_hp])
		ui.refresh()
	# Cosmetic clips only — the session already committed the result.
	# The enemy queues them behind any in-flight walk slide.
	if enemy != null and is_instance_valid(enemy):
		if actor.id == ENEMY_ID:
			enemy.face_toward_world(_player_world_cell())
			enemy.play_attack()
		if target.id == ENEMY_ID:
			enemy.play_attacked()
			if target_hp <= 0:
				enemy.play_death()

func _on_encounter_ended(_state: int, end_reason: int, winning_team: StringName) -> void:
	var text := "The encounter ends."
	if end_reason == CombatSession.EndReason.VICTORY:
		text = "Victory!" if winning_team == PLAYER_TEAM else "Defeat..."
	elif end_reason == CombatSession.EndReason.DRAW:
		text = "Draw."
	elif end_reason == CombatSession.EndReason.CANCELLED:
		text = "You slip away."
	# Prototype mercy rule: defeat never locks the player — there is
	# no death/respawn system yet, the fight simply ends.
	_teardown_session()
	if ui != null:
		ui.show_result(text)
		ui.set_prompt(Vector2.ZERO, false)

func _teardown_session() -> void:
	# If a walk animation was still playing (teardown mid-path), snap
	# the player to the combatant's committed cell so exploration
	# resumes from a consistent position. Skipped when a floor switch
	# already re-placed the player into a different room.
	if player != null and player.room != null and player.room == _combat_room \
			and _player_combatant != null:
		player.place_at(_player_combatant.cell - player.room.cell_origin,
			_player_combatant.elevation)
	session = null
	resolver = null
	combat_grid = null
	_player_combatant = null
	_enemy_combatant = null
	_enemy_thinking = false
	_pending_player_path = []
	_combat_room = null
	_reachable_cache = {}
	_preview_valid = false
	highlights.grid = null
	highlights.clear()
	if enemy != null and is_instance_valid(enemy):
		# A playing death clip frees itself on finish; freeing now
		# would cut it off mid-animation.
		if not enemy.death_pending:
			enemy.queue_free()
	enemy = null
	if ui != null:
		ui.target_mode = CombatUI.TargetMode.IDLE

# ------------------------------------------------------------------
# Enemy turn (deterministic prototype AI)
# ------------------------------------------------------------------

func _schedule_enemy_turn() -> void:
	if _enemy_thinking:
		return
	_enemy_thinking = true
	await get_tree().create_timer(enemy_turn_delay).timeout
	_enemy_thinking = false
	if not is_inside_tree() or session == null \
			or session.state != CombatSession.State.ACTIVE:
		return
	if not session.is_turn(ENEMY_ID):
		return
	enemy_take_turn()

## One full enemy turn, synchronous so tests can drive it directly:
## attack when possible, else step toward the player through the same
## CombatGrid/CombatActionResolver rules the player uses, attack again
## if the move closed to range, then end the turn.
func enemy_take_turn() -> void:
	# Local ref: a killing attack ends the encounter and _teardown
	# nulls the member mid-turn; the session object itself stays
	# valid and end_turn() safely no-ops once state leaves ACTIVE.
	var s := session
	if s == null or resolver == null or combat_grid == null \
			or s.state != CombatSession.State.ACTIVE:
		return
	if _enemy_combatant == null or not _enemy_combatant.is_alive():
		s.end_turn()
		return
	if _player_combatant == null or not _player_combatant.is_alive():
		s.end_turn()
		return
	if not _enemy_can_attack():
		var dest := _enemy_best_move()
		if dest != _enemy_combatant.cell:
			resolver.move(ENEMY_ID, dest)
	if _enemy_can_attack():
		resolver.attack(ENEMY_ID, PLAYER_ID)
	s.end_turn()

func _enemy_can_attack() -> bool:
	if _enemy_combatant == null or _player_combatant == null:
		return false
	if _enemy_combatant.act_used or not _player_combatant.is_alive():
		return false
	if CombatGrid.get_distance(_enemy_combatant.cell, _player_combatant.cell) != 1:
		return false
	return combat_grid.has_line_of_sight(_enemy_combatant.cell, _enemy_combatant.elevation,
		_enemy_combatant.height, _player_combatant.cell, _player_combatant.elevation,
		_player_combatant.height)

## Greedy step: the reachable cell that minimizes Chebyshev distance
## to the player, ties broken by lower movement cost. Returns the
## enemy's own cell when nothing reachable improves the approach.
func _enemy_best_move() -> Vector2i:
	var blocked := _blocked_for(ENEMY_ID)
	var reachable := combat_grid.get_reachable_cells(_enemy_combatant.cell,
		_enemy_combatant.elevation, _enemy_combatant.move_budget,
		_enemy_combatant.height, _enemy_combatant.max_step_height, blocked)
	var best := _enemy_combatant.cell
	var best_dist := CombatGrid.get_distance(best, _player_combatant.cell)
	var best_cost := 0
	for cell in reachable:
		var dist := CombatGrid.get_distance(cell, _player_combatant.cell)
		var cost: int = reachable[cell]
		if dist < best_dist or (dist == best_dist and cost < best_cost):
			best = cell
			best_dist = dist
			best_cost = cost
	return best

# ------------------------------------------------------------------
# Player-facing actions (UI + tests)
# ------------------------------------------------------------------

func player_combatant() -> Combatant:
	return _player_combatant

func enemy_combatant() -> Combatant:
	return _enemy_combatant

## True while the player's combat walk animation is still playing.
## Combat actions and turn end are refused until it finishes.
func player_visual_busy() -> bool:
	return player != null and player.combat_move_active

func player_turn_active() -> bool:
	return session != null and session.state == CombatSession.State.ACTIVE \
		and session.is_turn(PLAYER_ID)

func _player_world_cell() -> Vector2i:
	if player == null or player.room == null:
		return Vector2i.ZERO
	return player.room.world_cell_coordinates(player.grid_position)

func _blocked_for(combatant_id: StringName) -> Array[Vector2i]:
	var blocked: Array[Vector2i] = []
	if session == null:
		return blocked
	for c in session.combatants:
		if c.id != combatant_id:
			blocked.append(c.cell)
	return blocked

## get_path between two cells for a session combatant, using the
## combatant's own movement stats and current occupancy as blockers.
func _path_between(combatant: Combatant, from_cell: Vector2i,
		to_cell: Vector2i) -> Array[Vector2i]:
	if combat_grid == null or combatant == null or session == null:
		return []
	return combat_grid.get_path(from_cell,
		combat_grid.stand_elevation_at(from_cell), to_cell,
		combatant.move_budget, combatant.height, combatant.max_step_height,
		_blocked_for(combatant.id))

## Reachable world cells for the player's Move targeting. Empty when
## it isn't the player's turn or movement is already spent.
func reachable_for_player() -> Dictionary:
	if not player_turn_active() or _player_combatant == null \
			or _player_combatant.move_used or combat_grid == null:
		return {}
	return combat_grid.get_reachable_cells(_player_combatant.cell,
		_player_combatant.elevation, _player_combatant.move_budget,
		_player_combatant.height, _player_combatant.max_step_height,
		_blocked_for(PLAYER_ID))

func select_move_mode() -> void:
	if player_turn_active() and ui != null:
		ui.set_target_mode(CombatUI.TargetMode.MOVE)

func select_attack_mode() -> void:
	if player_turn_active() and ui != null:
		ui.set_target_mode(CombatUI.TargetMode.ATTACK)

func player_end_turn() -> void:
	if session != null and session.state == CombatSession.State.ACTIVE \
			and session.is_turn(PLAYER_ID) and not player_visual_busy():
		session.end_turn()

## Click resolution while a targeting mode is armed. Returns true
## when the click was consumed as a combat action.
func handle_world_click(world_cell: Vector2i) -> bool:
	if ui == null or session == null or session.state != CombatSession.State.ACTIVE \
			or player_visual_busy():
		return false
	match ui.target_mode:
		CombatUI.TargetMode.MOVE:
			var result := player_move_to(world_cell)
			if bool(result.get("ok", false)):
				ui.set_target_mode(CombatUI.TargetMode.IDLE)
			return true
		CombatUI.TargetMode.ATTACK:
			# The sprite is taller than its cell, so clicks on the
			# enemy's body land on neighbouring cells — accept anything
			# within the armed ability's range of the target's cell.
			var ability_range := _armed_ability_range()
			if _enemy_combatant != null \
					and CombatGrid.get_distance(world_cell, _enemy_combatant.cell) <= ability_range:
				if ui.armed_ability != &"":
					player_use_ability(ui.armed_ability)
				else:
					player_attack()
				ui.set_target_mode(CombatUI.TargetMode.IDLE)
			else:
				ui.set_status("Select the %s." % _enemy_combatant.display_name.to_lower())
			return true
	return false

## Chebyshev range of the currently armed ability, or 1 for the
## basic attack (armed_ability == &"").
func _armed_ability_range() -> int:
	if ui == null or ui.armed_ability == &"":
		return 1
	return int(AbilityCatalog.ability(ui.armed_ability).get("range", 1))

func player_move_to(world_cell: Vector2i) -> Dictionary:
	var result := {"ok": false, "reason": &"not_active"}
	if player_visual_busy():
		result["reason"] = &"moving"
	elif resolver != null:
		# Path is computed while the combatant still sits on its origin
		# cell; the combatant_moved signal (fired inside resolver.move)
		# consumes it to animate the walk.
		_pending_player_path = _path_for_dest(world_cell)
		result = resolver.move(PLAYER_ID, world_cell)
		_pending_player_path = []
	if ui != null:
		if bool(result.get("ok", false)):
			ui.set_status("")
		else:
			ui.set_status(ui.format_reason(result.get("reason", &"invalid")))
	return result

func _path_for_dest(world_cell: Vector2i) -> Array[Vector2i]:
	if _player_combatant == null:
		return []
	return _path_between(_player_combatant, _player_combatant.cell, world_cell)

func player_attack() -> Dictionary:
	var result := {"ok": false, "reason": &"not_active"}
	if player_visual_busy():
		result["reason"] = &"moving"
	elif resolver != null:
		result = resolver.attack(PLAYER_ID, ENEMY_ID)
	if ui != null:
		if bool(result.get("ok", false)):
			ui.set_status("")
		else:
			ui.set_status(ui.format_reason(result.get("reason", &"invalid")))
	return result

# ------------------------------------------------------------------
# Discipline abilities (player-facing)
# ------------------------------------------------------------------

## The player's per-encounter skillset, or null before/after combat.
func player_skillset() -> CombatSkillset:
	return _player_combatant.skillset if _player_combatant != null else null

## Ability ids the player can currently arm: equipped actives and
## ultimates from the skillset (passives never appear).
func player_ability_ids() -> Array:
	var ids: Array = []
	var skillset := player_skillset()
	if skillset == null:
		return ids
	for ability_id in skillset.available:
		var def := AbilityCatalog.ability(ability_id)
		if not def.is_empty() \
				and StringName(def.get("kind", &"")) != &"passive":
			ids.append(ability_id)
	return ids

## Arms an ability for click targeting. Self/no-range abilities are
## used immediately by the UI instead of arming.
func select_ability_mode(ability_id: StringName) -> void:
	if player_turn_active() and ui != null:
		ui.armed_ability = ability_id
		ui.set_target_mode(CombatUI.TargetMode.ATTACK)

## Executes an equipped ability against the encounter's enemy (the
## prototype has exactly one). Self-targeting abilities ignore the
## target. A successful ends_turn ability (Drowsiness) ends the turn
## immediately, per design.
func player_use_ability(ability_id: StringName) -> Dictionary:
	var result := {"ok": false, "reason": &"not_active"}
	if player_visual_busy():
		result["reason"] = &"moving"
	elif resolver != null and _enemy_combatant != null:
		result = resolver.use_ability(PLAYER_ID, ENEMY_ID, ability_id)
		if bool(result.get("ok", false)) and bool(result.get("ends_turn", false)):
			player_end_turn()
	if ui != null:
		if bool(result.get("ok", false)):
			ui.set_status("")
		else:
			ui.set_status(ui.format_reason(result.get("reason", &"invalid")))
	return result

func refresh_highlights() -> void:
	if highlights == null:
		return
	var list: Array = []
	if session != null and session.state == CombatSession.State.ACTIVE \
			and ui != null and combat_grid != null and player != null \
			and player.room != null:
		match ui.target_mode:
			CombatUI.TargetMode.MOVE:
				_reachable_cache = reachable_for_player()
				for cell in _reachable_cache:
					list.append(_cell_marker(cell, _walkable_tile,
						Color(0.3, 0.9, 0.4, 0.28)))
			CombatUI.TargetMode.ATTACK:
				_reachable_cache = {}
				if _enemy_combatant != null:
					list.append({
						"pos": _cell_canvas_pos(_enemy_combatant.cell),
						"color": Color(0.95, 0.3, 0.3, 0.35),
					})
			_:
				_reachable_cache = {}
	highlights.set_markers(list)

func _cell_canvas_pos(world_cell: Vector2i) -> Vector2:
	var grid := player.room.grid
	var elev := combat_grid.stand_elevation_at(world_cell) if combat_grid != null else 0.0
	return grid.grid_to_screen_position(Vector2(world_cell), elev)

## Hover path preview for MOVE targeting: while a reachable cell is
## under the cursor, lay the path-tile sprite along the same
## get_path route the walk animation will follow. Purely cosmetic —
## it never feeds back into combat rules.
func _update_move_preview() -> void:
	if highlights == null:
		return
	var active := ui != null and ui.target_mode == CombatUI.TargetMode.MOVE \
		and session != null and session.state == CombatSession.State.ACTIVE \
		and player_turn_active() and not player_visual_busy() \
		and combat_grid != null and player != null and player.room != null
	if not active:
		if _preview_valid:
			_preview_valid = false
			highlights.set_preview([])
		return
	var cell := ui.world_cell_at_mouse()
	if _preview_valid and cell == _preview_cell:
		return
	_preview_cell = cell
	_preview_valid = true
	var list: Array = []
	if _path_tile != null and _player_combatant != null \
			and _reachable_cache.has(cell):
		var path := _path_for_dest(cell)
		# Skip index 0 — that's the player's own cell.
		for i in range(1, path.size()):
			list.append(_cell_marker(path[i], _path_tile, Color(1, 1, 1, 0)))
	highlights.set_preview(list)

## Marker dict for one world cell: canvas pos plus the cell's surface
## z-depth so textured markers occlude like normal tiles. The color
## is only a fallback tint when the texture is missing.
func _cell_marker(world_cell: Vector2i, texture: Texture2D,
		tint: Color) -> Dictionary:
	var elev := combat_grid.stand_elevation_at(world_cell) \
		if combat_grid != null else 0.0
	var depth := 0
	var block_layer := player.block_layer if player != null else null
	if block_layer != null:
		depth = clampi(block_layer.depth_for_cell(
			world_cell - block_layer.cell_origin, elev), -4096, 4096)
	return {
		"pos": _cell_canvas_pos(world_cell),
		"depth": depth,
		"texture": texture,
		"color": tint,
	}

# ------------------------------------------------------------------
# Enemy spawning (prototype, single-player only)
# ------------------------------------------------------------------

## Spawns the prototype enemy on an explicit room-local cell. Used by
## tests and debug tooling; the game uses spawn_prototype_enemy().
func spawn_enemy_at(room: Room, local_cell: Vector2i) -> CombatEnemy:
	if room == null or room.block_layer == null or room.grid == null:
		return null
	var world_cell := room.world_cell_coordinates(local_cell)
	if world_cell == _player_world_cell():
		push_warning("CombatManager: enemy spawn cell is the player's cell.")
		return null
	var probe := CombatGrid.new()
	probe.setup(room.block_layer, room)
	if not probe.can_stand(world_cell, 2.0):
		push_warning("CombatManager: enemy spawn cell %s is not standable." % world_cell)
		return null
	enemy = CombatEnemy.new()
	enemy.name = "CombatEnemy"
	enemy.room = room
	enemy.grid = room.grid
	enemy.block_layer = room.block_layer
	enemy.world_cell = world_cell
	enemy.elevation = probe.stand_elevation_at(world_cell)
	add_child(enemy)
	enemy.face_toward_world(_player_world_cell())
	return enemy

## Picks a standable cell a few steps from the player and spawns the
## prototype enemy there. Returns null when no suitable cell exists.
func spawn_prototype_enemy() -> CombatEnemy:
	if player == null or player.room == null:
		return null
	var local := _find_enemy_cell(player.room)
	if local.x < 0:
		push_warning("CombatManager: no standable enemy spawn cell found; prototype enemy not spawned.")
		return null
	return spawn_enemy_at(player.room, local)

func _find_enemy_cell(room: Room) -> Vector2i:
	var probe := CombatGrid.new()
	probe.setup(room.block_layer, room)
	var player_world := _player_world_cell()
	var preferred := player_world + Vector2i(3, 0)
	var best := Vector2i(-1, -1)
	var best_score := 1 << 30
	for y in room.size.y:
		for x in room.size.x:
			var local := Vector2i(x, y)
			if room.has_footprint_cell(local) == false:
				continue
			var world_cell := room.world_cell_coordinates(local)
			if world_cell == player_world:
				continue
			if not probe.can_stand(world_cell, 2.0):
				continue
			var dist := CombatGrid.get_distance(world_cell, player_world)
			if dist < 3 or dist > 6:
				continue
			var score := CombatGrid.get_distance(world_cell, preferred) * 10 - dist
			if score < best_score:
				best_score = score
				best = local
	return best

# ------------------------------------------------------------------
# Lifecycle safety
# ------------------------------------------------------------------

## Floor switches invalidate every room-scoped ref the encounter
## used; end any active fight and despawn the prototype enemy (it
## belonged to the old floor's world and is not persisted).
func _on_floor_switched(_floor_def: Floor) -> void:
	if session != null:
		session.end_encounter()
	# A floor switch re-places the player anyway; this also clears any
	# in-flight combat walk so combat_move_active can't get stuck.
	if player != null:
		player.snap_to_surface()
	if enemy != null and is_instance_valid(enemy):
		enemy.queue_free()
		enemy = null
