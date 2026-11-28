extends SceneTree

## CombatSession/CombatActionResolver smoke test. Deterministic
## in-code fixture: one 8x8 room at cell_origin (50,50) with a chair
## (non-standable) and a 2-block column (elevation + LOS blocker).
## CombatSessions are cheap RefCounted objects — a fresh one per test.
##
## Fixture (local -> world = local + (50,50)):
##   (3,3)  chair        -> cannot stand
##   (3,0)  2x block     -> surface 2.0 (2-step, unreachable) + LOS wall

const ROOM_SCENE := "res://Scenes/World/Room.tscn"
const BLOCK_SCENE := "res://Scenes/Objects/Block.tscn"
const GRID_PATH := "res://Resources/IsometricGrid/TestGrid.tres"
const BLOCK_CATALOG_PATH := "res://Resources/BlockCatalog.tres"
const FURNITURE_CATALOG_PATH := "res://Resources/FurnitureCatalog.tres"
const TILE_CATALOG_PATH := "res://Resources/TileCatalog.tres"
const ROOM_ORIGIN := Vector2i(50, 50)
const ROOM_SIZE := Vector2i(8, 8)

var _room: Room
var _blocks: BlockLayer
var _cg: CombatGrid
var _frames := 0
var _failures: Array[String] = []

func _initialize() -> void:
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

	var chair := _blocks.furniture_catalog.get_definition(&"chair")
	_blocks.place_furniture(chair, Vector2i(3, 3), 0.0, 0)
	var standard := _blocks.get_definition(&"standard_block")
	_blocks.place_block(standard, Vector2i(3, 0), 0.0)
	_blocks.place_block(standard, Vector2i(3, 0), 1.0)

	_cg = CombatGrid.new()
	_cg.setup(_blocks, _room)

func _process(_delta: float) -> bool:
	_frames += 1
	if _frames < 2:
		return false
	_run_checks()
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

## Fresh session + resolver with a standard duel: hero "a" at local
## (2,4), foe "b" at (3,4) — adjacent, open LOS. Returns [session,
## resolver, a, b].
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

func _run_checks() -> void:
	_test_combatant()
	_test_session_setup()
	_test_turn_progression()
	_test_defeat_and_victory()
	_test_draw_and_cancel()
	_test_movement()
	_test_attack()
	_test_integration_sequences()

# ------------------------------------------------------------------
# Combatant
# ------------------------------------------------------------------

func _test_combatant() -> void:
	var c := Combatant.new(&"x", "X", &"t", Vector2i.ZERO, 5)
	_expect(c.is_alive(), "fresh combatant should be alive")
	_expect(c.hp == 5 and c.max_hp == 5, "hp init wrong")
	_expect(c.apply_damage(2) == 2 and c.hp == 3, "damage not applied")
	_expect(c.apply_damage(-4) == 0 and c.hp == 3, "negative damage must be rejected")
	_expect(c.apply_damage(0) == 0 and c.hp == 3, "zero damage must be rejected")
	_expect(c.apply_damage(99) == 3 and c.hp == 0, "damage must clamp at 0")
	_expect(not c.is_alive(), "hp 0 must mean defeated")
	_expect(c.apply_damage(1) == 0, "defeated combatant takes no damage")
	c.act_used = true
	c.move_used = true
	c.reset_turn()
	_expect(not c.act_used and not c.move_used, "reset_turn must clear flags")
	var bad := Combatant.new(&"bad", "Bad", &"t", Vector2i.ZERO, 0)
	_expect(not bad.is_alive(), "max_hp 0 combatant must not be alive")

# ------------------------------------------------------------------
# Session setup / registration
# ------------------------------------------------------------------

