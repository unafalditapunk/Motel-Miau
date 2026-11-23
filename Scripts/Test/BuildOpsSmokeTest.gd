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
		# B2 syncs furniture now — remove the fixture so later checks
		# see a clean world.
		layer.remove_block(furn)

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

	_run_b2_checks(room, room_b, no_players)

## Phase B2: furniture/carpet/tile through the generic _any API.
func _run_b2_checks(room: Room, room_b: Room, no_players: Array) -> void:
	# --- furniture place ---------------------------------------------------
	var fplace := {"room_id": Vector2i(0, 0), "cell": Vector2i(4, 4),
		"category": &"furniture", "object_id": &"chair", "rotation": 0}
	var fv := BuildOps.validate_place_any(_world, no_players, fplace)
	_expect(bool(fv.get("ok", false)),
		"furniture place rejected: %s" % fv.get("reason"))
	if bool(fv.get("ok", false)):
		var applied: Variant = BuildOps.apply_place_any(_world, fv["room"],
			&"furniture", Vector2i(4, 4), &"chair",
			float(fv["elevation"]), 0, false)
		_expect(applied is Furniture, "apply_place_any furniture returned %s" % applied)
		_expect(_block_ids(_world, Vector2i(0, 0)).has("chair"),
			"chair missing after apply")
	# furniture on a player cell must reject
	var fcell := room.world_cell_coordinates(Vector2i(4, 4))
	var fbad := BuildOps.validate_place_any(_world, [fcell],
		{"room_id": Vector2i(0, 0), "cell": Vector2i(4, 4),
			"category": &"furniture", "object_id": &"chair"})
	_expect(not bool(fbad.get("ok", true)) and fbad.get("reason") == &"player_occupied",
		"furniture place on player cell accepted")
	# unknown furniture id
	_expect(not bool(BuildOps.validate_place_any(_world, no_players,
		{"room_id": Vector2i(0, 0), "cell": Vector2i(4, 4),
			"category": &"furniture", "object_id": &"no_such"}).get("ok", true)),
		"unknown furniture accepted")

	# --- carpet place -------------------------------------------------------
	var cplace := {"room_id": Vector2i(0, 0), "cell": Vector2i(5, 5),
		"category": &"carpet", "object_id": &"flower_carpet", "rotation": 0}
	var cv := BuildOps.validate_place_any(_world, no_players, cplace)
	_expect(bool(cv.get("ok", false)),
		"carpet place rejected: %s" % cv.get("reason"))
	if bool(cv.get("ok", false)):
		var okc: Variant = BuildOps.apply_place_any(_world, cv["room"],
			&"carpet", Vector2i(5, 5), &"flower_carpet",
			float(cv["elevation"]), 0, false)
		_expect(okc == true, "apply_place_any carpet returned %s" % okc)
		_expect(room.get_cell_carpet(Vector2i(5, 5)) != null,
			"carpet missing after apply")
	# carpet over an existing carpet rejects
	_expect(not bool(BuildOps.validate_place_any(_world, no_players,
		{"room_id": Vector2i(0, 0), "cell": Vector2i(5, 5),
			"category": &"carpet", "object_id": &"flower_carpet"}).get("ok", true)),
		"overlapping carpet accepted")
	_expect(not bool(BuildOps.validate_place_any(_world, no_players,
		{"room_id": Vector2i(0, 0), "cell": Vector2i(5, 5),
			"category": &"carpet", "object_id": &"no_such"}).get("ok", true)),
		"unknown carpet accepted")

	# --- tile place ---------------------------------------------------------
	var tplace := {"room_id": Vector2i(0, 0), "cell": Vector2i(7, 7),
		"category": &"tile", "object_id": &"floor_iso", "rotation": 0}
	var tv := BuildOps.validate_place_any(_world, no_players, tplace)
	_expect(bool(tv.get("ok", false)),
		"tile place rejected: %s" % tv.get("reason"))
	if bool(tv.get("ok", false)):
		var okt: Variant = BuildOps.apply_place_any(_world, tv["room"],
			&"tile", Vector2i(7, 7), &"floor_iso",
			float(tv["elevation"]), 0, false)
		_expect(okt == true, "apply_place_any tile returned %s" % okt)
		_expect(room.get_cell_tile(Vector2i(7, 7)) != null,
			"tile missing after apply")
	_expect(not bool(BuildOps.validate_place_any(_world, no_players,
		{"room_id": Vector2i(0, 0), "cell": Vector2i(7, 7),
			"category": &"tile", "object_id": &"no_such"}).get("ok", true)),
		"unknown tile accepted")
	_expect(not bool(BuildOps.validate_place_any(_world, no_players,
		{"room_id": Vector2i(0, 0), "cell": Vector2i(20, 20),
			"category": &"tile", "object_id": &"floor_iso"}).get("ok", true)),
		"outside-room tile accepted")

	# --- generic removals ---------------------------------------------------
	# Furniture removal: identity must match (pos/elev/rotation).
	var furn := BuildOps.topmost_at(room, Vector2i(4, 4))
	_expect(StringName(str(furn.get("category", ""))) == &"furniture",
		"topmost at (4,4) is not furniture: %s" % furn)
	if not furn.is_empty():
		var fblk: Block = furn["block"]
		var fv_req := {"room_id": Vector2i(0, 0), "cell": Vector2i(4, 4),
			"category": &"furniture", "object_id": fblk.block_id,
			"pos": fblk.grid_position, "elev": fblk.elevation,
			"rotation": fblk.furniture_rotation_degrees}
		var frv := BuildOps.validate_remove_any(_world, no_players, fv_req)
		_expect(bool(frv.get("ok", false)),
			"furniture remove rejected: %s" % frv.get("reason"))
		if bool(frv.get("ok", false)):
			_expect(BuildOps.apply_remove_any(_world, frv["room"], &"furniture",
				Vector2i(4, 4), fblk.block_id, fblk.grid_position,
				fblk.elevation, Vector2i.ZERO,
				fblk.furniture_rotation_degrees, false),
				"apply_remove_any furniture returned false")
			_expect(not _block_ids(_world, Vector2i(0, 0)).has("chair"),
				"chair still present after remove")
		# stale identity rejects
		var stale_f := fv_req.duplicate()
		stale_f["elev"] = fblk.elevation + 5.0
		_expect(not bool(BuildOps.validate_remove_any(_world, no_players,
			stale_f).get("ok", true)),
			"stale furniture remove accepted")
		# wrong category rejects
		var wrong_cat := fv_req.duplicate()
		wrong_cat["category"] = &"block"
		_expect(not bool(BuildOps.validate_remove_any(_world, no_players,
			wrong_cat).get("ok", true)),
			"furniture removed as block category")

	# Carpet removal via its anchor identity.
	var cv_req := {"room_id": Vector2i(0, 0), "cell": Vector2i(5, 5),
		"category": &"carpet", "object_id": &"flower_carpet",
		"anchor": Vector2i(5, 5), "rotation": 0, "flip": false,
		"elev": room.get_cell(Vector2i(5, 5)).carpet_elevation}
	var crv := BuildOps.validate_remove_any(_world, no_players, cv_req)
	_expect(bool(crv.get("ok", false)),
		"carpet remove rejected: %s" % crv.get("reason"))
	if bool(crv.get("ok", false)):
		_expect(BuildOps.apply_remove_any(_world, crv["room"], &"carpet",
			Vector2i(5, 5), &"flower_carpet", Vector2i.ZERO,
			float(crv["target"]["elevation"]), Vector2i(5, 5), 0, false),
			"apply_remove_any carpet returned false")
		_expect(room.get_cell_carpet(Vector2i(5, 5)) == null,
			"carpet still present after remove")
	var stale_c := cv_req.duplicate()
	stale_c["anchor"] = Vector2i(6, 6)
	_expect(not bool(BuildOps.validate_remove_any(_world, no_players,
		stale_c).get("ok", true)),
		"stale carpet anchor accepted")

	# Tile removal.
	var tv_req := {"room_id": Vector2i(0, 0), "cell": Vector2i(7, 7),
		"category": &"tile", "object_id": &"floor_iso",
		"elev": room.get_cell(Vector2i(7, 7)).tile_elevation}
	var trv := BuildOps.validate_remove_any(_world, no_players, tv_req)
	_expect(bool(trv.get("ok", false)),
		"tile remove rejected: %s" % trv.get("reason"))
	if bool(trv.get("ok", false)):
		_expect(BuildOps.apply_remove_any(_world, trv["room"], &"tile",
			Vector2i(7, 7), &"floor_iso", Vector2i.ZERO,
			float(trv["target"]["elevation"]), Vector2i.ZERO, 0, false),
			"apply_remove_any tile returned false")
		_expect(room.get_cell_tile(Vector2i(7, 7)) == null,
			"tile still present after remove")

	# --- player occupancy on removals ---------------------------------------
	# Re-place a carpet, then reject its removal while a player stands on it.
	BuildOps.apply_place_any(_world, room, &"carpet", Vector2i(5, 5),
		&"flower_carpet", 0.0, 0, false)
	var carcell := room.world_cell_coordinates(Vector2i(5, 5))
	var crbad := BuildOps.validate_remove_any(_world, [carcell], cv_req)
	_expect(not bool(crbad.get("ok", true)) and crbad.get("reason") == &"player_occupied",
		"carpet remove on player cell accepted")

	# --- two-client equivalence for all categories --------------------------
	# World B performs the same place/remove sequence through the API.
	var seq := [
		{"kind": "place", "req": {"room_id": Vector2i(0, 0), "cell": Vector2i(4, 4),
			"category": &"furniture", "object_id": &"chair"}},
		{"kind": "place", "req": {"room_id": Vector2i(0, 0), "cell": Vector2i(5, 5),
			"category": &"carpet", "object_id": &"flower_carpet"}},
		{"kind": "place", "req": {"room_id": Vector2i(0, 0), "cell": Vector2i(7, 7),
			"category": &"tile", "object_id": &"floor_iso"}},
	]
	for step in seq:
		var v := BuildOps.validate_place_any(_world_b, no_players, step["req"])
		_expect(bool(v.get("ok", false)),
			"world B %s place rejected: %s" % [step["req"]["category"], v.get("reason")])
		if bool(v.get("ok", false)):
			BuildOps.apply_place_any(_world_b, v["room"],
				step["req"]["category"], step["req"]["cell"],
				step["req"]["object_id"], float(v["elevation"]),
				int(step["req"].get("rotation", 0)), false)
	# World A applies the same sequence (cells are free again post-removal).
	for step in seq:
		var req: Dictionary = step["req"]
		var v2 := BuildOps.validate_place_any(_world, no_players, req)
		if bool(v2.get("ok", false)):
			BuildOps.apply_place_any(_world, v2["room"], req["category"],
				req["cell"], req["object_id"], float(v2["elevation"]),
				int(req.get("rotation", 0)), false)
	# Both worlds now hold identical contents.
	_expect(_block_ids(_world, Vector2i(0, 0)) == _block_ids(_world_b, Vector2i(0, 0)),
		"post-B2 block ids diverged: %s vs %s" % [
			_block_ids(_world, Vector2i(0, 0)), _block_ids(_world_b, Vector2i(0, 0))])
	_expect(room.get_cell_carpet(Vector2i(5, 5)) != null
		and room_b.get_cell_carpet(Vector2i(5, 5)) != null,
		"carpet state diverged between worlds")
	_expect((room.get_cell_tile(Vector2i(7, 7)) != null)
		== (room_b.get_cell_tile(Vector2i(7, 7)) != null),
		"tile state diverged between worlds")

	_run_b3_checks(room, no_players)

