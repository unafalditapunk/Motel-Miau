extends SceneTree

## CombatGrid smoke test: deterministic fixture room built in code —
## never touches real saves or the motel layout. Room local cells are
## offset by cell_origin (100,100) so every check exercises world-cell
## coordinates.
##
## Fixture (local -> world = local + (100,100)):
##   (4,4)  chair                -> non-standable cell
##   (6,4)  2x standard_block    -> surface 2.0, unreachable (2-step)
##   (8,4)  1x standard_block    -> surface 1.0, reachable via 1-step
##   (9,4)  1x standard_block    -> same-level step from (8,4) top
##   (5,2)  2x standard_block    -> LOS wall between (2,2) and (8,2)

const ROOM_SCENE := "res://Scenes/World/Room.tscn"
const BLOCK_SCENE := "res://Scenes/Objects/Block.tscn"
const GRID_PATH := "res://Resources/IsometricGrid/TestGrid.tres"
const BLOCK_CATALOG_PATH := "res://Resources/BlockCatalog.tres"
const FURNITURE_CATALOG_PATH := "res://Resources/FurnitureCatalog.tres"
const TILE_CATALOG_PATH := "res://Resources/TileCatalog.tres"
const ROOM_ORIGIN := Vector2i(100, 100)
const ROOM_SIZE := Vector2i(10, 10)
const ACTOR_HEIGHT := 2.0
const MAX_STEP := 1.0

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

	# Fixture geometry (local coordinates).
	var chair := _blocks.furniture_catalog.get_definition(&"chair")
	_blocks.place_furniture(chair, Vector2i(4, 4), 0.0, 0)
	var standard := _blocks.get_definition(&"standard_block")
	_blocks.place_block(standard, Vector2i(6, 4), 0.0)
	_blocks.place_block(standard, Vector2i(6, 4), 1.0)
	_blocks.place_block(standard, Vector2i(8, 4), 0.0)
	_blocks.place_block(standard, Vector2i(9, 4), 0.0)
	_blocks.place_block(standard, Vector2i(5, 2), 0.0)
	_blocks.place_block(standard, Vector2i(5, 2), 1.0)

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

func _run_checks() -> void:
	_test_reachable_cardinal()
	_test_reachable_budget_and_blocked()
	_test_standability_and_elevation()
	_test_distance()
	_test_line_of_sight()
	_test_area_helpers()
	_test_world_coordinates()

func _test_reachable_cardinal() -> void:
	var start := _w(Vector2i(2, 2))
	var cells := _cg.get_reachable_cells(start, 0.0, 2, ACTOR_HEIGHT, MAX_STEP)
	# Open field: Manhattan ball of radius 2 minus the start = 12 cells.
	_expect(cells.size() == 12, "budget-2 reachable count wrong: %d" % cells.size())
	_expect(not cells.has(start), "start cell must be excluded")
	var ok_costs := true
	for cell in cells:
		var d := absi(cell.x - start.x) + absi(cell.y - start.y)
		if int(cells[cell]) != d:
			ok_costs = false
	if not ok_costs:
		_failures.append("reachable costs are not Manhattan distances")
	var one := _cg.get_reachable_cells(start, 0.0, 1, ACTOR_HEIGHT, MAX_STEP)
	_expect(one.size() == 4, "budget-1 reachable count wrong: %d" % one.size())
	_expect(_cg.get_reachable_cells(start, 0.0, 0, ACTOR_HEIGHT, MAX_STEP).is_empty(),
		"budget 0 should return no cells")

func _test_reachable_budget_and_blocked() -> void:
	var start := _w(Vector2i(2, 2))
	var cells := _cg.get_reachable_cells(start, 0.0, 10, ACTOR_HEIGHT, MAX_STEP)
	# Chair cell is not standable.
	_expect(not cells.has(_w(Vector2i(4, 4))), "chair cell must be unreachable")
	# Cells behind the chair are still reachable around it.
	_expect(cells.has(_w(Vector2i(4, 5))), "cell behind chair should be reachable")
	_expect(cells.has(_w(Vector2i(5, 4))), "cell beside chair should be reachable")
	# extra_blocked simulates future combatant occupancy.
	var blocked_target := _w(Vector2i(3, 2))
	var blocked := _cg.get_reachable_cells(start, 0.0, 10, ACTOR_HEIGHT, MAX_STEP,
		[blocked_target])
	_expect(not blocked.has(blocked_target), "extra_blocked cell must be unreachable")
	_expect(blocked.size() == cells.size() - 1, "extra_blocked should remove exactly one cell")