func _test_session_setup() -> void:
	# Too few combatants.
	var s1 := CombatSession.new()
	s1.setup(_cg)
	_expect(not s1.start(), "start with zero combatants must fail")
	s1.add_combatant(_mk(&"solo", &"heroes", Vector2i(0, 0)))
	_expect(not s1.start(), "start with one combatant must fail")
	# Single team.
	var s2 := CombatSession.new()
	s2.setup(_cg)
	s2.add_combatant(_mk(&"t1", &"same", Vector2i(0, 0)))
	s2.add_combatant(_mk(&"t2", &"same", Vector2i(1, 0)))
	_expect(not s2.start(), "start with one team must fail")
	# Duplicate id.
	var s3 := CombatSession.new()
	s3.setup(_cg)
	_expect(s3.add_combatant(_mk(&"dup", &"heroes", Vector2i(0, 0))), "first add failed")
	_expect(not s3.add_combatant(_mk(&"dup", &"foes", Vector2i(1, 0))),
		"duplicate id must be rejected")
	# Invalid team / HP.
	var no_team := Combatant.new(&"nt", "NT", &"", _w(Vector2i(0, 1)), 5)
	_expect(not s3.add_combatant(no_team), "empty team must be rejected")
	var no_hp := _mk(&"nh", &"foes", Vector2i(1, 1), 0)
	_expect(not s3.add_combatant(no_hp), "zero max_hp must be rejected")
	# Invalid position: chair cell and outside the room.
	_expect(not s3.add_combatant(_mk(&"chair", &"foes", Vector2i(3, 3))),
		"non-standable cell must be rejected")
	_expect(not s3.add_combatant(
		Combatant.new(&"out", "Out", &"foes", Vector2i(999, 999), 5)),
		"out-of-room cell must be rejected")
	# Occupied starting cell.
	_expect(s3.add_combatant(_mk(&"occ1", &"foes", Vector2i(2, 2))), "add occ1 failed")
	_expect(not s3.add_combatant(_mk(&"occ2", &"heroes", Vector2i(2, 2))),
		"occupied cell must be rejected")
	# Registration order decides the first turn.
	var s4 := CombatSession.new()
	s4.setup(_cg)
	var first := _mk(&"first", &"heroes", Vector2i(0, 4))
	var second := _mk(&"second", &"foes", Vector2i(1, 4))
	s4.add_combatant(first)
	s4.add_combatant(second)
	s4.start()
	_expect(s4.current_combatant() == first, "first registered must move first")
	_expect(s4.state == CombatSession.State.ACTIVE, "state must be ACTIVE")
	_expect(s4.round_number == 1, "round must start at 1")
	# Adding after start is rejected.
	_expect(not s4.add_combatant(_mk(&"late", &"foes", Vector2i(5, 5))),
		"add after start must fail")

# ------------------------------------------------------------------
# Turns
# ------------------------------------------------------------------

func _test_turn_progression() -> void:
	var parts := _duel()
	var s: CombatSession = parts[0]
	var a: Combatant = parts[2]
	var b: Combatant = parts[3]
	_expect(s.end_turn(), "end_turn failed")
	_expect(s.current_combatant() == b, "turn did not advance to b")
	_expect(s.is_turn(&"b") and not s.is_turn(&"a"), "is_turn wrong")
	_expect(s.end_turn(), "second end_turn failed")
	_expect(s.current_combatant() == a, "order did not wrap to a")
	_expect(s.round_number == 2, "round did not increment on wrap, got %d" % s.round_number)
	_expect(not a.act_used and not a.move_used, "new turn must reset flags")

func _test_defeat_and_victory() -> void:
	# Four combatants: heroes a+b, foes c+d. Killing c must NOT end the
	# encounter (d remains) and c's slot must be skipped on later turns.
	var s := CombatSession.new()
	s.setup(_cg)
	var a := _mk(&"a", &"heroes", Vector2i(0, 2), 10)
	var b := _mk(&"b", &"heroes", Vector2i(6, 6), 10)
	var c := _mk(&"c", &"foes", Vector2i(1, 2), 2)
	var d := _mk(&"d", &"foes", Vector2i(7, 7), 10)
	s.add_combatant(a)
	s.add_combatant(b)
	s.add_combatant(c)
	s.add_combatant(d)
	s.start()
	var r := CombatActionResolver.new()
	r.setup(s)
	# a at (0,2), c at (1,2): adjacent. a attacks, c dies (hp 2).
	var res := r.attack(&"a", &"c")
	_expect(res["ok"] and res["target_defeated"], "lethal attack failed: %s" % str(res))
	_expect(s.state == CombatSession.State.ACTIVE, "victory must wait for last team")
	# Turn order a,b,c,d: end a -> b; end b -> must skip dead c -> d.
	s.end_turn()
	_expect(s.current_combatant() == b, "expected b after a")
	s.end_turn()
	_expect(s.current_combatant() == d, "dead c must be skipped")
	_expect(s.round_number == 1, "round should still be 1, got %d" % s.round_number)
	s.end_turn()
	_expect(s.current_combatant() == a, "order should wrap to a")
	_expect(s.round_number == 2, "round should be 2 after wrap")
	# Full victory: fresh duel, b has 2 hp.
	var parts := _duel()
	var s2: CombatSession = parts[0]
	var r2: CombatActionResolver = parts[1]
	var b2: Combatant = parts[3]
	b2.hp = 2
	var kill := r2.attack(&"a", &"b")
	_expect(kill["ok"] and kill["target_defeated"], "kill attack failed")
	_expect(s2.state == CombatSession.State.VICTORY, "state must be VICTORY")
	_expect(s2.winning_team == &"heroes", "winning team wrong: %s" % s2.winning_team)
	_expect(s2.end_reason == CombatSession.EndReason.VICTORY, "end reason wrong")
	_expect(not s2.end_turn(), "end_turn must fail after victory")
	var after := r2.attack(&"a", &"b")
	_expect(not after["ok"] and after["reason"] == &"not_active",
		"actions must fail after encounter end")

