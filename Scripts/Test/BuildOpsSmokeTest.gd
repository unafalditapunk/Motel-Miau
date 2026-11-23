extends SceneTree

## Smoke test for BuildOps (Phase B1): the shared server-authority
## rules for block placement/removal. Runs the same validate/apply
## code the network layer uses — no ENet required.

const GRID_PATH := "res://Resources/IsometricGrid/TestGrid.tres"
const TILE_CATALOG_PATH := "res://Resources/TileCatalog.tres"
const BLOCK_CATALOG_PATH := "res://Resources/BlockCatalog.tres"
const FURNITURE_CATALOG_PATH := "res://Resources/FurnitureCatalog.tres"
const CARPET_CATALOG_PATH := "res://Resources/CarpetCatalog.tres"
const BLOCK_SCENE_PATH := "res://Scenes/Objects/Block.tscn"
const PLAYER_SCENE_PATH := "res://Scenes/Player/Player.tscn"
const SCRATCH_ROOT := "user://smoke_buildops_saves"

var _fm: FloorManager
var _world: RoomWorld
var _world_b: RoomWorld
var _frames := 0
var _failures: Array[String] = []

func _initialize() -> void:
	FloorSaveSystem.save_root = SCRATCH_ROOT
	_remove_dir_contents(SCRATCH_ROOT)
	_fm = FloorManager.new()
	_fm.name = "BuildOpsFloorManager"
	root.add_child(_fm)
	_world = _make_room_world("WorldA")
	_fm.room_world = _world
	# A second independent world stands in for "every client".
	_world_b = _make_room_world("WorldB")

func _make_room_world(node_name: String) -> RoomWorld:
	var world := RoomWorld.new()
	world.name = node_name
	world.grid = load(GRID_PATH) as IsometricGrid
	world.room_dimensions = Vector2i(16, 16)
	world.default_tile_id = &"floor_iso"
	world.tile_catalog = load(TILE_CATALOG_PATH) as TileCatalog
	world.block_catalog = load(BLOCK_CATALOG_PATH) as BlockCatalog
	world.furniture_catalog = load(FURNITURE_CATALOG_PATH) as FurnitureCatalog
	world.carpet_catalog = load(CARPET_CATALOG_PATH) as CarpetCatalog
	world.block_scene = load(BLOCK_SCENE_PATH) as PackedScene
	world.player_scene = load(PLAYER_SCENE_PATH) as PackedScene
	world.hide_rooms_outside_neighborhood = false
	world.deemphasize_neighbors = false
	world.emphasis_transition_duration = 0.0
	world.room_slide_duration = 0.0
	root.add_child(world)
	return world

func _floor(id: StringName) -> Floor:
	var floor_def := Floor.new()
	floor_def.floor_id = id
	floor_def.display_name = String(id)
	floor_def.entry_room_id = Vector2i(0, 0)
	floor_def.spawn_position = Vector2i(2, 2)
	floor_def.auto_connect_adjacent = false
	var spec_a := FloorRoomSpec.new()
	spec_a.room_id = Vector2i(0, 0)
	spec_a.global_origin = Vector2i(0, 0)
	spec_a.size = Vector2i(8, 8)
	var spec_b := FloorRoomSpec.new()
	spec_b.room_id = Vector2i(1, 0)
	spec_b.global_origin = Vector2i(8, 0)
	spec_b.size = Vector2i(8, 8)
	floor_def.rooms.assign([spec_a, spec_b])
	return floor_def

func _process(_delta: float) -> bool:
	_frames += 1
	if _frames == 1:
		var floor_def := _floor(&"buildops_a")
		_fm.register_floor(floor_def)
		return false
	if _frames == 2:
		if not _fm.load_floor_without_save(&"buildops_a"):
			_expect(false, "load_floor_without_save failed")
		# World B gets the same layout via materialize only.
		var floor_b := _floor(&"buildops_a")
		_world_b.save_directory = _fm.floor_save_dir(&"buildops_a")
		if not _fm.materialize_floor(floor_b, _world_b):
			_expect(false, "materialize world B failed")
		_run_checks()
		_report()
		quit()
		return true
	return false

