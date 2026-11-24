extends SceneTree

## Smoke test for Phase C4 authoritative floor create/delete. Boots a
## real WorldBootstrap headless, stands up a SERVER-mode
## MultiplayerManager, simulates client bodies across floors, and
## drives _handle_floor_op / _handle_floor_result directly (RPC sends
## fail harmlessly without an ENet peer — server/client state changes
## are what is asserted). Covers: create success + persistence,
## duplicate/invalid/built-in id rejection, delete occupancy/unknown
## rejection, runtime-world teardown, active-floor delete with
## runtime-world body migration, op-id replay, client replica
## apply without persistence, and snapshot floor-catalog reconcile.

const BOOTSTRAP_SCENE := "res://Scenes/World/WorldBootstrap.tscn"
const GRID_PATH := "res://Resources/IsometricGrid/TestGrid.tres"
const TILE_CATALOG_PATH := "res://Resources/TileCatalog.tres"
const BLOCK_CATALOG_PATH := "res://Resources/BlockCatalog.tres"
const FURNITURE_CATALOG_PATH := "res://Resources/FurnitureCatalog.tres"
const CARPET_CATALOG_PATH := "res://Resources/CarpetCatalog.tres"
const BLOCK_SCENE_PATH := "res://Scenes/Objects/Block.tscn"
const PLAYER_SCENE_PATH := "res://Scenes/Player/Player.tscn"
const SCRATCH_ROOT := "user://smoke_floor_ops"

var _world: WorldBootstrap
var _client_world: WorldBootstrap
var _mm: MultiplayerManager
var _client_mm: MultiplayerManager
var _frames := 0
var _op_serial := 0
var _failures: Array[String] = []

func _initialize() -> void:
	FloorSaveSystem.save_root = SCRATCH_ROOT
	_remove_dir_contents(SCRATCH_ROOT)

func _process(_delta: float) -> bool:
	_frames += 1
	if _frames == 1:
		_boot()
	# WorldBootstrap._ready is deferred; give it a few frames, then run.
	if _frames == 4:
		_run_checks()
		_report()
		quit()
		return true
	return false

func _boot() -> void:
	var scene := load(BOOTSTRAP_SCENE) as PackedScene
	_world = scene.instantiate() as WorldBootstrap
	_world.startup_floor_id = &"motel"
	root.add_child(_world)
	# A second bootstrap stands in for a multiplayer client's replica
	# world — it boots before any test floors exist so its registry
	# holds only shipped floors.
	_client_world = scene.instantiate() as WorldBootstrap
	_client_world.startup_floor_id = &"motel"
	root.add_child(_client_world)

func _remove_dir_contents(path: String) -> void:
	var dir := DirAccess.open(path)
	if dir == null:
		return
	for file_name in dir.get_files():
		dir.remove(file_name)
	for sub in dir.get_directories():
		_remove_dir_contents(path.path_join(sub))
		DirAccess.remove_absolute(path.path_join(sub))

func _expect(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)

func _make_server() -> void:
	_mm = MultiplayerManager.new()
	_mm.name = "MultiplayerManager"
	_mm.mode = MultiplayerManager.Mode.SERVER
	_mm._world = _world
	_mm._player_scene = _world.player_scene
	_mm.add_to_group(&"multiplayer_manager")
	root.add_child(_mm)

func _make_client() -> void:
	_client_mm = MultiplayerManager.new()
	_client_mm.name = "ClientMM"
	_client_mm.mode = MultiplayerManager.Mode.CLIENT
	_client_mm._world = _client_world
	_client_mm._player_scene = _client_world.player_scene
	_client_mm._connected = true
	_client_mm.world_synced = true
	_client_mm._my_floor_id = &"motel"
	root.add_child(_client_mm)

func _floor_op(peer_id: int, op: Dictionary) -> int:
	_op_serial += 1
	_mm._handle_floor_op(peer_id, _op_serial, op)
	return _op_serial

func _floor_op_with_id(peer_id: int, op_id: int, op: Dictionary) -> void:
	_mm._handle_floor_op(peer_id, op_id, op)

func _floor_dir_exists(floor_id: StringName) -> bool:
	var dir := FloorSaveSystem.floor_dir(floor_id)
	return dir != "" and DirAccess.dir_exists_absolute(dir)