func _test_draw_and_cancel() -> void:
	# Draw: detection branch via check_end_conditions with all dead.
	var s := CombatSession.new()
	s.setup(_cg)
	var a := _mk(&"a", &"t1", Vector2i(0, 0), 1)
	var b := _mk(&"b", &"t2", Vector2i(1, 0), 1)
	s.add_combatant(a)
	s.add_combatant(b)
	s.start()
	a.hp = 0
	b.hp = 0
	s.check_end_conditions()
	_expect(s.state == CombatSession.State.DRAW, "all-dead must be DRAW")
	_expect(s.end_reason == CombatSession.EndReason.DRAW, "draw reason wrong")
	# Cancel from ACTIVE.
	var parts := _duel()
	var s2: CombatSession = parts[0]
	_expect(s2.end_encounter(), "cancel failed")
	_expect(s2.state == CombatSession.State.ENDED, "state must be ENDED")
	_expect(s2.end_reason == CombatSession.EndReason.CANCELLED, "reason must be CANCELLED")
	_expect(not s2.end_encounter(), "second cancel must fail")

# ------------------------------------------------------------------
# Movement
# ------------------------------------------------------------------

func _test_movement() -> void:
	var parts := _duel()
	var s: CombatSession = parts[0]
	var r: CombatActionResolver = parts[1]
	var a: Combatant = parts[2]
	var b: Combatant = parts[3]
	# Legal cardinal move.
	var res := r.move(&"a", _w(Vector2i(2, 5)))
	_expect(res["ok"], "legal move failed: %s" % str(res))
	_expect(a.cell == _w(Vector2i(2, 5)), "cell not updated")
	_expect(s.combatant_at(_w(Vector2i(2, 5))) == a, "occupancy not updated")
	_expect(s.combatant_at(_w(Vector2i(2, 4))) == null, "old cell still occupied")
	# Second move same turn rejected.
	var again := r.move(&"a", _w(Vector2i(2, 6)))
	_expect(not again["ok"] and again["reason"] == &"move_used",
		"second move must be rejected: %s" % str(again))
	# Failed move changes nothing.
	var bad := r.move(&"a", _w(Vector2i(3, 3)))
	_expect(not bad["ok"], "move onto chair must fail")
	_expect(a.cell == _w(Vector2i(2, 5)), "failed move changed position")
	# Out-of-turn move is rejected.
	var res2 := r.move(&"b", _w(Vector2i(3, 4)))
	_expect(not res2["ok"] and res2["reason"] == &"out_of_turn",
		"out-of-turn move must fail: %s" % str(res2))
	# Cardinal-only movement: with budget 1 the diagonal cell (1,1) is
	# two cardinal steps away -> unreachable; orthogonal cells work.
	var s2 := CombatSession.new()
	s2.setup(_cg)
	var c := _mk(&"c", &"heroes", Vector2i(0, 0), 10, 1)
	var d := _mk(&"d", &"foes", Vector2i(7, 7), 10, 4)
	s2.add_combatant(c)
	s2.add_combatant(d)
	s2.start()
	var r2 := CombatActionResolver.new()
	r2.setup(s2)
	var diag := r2.move(&"c", _w(Vector2i(1, 1)))
	_expect(not diag["ok"] and diag["reason"] == &"unreachable",
		"diagonal cell must be unreachable at budget 1: %s" % str(diag))
	_expect(r2.move(&"c", _w(Vector2i(1, 0)))["ok"],
		"orthogonal cell must be reachable at budget 1")
	# Budget: budget-2 mover cannot reach 3 cells away.
	var e := _mk(&"e", &"heroes", Vector2i(0, 1), 10, 2)
	var f := _mk(&"f", &"foes", Vector2i(7, 0), 10, 4)
	var s3 := CombatSession.new()
	s3.setup(_cg)
	s3.add_combatant(e)
	s3.add_combatant(f)
	s3.start()
	var r3 := CombatActionResolver.new()
	r3.setup(s3)
	_expect(not r3.move(&"e", _w(Vector2i(3, 1)))["ok"],
		"budget-2 mover must not reach 3 cells")
	_expect(r3.move(&"e", _w(Vector2i(2, 1)))["ok"],
		"budget-2 mover must reach 2 cells")
	# Solid geometry: the 2-block column at local (3,0) is a 2-step —
	# unreachable from the floor — while cells beyond it stay reachable.
	var g := _mk(&"g", &"heroes", Vector2i(2, 0), 10, 6)
	var h := _mk(&"h", &"foes", Vector2i(6, 6), 10, 4)
	var s4 := CombatSession.new()
	s4.setup(_cg)
	s4.add_combatant(g)
	s4.add_combatant(h)
	s4.start()
	var r4 := CombatActionResolver.new()
	r4.setup(s4)
	_expect(not r4.move(&"g", _w(Vector2i(3, 0)))["ok"],
		"2-step column must block movement")
	_expect(r4.move(&"g", _w(Vector2i(4, 0)))["ok"],
		"cells beyond the column must stay reachable")
	# Occupied destination on a fresh duel: a cannot enter b's cell,
	# and cannot path THROUGH it to (4,4) — the detour costs more than
	# the direct 2 steps.
	var parts5 := _duel()
	var s5: CombatSession = parts5[0]
	var r5: CombatActionResolver = parts5[1]
	var onto := r5.move(&"a", _w(Vector2i(3, 4)))
	_expect(not onto["ok"] and onto["reason"] == &"unreachable",
		"occupied destination must be unreachable: %s" % str(onto))
	var through := r5.move(&"a", _w(Vector2i(4, 4)))
	_expect(through["ok"] and int(through["cost"]) > 2,
		"path through combatant must cost a detour, got %s" % str(through))