func _room() -> Room:
	return _world.get_room(Vector2i(0, 0))

func _room_b() -> Room:
	return _world_b.get_room(Vector2i(0, 0))

func _block_ids(world: RoomWorld, room_id: Vector2i) -> Array:
	var ids: Array = []
	var room := world.get_room(room_id)
	if room != null and room.block_layer != null:
		for block in room.block_layer.blocks:
			ids.append(String(block.block_id))
	ids.sort()
	return ids

func _run_checks() -> void:
	var room := _room()
	var room_b := _room_b()
	_expect(room != null and room_b != null, "rooms missing")
	if room == null or room_b == null:
		return
	var layer := room.block_layer
	var no_players: Array = []

	# --- valid placement -------------------------------------------------
	var ok := BuildOps.validate_place(_world, no_players,
		Vector2i(0, 0), Vector2i(3, 3), &"standard_block")
	_expect(bool(ok.get("ok", false)), "valid place rejected: %s" % ok.get("reason"))
	if bool(ok.get("ok", false)):
		var placed := BuildOps.apply_place(ok["room"], Vector2i(3, 3),
			&"standard_block", float(ok["elevation"]), false)
		_expect(placed != null, "apply_place returned null")
		_expect(_block_ids(_world, Vector2i(0, 0)) == ["standard_block"],
			"block not present after apply: %s" % _block_ids(_world, Vector2i(0, 0)))

	# --- rejections ------------------------------------------------------
	_expect(not bool(BuildOps.validate_place(_world, no_players,
		Vector2i(9, 9), Vector2i(3, 3), &"standard_block").get("ok", true)),
		"unknown room accepted")
	_expect(not bool(BuildOps.validate_place(_world, no_players,
		Vector2i(0, 0), Vector2i(3, 3), &"no_such_block").get("ok", true)),
		"unknown block accepted")
	# NOTE: stacking is legal — elevation is always recomputed as the
	# top surface, so a second block at the same cell rests on top.
	# Rejections that matter here: unknown room/block, outside room,
	# player occupancy (below), and op-id dedup (tested separately).
	_expect(not bool(BuildOps.validate_place(_world, no_players,
		Vector2i(0, 0), Vector2i(20, 20), &"crate").get("ok", true)),
		"outside-room placement accepted")

	# --- player occupancy -------------------------------------------------
	var occupied := room.world_cell_coordinates(Vector2i(5, 5))
	var bad := BuildOps.validate_place(_world, [occupied],
		Vector2i(0, 0), Vector2i(5, 5), &"crate")
	_expect(not bool(bad.get("ok", true)) and bad.get("reason") == &"player_occupied",
		"placement on player cell accepted")

	# --- second client world gets identical result ------------------------
	var ok_b := BuildOps.validate_place(_world_b, no_players,
		Vector2i(0, 0), Vector2i(3, 3), &"standard_block")
	_expect(bool(ok_b.get("ok", false)), "world B place rejected")
	if bool(ok_b.get("ok", false)):
		BuildOps.apply_place(ok_b["room"], Vector2i(3, 3), &"standard_block",
			float(ok_b["elevation"]), false)
	_expect(_block_ids(_world, Vector2i(0, 0)) == _block_ids(_world_b, Vector2i(0, 0)),
		"client worlds diverged: %s vs %s" % [
			_block_ids(_world, Vector2i(0, 0)), _block_ids(_world_b, Vector2i(0, 0))])

	# --- removal ----------------------------------------------------------
	# Place a second block elsewhere for removal tests.
	var ok2 := BuildOps.validate_place(_world, no_players,
		Vector2i(0, 0), Vector2i(6, 6), &"crate")
	_expect(bool(ok2.get("ok", false)), "second place rejected")
	if bool(ok2.get("ok", false)):
		BuildOps.apply_place(ok2["room"], Vector2i(6, 6), &"crate",
			float(ok2["elevation"]), false)
	var target := BuildOps.topmost_block(layer, Vector2i(6, 6))
	_expect(target != null and String(target.block_id) == "crate",
		"topmost block at (6,6) is not crate")
	var rem := BuildOps.validate_remove(_world, no_players, Vector2i(0, 0),
		Vector2i(6, 6), StringName(target.block_id), target.grid_position,
		target.elevation)
	_expect(bool(rem.get("ok", false)), "valid remove rejected: %s" % rem.get("reason"))
	if bool(rem.get("ok", false)):
		_expect(BuildOps.apply_remove(rem["room"], Vector2i(6, 6),
			StringName(target.block_id), target.grid_position,
			target.elevation), "apply_remove returned false")
		_expect(not _block_ids(_world, Vector2i(0, 0)).has("crate"),
			"crate still present after remove")

	# --- removal rejections -------------------------------------------------
	_expect(not bool(BuildOps.validate_remove(_world, no_players,
		Vector2i(0, 0), Vector2i(1, 1), &"", Vector2i.ZERO, 0.0).get("ok", true)),
		"empty-cell remove accepted")
	var stale := BuildOps.validate_remove(_world, no_players, Vector2i(0, 0),
		Vector2i(3, 3), &"crate", Vector2i(3, 3), 0.0)
	_expect(not bool(stale.get("ok", true)),
		"remove with wrong target identity accepted")

	# --- furniture topmost is unsupported ----------------------------------
	var chair_def: FurnitureDefinition = _world.furniture_catalog.get_definition(&"chair")
	_expect(chair_def != null, "chair definition missing")
	if chair_def != null:
		room.block_layer.place_furniture(chair_def, Vector2i(2, 2), 0.0, 0)
		var furn := BuildOps.topmost_block(layer, Vector2i(2, 2))
		_expect(furn != null and furn.block_definition == null,
			"furniture not detected as non-plain block")
		var frej := BuildOps.validate_remove(_world, no_players,
			Vector2i(0, 0), Vector2i(2, 2), &"", Vector2i.ZERO, 0.0)
		_expect(not bool(frej.get("ok", true)) and frej.get("reason") == &"unsupported",
			"furniture removal accepted: %s" % frej.get("reason"))

	# --- duplicate application cannot double-apply --------------------------
	# Op-id dedup lives in MultiplayerManager._claim_build_op; a bare
	# instance exercises it without ENet.
	var mm := MultiplayerManager.new()
	root.add_child(mm)
	_expect(mm._claim_build_op(7, 42), "first op claim rejected")
	_expect(not mm._claim_build_op(7, 42), "duplicate op claim accepted")
	_expect(mm._claim_build_op(7, 43), "distinct op claim rejected")
	_expect(mm._claim_build_op(8, 42), "same op id from another peer rejected")
	mm.queue_free()
	# And a repeated REMOVE finds nothing left to remove.
	var gone := BuildOps.apply_remove(room, Vector2i(6, 6), &"crate",
		Vector2i(6, 6), 0.0)
	_expect(not gone, "second remove applied a ghost block")

	# --- remove rejected on occupied cell ------------------------------------
	var block3 := BuildOps.topmost_block(layer, Vector2i(3, 3))
	_expect(block3 != null, "standard_block missing for occupancy remove test")
	if block3 != null:
		var cells: Array = []
		for c in block3.occupied_cells():
			cells.append(room.world_cell_coordinates(c))
		var rbad := BuildOps.validate_remove(_world, cells, Vector2i(0, 0),
			Vector2i(3, 3), &"", Vector2i.ZERO, 0.0)
		_expect(not bool(rbad.get("ok", true)) and rbad.get("reason") == &"player_occupied",
			"remove on player-occupied block accepted")

func _expect(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)

func _report() -> void:
	if _failures.is_empty():
		print("BUILDOPS_SMOKE: OK")
	else:
		for failure in _failures:
			push_error("BUILDOPS_SMOKE FAIL: %s" % failure)
		print("BUILDOPS_SMOKE: FAILED (%d)" % _failures.size())

func _remove_dir_contents(path: String) -> void:
	var dir := DirAccess.open(path)
	if dir == null:
		return
	for file_name in dir.get_files():
		dir.remove(file_name)
	for sub in dir.get_directories():
		_remove_dir_contents(path.path_join(sub))
		DirAccess.remove_absolute(path.path_join(sub))