func _test_standability_and_elevation() -> void:
	# Chair: solid but non-walkable top -> cannot stand.
	_expect(not _cg.can_stand(_w(Vector2i(4, 4)), ACTOR_HEIGHT),
		"chair cell should not be standable")
	# 2-stack: standable on top (walkable) but surface 2.0 is a 2-step
	# climb from the floor -> unreachable.
	var tall := _w(Vector2i(6, 4))
	_expect(_cg.can_stand(tall, ACTOR_HEIGHT), "2-stack top should be standable")
	var cells := _cg.get_reachable_cells(_w(Vector2i(2, 2)), 0.0, 10,
		ACTOR_HEIGHT, MAX_STEP)
	_expect(not cells.has(tall), "2-step climb must be unreachable")
	# 1-block: surface 1.0, one step up -> reachable.
	_expect(cells.has(_w(Vector2i(8, 4))), "1-step climb should be reachable")
	# From the top of the 1-block (elevation 1): the adjacent 1-block
	# is a same-level step, the floor is a one-step descent, and the
	# 2-stack stays unreachable because all its neighbors are floor.
	var atop := _cg.get_reachable_cells(_w(Vector2i(8, 4)), 1.0, 10,
		ACTOR_HEIGHT, MAX_STEP)
	_expect(atop.has(_w(Vector2i(9, 4))), "same-level step should be reachable")
	_expect(atop.has(_w(Vector2i(2, 2))), "floor should be reachable descending")
	_expect(not atop.has(tall), "2-stack must stay unreachable from elevation 1")

func _test_distance() -> void:
	_expect(CombatGrid.get_distance(Vector2i(0, 0), Vector2i(3, 4)) == 4, "distance (0,0)-(3,4)")
	_expect(CombatGrid.get_distance(Vector2i(0, 0), Vector2i(3, 3)) == 3, "diagonal distance")
	_expect(CombatGrid.get_distance(Vector2i(-2, 5), Vector2i(1, -1)) == 6, "negative coords")
	_expect(CombatGrid.get_distance(Vector2i(4, 4), Vector2i(4, 4)) == 0, "same cell")

func _test_line_of_sight() -> void:
	var eye_h := ACTOR_HEIGHT
	# Open diagonal across the room.
	_expect(_cg.has_line_of_sight(_w(Vector2i(0, 0)), 0.0, eye_h,
			_w(Vector2i(9, 9)), 0.0, eye_h),
		"open diagonal LOS should be clear")
	# Wall column at (5,2): blocks the (2,2)->(8,2) sightline.
	_expect(not _cg.has_line_of_sight(_w(Vector2i(2, 2)), 0.0, eye_h,
			_w(Vector2i(8, 2)), 0.0, eye_h),
		"2-tall wall should block LOS")
	# Same wall is beyond the target (4,2): must not block.
	_expect(_cg.has_line_of_sight(_w(Vector2i(2, 2)), 0.0, eye_h,
			_w(Vector2i(4, 2)), 0.0, eye_h),
		"geometry behind the target must not block LOS")
	# Chair (height 1) on the (4,3)->(4,5) sightline: too low to block
	# eye level 1.5.
	_expect(_cg.has_line_of_sight(_w(Vector2i(4, 3)), 0.0, eye_h,
			_w(Vector2i(4, 5)), 0.0, eye_h),
		"low furniture should not block LOS")
	# Same-cell LOS is trivially true.
	_expect(_cg.has_line_of_sight(_w(Vector2i(4, 4)), 0.0, eye_h,
			_w(Vector2i(4, 4)), 0.0, eye_h),
		"same-cell LOS should be true")

func _test_area_helpers() -> void:
	var center := _w(Vector2i(5, 5))
	var radius := _cg.get_radius_cells(center, 1)
	_expect(radius.size() == 9, "radius-1 should return 3x3 = 9 cells, got %d" % radius.size())
	var line := _cg.get_line_cells(_w(Vector2i(2, 2)), Vector2i(1, 0), 3)
	_expect(line == [_w(Vector2i(2, 2)), _w(Vector2i(3, 2)),
		_w(Vector2i(4, 2)), _w(Vector2i(5, 2))],
		"cardinal line cells wrong: %s" % str(line))
	_expect(_cg.get_line_cells(center, Vector2i(1, 1), 3).is_empty(),
		"diagonal direction must return empty")
	var cross := _cg.get_cross_cells(center, 1)
	_expect(cross.size() == 5, "cross radius-1 should be 5 cells, got %d" % cross.size())
	_expect(cross.has(center), "cross must include center")

func _test_world_coordinates() -> void:
	# Everything returned must be in world space (offset by origin).
	var cells := _cg.get_reachable_cells(_w(Vector2i(2, 2)), 0.0, 2,
		ACTOR_HEIGHT, MAX_STEP)
	var saw_world := false
	var saw_local := false
	for cell in cells:
		if cell.x >= ROOM_ORIGIN.x and cell.y >= ROOM_ORIGIN.y:
			saw_world = true
		if cell.x < ROOM_ORIGIN.x or cell.y < ROOM_ORIGIN.y:
			saw_local = true
	_expect(saw_world and not saw_local, "reachable cells must be world cells")
	_expect(cells.has(_w(Vector2i(3, 2))), "missing expected world cell (103,102)")
	_expect(not cells.has(Vector2i(3, 2)), "local cell leaked into results")

func _report() -> void:
	if _failures.is_empty():
		print("COMBAT_GRID_SMOKE: OK")
	else:
		for failure in _failures:
			push_error("COMBAT_GRID_SMOKE FAIL: " + failure)
		print("COMBAT_GRID_SMOKE: FAILED (%d)" % _failures.size())