# ------------------------------------------------------------------
# Attack
# ------------------------------------------------------------------

func _test_attack() -> void:
	var parts := _duel()
	var s: CombatSession = parts[0]
	var r: CombatActionResolver = parts[1]
	var a: Combatant = parts[2]
	var b: Combatant = parts[3]
	# Valid attack: exactly 2 damage.
	var res := r.attack(&"a", &"b")
	_expect(res["ok"], "valid attack failed: %s" % str(res))
	_expect(res["damage"] == 2 and b.hp == 8, "damage wrong: %s" % str(res))
	_expect(a.act_used, "act not consumed")
	# Second attack same turn rejected.
	var second := r.attack(&"a", &"b")
	_expect(not second["ok"] and second["reason"] == &"act_used",
		"second attack must be rejected")
	# Invalid attack does not consume the Act: distant pair, failed
	# out-of-range attempt then a valid one after closing in is not
	# possible in one turn — so use a dedicated ranged setup where the
	# first attempt fails and a second target in range succeeds.
	var sR := CombatSession.new()
	sR.setup(_cg)
	var ra := _mk(&"ra", &"heroes", Vector2i(0, 0))
	var rbFar := _mk(&"rbFar", &"foes", Vector2i(5, 0))
	var rbNear := _mk(&"rbNear", &"foes", Vector2i(1, 0))
	sR.add_combatant(ra)
	sR.add_combatant(rbFar)
	sR.add_combatant(rbNear)
	sR.start()
	var rr := CombatActionResolver.new()
	rr.setup(sR)
	var far := rr.attack(&"ra", &"rbFar")
	_expect(not far["ok"] and far["reason"] == &"out_of_range",
		"out-of-range attack must fail: %s" % str(far))
	_expect(not ra.act_used, "failed attack consumed the act")
	_expect(rr.attack(&"ra", &"rbNear")["ok"],
		"valid attack after failure must work")
	# Same team.
	var s4 := CombatSession.new()
	s4.setup(_cg)
	var h1 := _mk(&"h1", &"heroes", Vector2i(0, 0))
	var h2 := _mk(&"h2", &"heroes", Vector2i(1, 0))
	var f1 := _mk(&"f1", &"foes", Vector2i(7, 7))
	s4.add_combatant(h1)
	s4.add_combatant(h2)
	s4.add_combatant(f1)
	s4.start()
	var r4 := CombatActionResolver.new()
	r4.setup(s4)
	var same := r4.attack(&"h1", &"h2")
	_expect(not same["ok"] and same["reason"] == &"same_team",
		"same-team attack must fail: %s" % str(same))
	# Defeated target.
	var p5 := _duel()
	var r5: CombatActionResolver = p5[1]
	var b5: Combatant = p5[3]
	b5.apply_damage(10)
	var dead := r5.attack(&"a", &"b")
	_expect(not dead["ok"] and dead["reason"] == &"target_defeated",
		"defeated target must fail: %s" % str(dead))
	# Out of turn.
	var p6 := _duel()
	var r6: CombatActionResolver = p6[1]
	var oot := r6.attack(&"b", &"a")
	_expect(not oot["ok"] and oot["reason"] == &"out_of_turn",
		"out-of-turn attack must fail: %s" % str(oot))
	# No LOS: the 2-block wall at local (3,0) clips the diagonal
	# sightline between adjacent cells (2,0) and (3,1).
	var s7 := CombatSession.new()
	s7.setup(_cg)
	var la := _mk(&"la", &"heroes", Vector2i(2, 0))
	var lb := _mk(&"lb", &"foes", Vector2i(3, 1))
	s7.add_combatant(la)
	s7.add_combatant(lb)
	s7.start()
	var r7 := CombatActionResolver.new()
	r7.setup(s7)
	var los := r7.attack(&"la", &"lb")
	_expect(not los["ok"] and los["reason"] == &"no_los",
		"walled attack must fail: %s" % str(los))
	_expect(not la.act_used, "failed LOS attack consumed act")
	# Step around the wall: move la to (3,2) then attack lb.
	_expect(r7.move(&"la", _w(Vector2i(3, 2)))["ok"], "flank move failed")
	_expect(r7.attack(&"la", &"lb")["ok"], "flanked attack should have LOS")