## Phase B3: dedup monotonicity, malformed payloads, disconnect
## cleanup, and serialized-conflict semantics.
func _run_b3_checks(room: Room, no_players: Array) -> void:
	var mm := MultiplayerManager.new()
	root.add_child(mm)

	# --- op-id dedup: monotonic, replay-proof -------------------------------
	_expect(mm._claim_build_op(7, 1), "op 1 rejected")
	_expect(mm._claim_build_op(7, 2), "op 2 rejected")
	_expect(not mm._claim_build_op(7, 2), "duplicate op 2 accepted")
	_expect(not mm._claim_build_op(7, 1), "older op 1 replay accepted")
	_expect(not mm._claim_build_op(7, 0), "op id 0 accepted")
	_expect(not mm._claim_build_op(7, -3), "negative op id accepted")
	_expect(mm._claim_build_op(7, 3), "op 3 rejected")
	_expect(mm._claim_build_op(8, 1), "op 1 from another peer rejected")
	_expect(not mm._claim_build_op(8, 0), "op 0 from another peer accepted")

	# --- disconnect cleanup --------------------------------------------------
	mm.mode = MultiplayerManager.Mode.SERVER
	mm._on_peer_disconnected(7)
	_expect(not mm._build_op_max.has(7), "dedup state survived disconnect")
	_expect(mm._build_op_max.has(8), "other peer's dedup state lost")
	mm.queue_free()

	# --- malformed request fields reject safely ------------------------------
	var malformed := [
		{"room_id": [], "cell": Vector2i(1, 1), "category": &"block",
			"object_id": &"standard_block"},
		{"room_id": Vector2i(0, 0), "cell": {"x": 1}, "category": &"carpet",
			"object_id": &"flower_carpet", "rotation": []},
		{"room_id": Vector2i(0, 0), "cell": Vector2i(4, 4), "category": &"furniture",
			"object_id": &"chair", "rotation": {}},
	]
	for req in malformed:
		var v := BuildOps.validate_place_any(_world, no_players, req)
		_expect(v is Dictionary, "malformed place crashed validation")
	var bad_rem := {"room_id": Vector2i(0, 0), "cell": Vector2i(5, 5),
		"category": &"carpet", "object_id": &"flower_carpet",
		"anchor": [], "rotation": [], "flip": [], "elev": {}}
	var rv := BuildOps.validate_remove_any(_world, no_players, bad_rem)
	_expect(not bool(rv.get("ok", true)), "malformed remove accepted")

	# --- serialized conflicts -------------------------------------------------
	# Carpet: second place on the same footprint must reject once the
	# first is authoritative state.
	var cell := Vector2i(6, 2)
	var c1 := {"room_id": Vector2i(0, 0), "cell": cell,
		"category": &"carpet", "object_id": &"flower_carpet"}
	var v1 := BuildOps.validate_place_any(_world, no_players, c1)
	_expect(bool(v1.get("ok", false)), "first carpet place rejected")
	if bool(v1.get("ok", false)):
		BuildOps.apply_place_any(_world, v1["room"], &"carpet", cell,
			&"flower_carpet", float(v1["elevation"]), 0, false)
	var v2 := BuildOps.validate_place_any(_world, no_players, c1)
	_expect(not bool(v2.get("ok", true)) and v2.get("reason") == &"cannot_place",
		"conflicting carpet place accepted: %s" % v2.get("reason"))

	# Remove then immediate re-place: the remove must be reflected
	# before the next validation runs.
	var top := BuildOps.topmost_at(room, cell)
	_expect(StringName(str(top.get("category", ""))) == &"carpet",
		"topmost at (6,2) is not carpet")
	var rem_req := {"room_id": Vector2i(0, 0), "cell": cell,
		"category": &"carpet", "object_id": &"flower_carpet",
		"anchor": top.get("anchor", Vector2i.ZERO),
		"rotation": int(top.get("rotation", 0)),
		"flip": bool(top.get("flip", false))}
	var rv1 := BuildOps.validate_remove_any(_world, no_players, rem_req)
	_expect(bool(rv1.get("ok", false)), "carpet remove rejected: %s" % rv1.get("reason"))
	if bool(rv1.get("ok", false)):
		BuildOps.apply_remove_any(_world, rv1["room"], &"carpet", cell,
			&"flower_carpet", Vector2i.ZERO, 0.0,
			top.get("anchor", Vector2i.ZERO),
			int(top.get("rotation", 0)), bool(top.get("flip", false)))
	# Same remove again: nothing left -> rejected, world untouched.
	var rv2 := BuildOps.validate_remove_any(_world, no_players, rem_req)
	_expect(not bool(rv2.get("ok", true)),
		"repeat remove of same carpet accepted")
	# Re-place after removal validates against post-remove state.
	var v3 := BuildOps.validate_place_any(_world, no_players, c1)
	_expect(bool(v3.get("ok", false)),
		"re-place after remove rejected: %s" % v3.get("reason"))
	if bool(v3.get("ok", false)):
		BuildOps.apply_place_any(_world, v3["room"], &"carpet", cell,
			&"flower_carpet", float(v3["elevation"]), 0, false)

	# Two peers place furniture in the SAME cell (both legally stack),
	# then one removes the topmost — exactly one chair must remain.
	var dup_cell := Vector2i(2, 6)
	for i in range(2):
		var dv := BuildOps.validate_place_any(_world, no_players,
			{"room_id": Vector2i(0, 0), "cell": dup_cell,
				"category": &"furniture", "object_id": &"chair"})
		_expect(bool(dv.get("ok", false)), "dup chair place %d rejected: %s" % [i, dv.get("reason")])
		if bool(dv.get("ok", false)):
			BuildOps.apply_place_any(_world, dv["room"], &"furniture", dup_cell,
				&"chair", float(dv["elevation"]), 0, false)
	var dup_top := BuildOps.topmost_at(room, dup_cell)
	_expect(StringName(str(dup_top.get("category", ""))) == &"furniture",
		"topmost at dup cell is not furniture")
	if not dup_top.is_empty():
		var dblk: Block = dup_top["block"]
		var drv := BuildOps.validate_remove_any(_world, no_players,
			{"room_id": Vector2i(0, 0), "cell": dup_cell,
				"category": &"furniture", "object_id": dblk.block_id,
				"pos": dblk.grid_position, "elev": dblk.elevation,
				"rotation": dblk.furniture_rotation_degrees})
		_expect(bool(drv.get("ok", false)), "dup chair remove rejected: %s" % drv.get("reason"))
		if bool(drv.get("ok", false)):
			BuildOps.apply_remove_any(_world, drv["room"], &"furniture", dup_cell,
				dblk.block_id, dblk.grid_position, dblk.elevation,
				Vector2i.ZERO, dblk.furniture_rotation_degrees, false)
	var remaining := 0
	for b in room.block_layer.get_blocks_at(dup_cell):
		if b.block_id == &"chair":
			remaining += 1
	_expect(remaining == 1, "expected 1 stacked chair after remove, found %d" % remaining)

	# Unsupported category rejects cleanly.
	var bad_cat := BuildOps.validate_place_any(_world, no_players,
		{"room_id": Vector2i(0, 0), "cell": Vector2i(1, 1),
			"category": &"wall", "object_id": &"x"})
	_expect(not bool(bad_cat.get("ok", true))
		and bad_cat.get("reason") == &"unsupported_category",
		"unknown category not rejected as unsupported_category")

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