func _run_checks() -> void:
	_expect(_world != null and _world.floor_manager != null
		and _world.floor_manager.active_floor != null
		and _world.floor_manager.active_floor.floor_id == &"motel",
		"server motel floor did not boot")
	_expect(_client_world != null and _client_world.floor_manager != null
		and _client_world.floor_manager.active_floor != null,
		"client replica world did not boot")
	if _world == null or _world.floor_manager == null \
			or _client_world == null or _client_world.floor_manager == null:
		return
	var fm := _world.floor_manager
	var cfm := _client_world.floor_manager

	# --- client request gating ----------------------------------------
	var gating_mm := MultiplayerManager.new()
	gating_mm.mode = MultiplayerManager.Mode.CLIENT
	root.add_child(gating_mm)
	_expect(not gating_mm.request_floor_create(&"x"),
		"unconnected client floor create accepted")
	_expect(not gating_mm.request_floor_delete(&"motel"),
		"unconnected client floor delete accepted")
	gating_mm._connected = true
	gating_mm.world_synced = true
	_expect(gating_mm.request_floor_create(&"x"),
		"connected client floor create refused")
	_expect(gating_mm.request_floor_delete(&"motel"),
		"connected client floor delete refused")
	gating_mm._transition_pending = true
	_expect(not gating_mm.request_floor_create(&"x"),
		"floor create allowed during pending transition")
	_expect(not gating_mm.request_floor_delete(&"motel"),
		"floor delete allowed during pending transition")
	gating_mm.queue_free()

	_make_server()
	var body_a: Player = _mm._spawn_body(7)
	var body_b: Player = _mm._spawn_body(8)
	_expect(body_a != null and body_b != null, "server bodies failed to spawn")
	if body_a == null or body_b == null:
		return
	_mm._peer_floor[7] = &"motel"
	_mm._peer_floor[8] = &"motel"

	# --- create: success, persistence, default layout -----------------
	var floors_before := fm.floors.size()
	_floor_op(7, {"op": "floor_create", "floor_id": &"mp_floor",
		"display_name": "MP Floor"})
	var mp_def := fm.get_floor(&"mp_floor")
	_expect(mp_def != null, "floor_create did not register mp_floor")
	_expect(fm.floors.size() == floors_before + 1, "floor count did not grow")
	if mp_def != null:
		_expect(mp_def.display_name == "MP Floor", "display name not applied")
		_expect(mp_def.rooms.size() == 1 and mp_def.rooms[0] != null
			and mp_def.rooms[0].size == Vector2i(8, 8),
			"created floor lacks the default 8x8 room")
		_expect(mp_def.entry_room_id == mp_def.rooms[0].room_id,
			"created floor entry room not set")
	_expect(_floor_dir_exists(&"mp_floor"), "floor_def.json not persisted")
	_expect(FileAccess.file_exists(FloorSaveSystem.floor_def_path(&"mp_floor")),
		"floor_def.json missing on disk")

	# --- create: rejections ---------------------------------------------
	_floor_op(7, {"op": "floor_create", "floor_id": &"mp_floor"})
	_expect(fm.floors.size() == floors_before + 1, "duplicate floor create applied")
	for bad_id in [&"", &"../evil", &"a/b", &"motel", &"x".repeat(65)]:
		_floor_op(7, {"op": "floor_create", "floor_id": bad_id})
	_expect(fm.floors.size() == floors_before + 1,
		"invalid/built-in/oversized floor id accepted")
	# Op-id replay: a fresh id applies once; reusing it must not
	# re-apply a different op.
	var id1 := _floor_op(7, {"op": "floor_create", "floor_id": &"replay_floor"})
	_floor_op_with_id(7, id1, {"op": "floor_create", "floor_id": &"replay_floor2"})
	_expect(fm.get_floor(&"replay_floor") != null,
		"first op-id use did not apply")
	_expect(fm.get_floor(&"replay_floor2") == null,
		"replayed op id applied a second floor create")
	# Unknown op kind and ghost peer.
	_floor_op(7, {"op": "bogus", "floor_id": &"whatever"})
	_floor_op(77, {"op": "floor_delete", "floor_id": &"mp_floor"})
	_expect(fm.get_floor(&"mp_floor") != null, "ghost-peer delete applied")
	# Remove replay_floor so later floor-count assertions stay exact.
	_floor_op(7, {"op": "floor_delete", "floor_id": &"replay_floor"})
	_expect(fm.get_floor(&"replay_floor") == null, "replay_floor cleanup failed")

	# --- delete: rejections ---------------------------------------------
	_floor_op(7, {"op": "floor_delete", "floor_id": &"no_such_floor"})
	# Occupied: park peer 8's tracked floor on mp_floor.
	_mm._peer_floor[8] = &"mp_floor"
	_floor_op(7, {"op": "floor_delete", "floor_id": &"mp_floor"})
	_expect(fm.get_floor(&"mp_floor") != null, "occupied floor delete applied")
	_mm._peer_floor[8] = &"motel"

	# --- visit + leave: runtime world lifecycle -------------------------
	_mm._handle_floor_transition(8, &"mp_floor")
	var mp_world: RoomWorld = fm.world_for_floor(&"mp_floor")
	_expect(mp_world != null and mp_world != _world.room_world,
		"mp_floor runtime world not materialized")
	_expect(fm.runtime_worlds.has(&"mp_floor"), "runtime_worlds missing mp_floor")
	# Peer 8 leaves; the runtime world is RETAINED (safe policy).
	_mm._handle_floor_transition(8, &"motel")
	_expect(fm.runtime_worlds.has(&"mp_floor"),
		"runtime world freed on depart — retention policy changed")
	# Peer 7 makes a REAL trip to village so motel is genuinely
	# unoccupied when the delete arrives (occupancy tracks _peer_floor,
	# which only real transitions keep honest).
	_mm._handle_floor_transition(7, &"village")
	_expect(_mm._peer_floor[7] == &"village", "peer 7 did not reach village")
	# Now unoccupied: delete succeeds, world torn down, save dir gone.
	_floor_op(7, {"op": "floor_delete", "floor_id": &"mp_floor"})
	_expect(fm.get_floor(&"mp_floor") == null, "floor_delete did not unregister")
	_expect(not fm.runtime_worlds.has(&"mp_floor"),
		"runtime world not released on floor delete")
	_expect(not _floor_dir_exists(&"mp_floor"), "floor save dir not removed")
	_expect(fm.floors.size() == floors_before, "floor count did not return")

	# --- snapshot catalog: join/missed-broadcast reconcile ---------------
	# Recreate the floor, then verify a fresh replica learns it from
	# the snapshot catalog alone (no floor_result involved).
	_floor_op(7, {"op": "floor_create", "floor_id": &"cat_floor",
		"display_name": "Catalog Floor"})
	var snapshot := WorldSnapshot.build(fm, _world.room_world)
	var parsed: Variant = JSON.parse_string(JSON.stringify(snapshot))
	_expect(parsed is Dictionary and (parsed as Dictionary).has("floors"),
		"snapshot missing floor catalog")
	var replica_fm := FloorManager.new()
	replica_fm.name = "ReplicaFM"
	root.add_child(replica_fm)
	var replica_world := _make_replica_world()
	replica_fm.room_world = replica_world
	var replica_player := _make_replica_player(replica_world)
	_expect(WorldSnapshot.apply(replica_fm, replica_world, replica_player, parsed),
		"catalog snapshot apply failed")
	_expect(replica_fm.get_floor(&"cat_floor") != null,
		"snapshot catalog did not register cat_floor on replica")
	_expect(replica_fm.get_floor(&"forest") != null,
		"snapshot catalog dropped shipped forest floor")
	# Server deletes cat_floor; the NEXT snapshot must evict the
	# replica even though no delete broadcast is replayed.
	_floor_op(7, {"op": "floor_delete", "floor_id": &"cat_floor"})
	var snapshot2 := WorldSnapshot.build(fm, _world.room_world)
	var parsed2: Variant = JSON.parse_string(JSON.stringify(snapshot2))
	_expect(WorldSnapshot.apply(replica_fm, replica_world, replica_player, parsed2),
		"second catalog snapshot apply failed")
	_expect(replica_fm.get_floor(&"cat_floor") == null,
		"snapshot catalog did not evict deleted cat_floor")
	_expect(replica_fm.get_floor(&"motel") != null
		and replica_fm.active_floor != null
		and replica_fm.active_floor.floor_id == &"motel",
		"replica lost its active floor after reconcile")
	replica_fm.queue_free()
	replica_world.queue_free()

	# --- client replica apply via _handle_floor_result ------------------
	_make_client()
	# Create wire_floor through the real op path, then replay its
	# broadcast payload shape at the client replica.
	_floor_op(7, {"op": "floor_create", "floor_id": &"wire_floor",
		"display_name": "Wire Floor"})
	var wire_def := fm.get_floor(&"wire_floor")
	_expect(wire_def != null, "wire_floor create failed")
	var client_def_before := cfm.floors.size()
	_client_mm._handle_floor_result(900, true, &"", {
		"op": "floor_create", "floor_id": &"wire_floor",
		"floor_def": FloorSaveSystem.floor_definition_data(wire_def)})
	_expect(cfm.get_floor(&"wire_floor") != null,
		"client replica did not register wire_floor")
	_expect(cfm.floors.size() == client_def_before + 1,
		"client floor count did not grow")
	# Duplicate broadcast is idempotent, not an error.
	_client_mm._handle_floor_result(901, true, &"", {
		"op": "floor_create", "floor_id": &"wire_floor",
		"floor_def": FloorSaveSystem.floor_definition_data(wire_def)})
	_expect(cfm.floors.size() == client_def_before + 1,
		"duplicate floor_create grew the replica registry")
	# Delete result evicts the replica.
	_client_mm._handle_floor_result(902, true, &"", {
		"op": "floor_delete", "floor_id": &"wire_floor"})
	_expect(cfm.get_floor(&"wire_floor") == null,
		"client replica did not unregister wire_floor")
	# Rejection propagates as accepted=false.
	var rejected := [false]
	_client_mm.floor_result.connect(func(_id: int, acc: bool, _r: StringName, _p: Dictionary) -> void:
		rejected[0] = not acc)
	_client_mm._handle_floor_result(903, false, &"occupied", {})
	_expect(rejected[0], "floor_result rejection not emitted")
	# Divergence: delete broadcast for the client's ACTIVE floor is
	# refused by unregister_floor_replica and reported as diverged.
	var diverged := [false]
	_client_mm.floor_result.connect(func(_id: int, acc: bool, reason: StringName, _p: Dictionary) -> void:
		if reason == &"diverged":
			diverged[0] = true)
	_client_mm._handle_floor_result(904, true, &"", {
		"op": "floor_delete", "floor_id": &"motel"})
	_expect(cfm.active_floor != null and cfm.active_floor.floor_id == &"motel",
		"active floor replica was unregistered")
	_expect(diverged[0], "active-floor delete not reported as diverged")

	# --- active-floor delete + runtime-body migration --------------------
	# Peer 8 visits forest (runtime world); peer 7 is already on
	# village. Motel is active with no peer bodies — delete must
	# succeed via the switch_floor + migrate path.
	_mm._handle_floor_transition(8, &"forest")
	_expect(_mm._peer_floor[8] == &"forest", "peer 8 did not reach forest")
	var forest_world_before: RoomWorld = fm.world_for_floor(&"forest")
	_expect(forest_world_before != null, "forest world missing before delete")
	_floor_op(7, {"op": "floor_delete", "floor_id": &"motel"})
	_expect(fm.get_floor(&"motel") == null, "active motel delete failed")
	_expect(fm.active_floor != null and fm.active_floor.floor_id != &"motel",
		"active floor not switched after motel delete")
	# The core invariant: every peer's body lives in the world its
	# floor resolves to — no orphaned runtime worlds.
	var forest_world_after: RoomWorld = fm.world_for_floor(&"forest")
	_expect(forest_world_after != null, "forest world missing after delete")
	_expect(body_b.room_world == forest_world_after,
		"peer 8 body not rebound to forest's authoritative world")
	_expect(not fm.runtime_worlds.has(fm.active_floor.floor_id),
		"runtime world shadows the active floor after migration")

	# Deterministic migration check: move peer 8 onto ANY non-active
	# floor (guaranteed a runtime world), activate that floor via
	# switch_floor — its runtime world becomes shadowed — then
	# _migrate_runtime_bodies_to_bound must rebind the body into the
	# bound world before teardown.
	var mig_floor := &""
	for candidate in fm.floors:
		if candidate != fm.active_floor:
			mig_floor = candidate.floor_id
			break
	_expect(mig_floor != &"", "no non-active floor available for migration test")
	if mig_floor == &"":
		return
	_mm._handle_floor_transition(8, mig_floor)
	var mig_world: RoomWorld = fm.runtime_worlds.get(mig_floor)
	_expect(mig_world != null and body_b.room_world == mig_world,
		"peer 8 did not enter %s's runtime world" % mig_floor)
	_expect(fm.switch_floor(mig_floor), "switch_floor to %s failed" % mig_floor)
	_mm._migrate_runtime_bodies_to_bound(mig_floor)
	_expect(body_b.room_world == _world.room_world,
		"migration did not rebind peer 8's body to the bound world")
	_expect(not fm.runtime_worlds.has(mig_floor),
		"%s runtime world not released after migration" % mig_floor)
	# Test floors are left registered: each smoke test owns a scratch
	# save_root and the process exits, so no cleanup is required.

func _make_replica_world() -> RoomWorld:
	var world := RoomWorld.new()
	world.name = "ReplicaWorld"
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

func _make_replica_player(world: RoomWorld) -> Player:
	var scene := load(PLAYER_SCENE_PATH) as PackedScene
	var player := scene.instantiate() as Player
	player.grid = world.grid
	player.move_duration = 0.0
	world.entity_layer.add_child(player)
	return player

func _report() -> void:
	if _failures.is_empty():
		print("FLOOR_OPS_SMOKE: OK")
	else:
		print("FLOOR_OPS_SMOKE: FAILED (%d)" % _failures.size())
		for failure in _failures:
			print("  FAIL: %s" % failure)