# ------------------------------------------------------------------
# Integration sequences (Model A)
# ------------------------------------------------------------------

func _test_integration_sequences() -> void:
	# Move -> attack -> end -> enemy attacks -> end -> fresh turn.
	var s := CombatSession.new()
	s.setup(_cg)
	var a := _mk(&"a", &"heroes", Vector2i(0, 4), 10, 4)
	var b := _mk(&"b", &"foes", Vector2i(4, 4), 10, 4)
	s.add_combatant(a)
	s.add_combatant(b)
	s.start()
	var r := CombatActionResolver.new()
	r.setup(s)
	# a moves 3 cells to (3,4), now adjacent to b at (4,4).
	var mv := r.move(&"a", _w(Vector2i(3, 4)))
	_expect(mv["ok"] and int(mv["cost"]) == 3, "3-cell move failed: %s" % str(mv))
	var atk := r.attack(&"a", &"b")
	_expect(atk["ok"], "post-move attack failed: %s" % str(atk))
	_expect(s.end_turn(), "end turn failed")
	_expect(s.current_combatant() == b, "b should be current")
	# b attacks a (now adjacent), then ends.
	var batk := r.attack(&"b", &"a")
	_expect(batk["ok"], "b attack failed: %s" % str(batk))
	_expect(s.end_turn(), "b end turn failed")
	_expect(s.current_combatant() == a and s.round_number == 2,
		"a should start round 2")
	_expect(not a.act_used and not a.move_used, "turn flags must reset")
	# Attack-then-move on a's fresh turn: attack b, then step to (3,5).
	var atk2 := r.attack(&"a", &"b")
	_expect(atk2["ok"], "second-round attack failed")
	var mv2 := r.move(&"a", _w(Vector2i(3, 5)))
	_expect(mv2["ok"], "move after attack failed: %s" % str(mv2))

func _report() -> void:
	if _failures.is_empty():
		print("COMBAT_SESSION_SMOKE: OK")
	else:
		for failure in _failures:
			push_error("COMBAT_SESSION_SMOKE FAIL: " + failure)
		print("COMBAT_SESSION_SMOKE: FAILED (%d)" % _failures.size())
