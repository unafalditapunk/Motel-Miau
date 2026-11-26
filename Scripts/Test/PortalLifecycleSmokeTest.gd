extends SceneTree

## Smoke test for Phase P4 portal/transition lifecycle hardening.
## Boots a real WorldBootstrap headless and covers:
##   - deferred avatar spawning (P4.1): spawn states that arrive
##     before their room exists are queued, retried, deduplicated,
##     and cleaned up on despawn/floor-change;
##   - id-matched transition rejections (P4.3): a stale reject must
##     not clear a newer pending transition;
##   - occupied-floor deletion rejection (P4.2): the floor, its
##     runtime world, and every peer floor stay untouched, the
##     floor remains usable, and a pending join snapshot guards
##     primary-floor deletion.
## Server-side handlers are driven directly (RPC sends fail
## harmlessly without an ENet peer), same as PortalTransitionSmokeTest.

const BOOTSTRAP_SCENE := "res://Scenes/World/WorldBootstrap.tscn"
const GRID_PATH := "res://Resources/IsometricGrid/TestGrid.tres"
const TILE_CATALOG_PATH := "res://Resources/TileCatalog.tres"
const BLOCK_CATALOG_PATH := "res://Resources/BlockCatalog.tres"
const FURNITURE_CATALOG_PATH := "res://Resources/FurnitureCatalog.tres"
const CARPET_CATALOG_PATH := "res://Resources/CarpetCatalog.tres"
const BLOCK_SCENE_PATH := "res://Scenes/Objects/Block.tscn"
const PLAYER_SCENE_PATH := "res://Scenes/Player/Player.tscn"
const SCRATCH_ROOT := "user://smoke_portal_lifecycle"

var _world: WorldBootstrap
var _mm: MultiplayerManager
var _frames := 0
var _failures: Array[String] = []

func _initialize() -> void:
	FloorSaveSystem.save_root = SCRATCH_ROOT
	_remove_dir_contents(SCRATCH_ROOT)

func _process(_delta: float) -> bool:
	_frames += 1
	if _frames == 1:
		_boot()
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

func _spec(room_id: Vector2i, origin: Vector2i, size: Vector2i) -> FloorRoomSpec:
	var spec := FloorRoomSpec.new()
	spec.room_id = room_id
	spec.global_origin = origin
	spec.size = size
	return spec

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

## Client fixture: FloorManager + materialized replica world (rooms
## (0,0) and (1,0) on 'motel') + player behind a WorldBootstrap stub,
## plus a synced CLIENT-mode manager.
func _make_client() -> Dictionary:
	var fm := FloorManager.new()
	fm.name = "ClientFloorManager"
	root.add_child(fm)
	var world := _make_replica_world()
	fm.room_world = world
	var floor_def := Floor.new()
	floor_def.floor_id = &"life_motel"
	floor_def.display_name = "Motel"
	floor_def.entry_room_id = Vector2i.ZERO
	floor_def.rooms.assign([
		_spec(Vector2i.ZERO, Vector2i.ZERO, Vector2i(8, 8)),
		_spec(Vector2i(1, 0), Vector2i(8, 0), Vector2i(8, 8)),
	])
	fm.register_floor(floor_def)
	_expect(fm.materialize_floor(floor_def, world),
		"client replica floor failed to materialize")
	var player := _make_replica_player(world)
	var stub := WorldBootstrap.new()
	stub.floor_manager = fm
	stub.room_world = world
	stub.player = player
	var mm := MultiplayerManager.new()
	mm.name = "ClientMM"
	mm.mode = MultiplayerManager.Mode.CLIENT
	mm._world = stub
	mm._player_scene = world.player_scene
	mm._connected = true
	mm.world_synced = true
	mm._my_floor_id = &"life_motel"
	root.add_child(mm)
	return {"fm": fm, "world": world, "player": player, "mm": mm}

func _run_checks() -> void:
	_expect(_world != null and _world.floor_manager != null
		and _world.floor_manager.active_floor != null
		and _world.floor_manager.active_floor.floor_id == &"motel",
		"motel floor did not boot")
	if _world == null or _world.floor_manager == null:
		return
	var fm := _world.floor_manager

	# --- floors for the server-side lifecycle checks ------------------
	var specs: Array[FloorRoomSpec] = [
		_spec(Vector2i(0, 0), Vector2i(0, 0), Vector2i(8, 8)),
		_spec(Vector2i(1, 0), Vector2i(8, 0), Vector2i(8, 8)),
	]
	_expect(fm.create_floor(&"floor_b", "Floor B", specs) != null,
		"server create_floor floor_b failed")
	_expect(fm.create_floor(&"floor_c", "Floor C", specs) != null,
		"server create_floor floor_c failed")
	_make_server()

	# --- P4.2: occupied-floor deletion is refused, nothing mutates ----
	var body_a: Player = _mm._spawn_body(7)
	var body_b: Player = _mm._spawn_body(8)
	_expect(body_a != null and body_b != null, "server bodies failed to spawn")
	if body_a == null or body_b == null:
		return
	_mm._peer_floor[7] = &"motel"
	_mm._peer_floor[8] = &"motel"
	# Occupy floor_b with peer 7 through the real transition path.
	_mm._handle_floor_transition(7, &"floor_b")
	_expect(_mm._peer_floor.get(7) == &"floor_b",
		"setup transition to floor_b failed")
	var floor_b_world := fm.world_for_floor(&"floor_b")
	_expect(floor_b_world != null, "floor_b runtime world missing")
	var op_id := 100
	_mm._handle_floor_op(8, op_id, {"op": "floor_delete", "floor_id": "floor_b"})
	_expect(fm.get_floor(&"floor_b") != null,
		"occupied floor_b was unregistered")
	_expect(fm.world_for_floor(&"floor_b") == floor_b_world,
		"occupied floor_b runtime world was released")
	_expect(_mm._peer_floor.get(7) == &"floor_b"
		and _mm._peer_floor.get(8) == &"motel",
		"occupied-floor rejection changed peer floors")
	_expect(body_a.get_parent() == floor_b_world.entity_layer,
		"occupied-floor rejection moved body A")
	# floor_b stays fully usable: peer 8 can still travel there once
	# its in-flight guard clears — simulate the ack first.
	_mm._release_transition_guard(7, 0)
	_mm._handle_floor_transition(8, &"floor_b")
	_expect(_mm._peer_floor.get(8) == &"floor_b",
		"floor_b unusable after occupied-delete rejection")

	# --- P4.2: pending joiner guards primary-floor deletion -----------
	_mm._pending_peers[99] = Time.get_ticks_msec()
	_mm._handle_floor_op(8, op_id + 1,
		{"op": "floor_delete", "floor_id": "motel"})
	_expect(fm.active_floor != null and fm.active_floor.floor_id == &"motel",
		"primary floor deleted while a join snapshot was in flight")
	# Same request against an unoccupied non-active floor still works
	# once the pending peer is gone.
	_mm._pending_peers.erase(99)
	_mm._release_transition_guard(8, 0)
	_mm._handle_floor_op(8, op_id + 2,
		{"op": "floor_delete", "floor_id": "floor_c"})
	_expect(fm.get_floor(&"floor_c") == null,
		"unoccupied floor_c delete did not apply after guards cleared")

	# --- P4.1: deferred avatar spawning -------------------------------
	var fx := _make_client()
	var cmm: MultiplayerManager = fx["mm"]
	var cfm: FloorManager = fx["fm"]
	var cworld: RoomWorld = fx["world"]
	var cplayer: Player = fx["player"]

	# Room (2,0) does not exist yet — spawn states for it must queue.
	var missing_room := Vector2i(2, 0)
	cmm._request_avatar_spawn(42, &"life_motel", missing_room,
		Vector2i(1, 1), 0.0, Vector2i(1, 0))
	_expect(cmm._pending_avatar_spawns.has(42),
		"missing-room spawn was not queued")
	_expect(not cmm._avatars.has(42),
		"missing-room spawn created an avatar")
	# A newer state for the same peer overwrites — still one entry.
	cmm._request_avatar_spawn(42, &"life_motel", missing_room,
		Vector2i(2, 2), 0.0, Vector2i(-1, 0))
	_expect(cmm._pending_avatar_spawns.size() == 1,
		"duplicate pending spawn entries for one peer")
	_expect(cmm._pending_avatar_spawns[42]["cell"] == Vector2i(2, 2),
		"newer spawn state did not overwrite the queued one")
	# Wrong-floor state: discarded, and the stale queue entry goes too.
	cmm._request_avatar_spawn(42, &"floor_b", Vector2i.ZERO,
		Vector2i.ZERO, 0.0, Vector2i(1, 0))
	_expect(not cmm._pending_avatar_spawns.has(42),
		"wrong-floor spawn was queued")
	_expect(not cmm._avatars.has(42),
		"wrong-floor spawn created an avatar")
	# Despawn clears a pending entry (peer left / floor changed).
	cmm._request_avatar_spawn(43, &"life_motel", missing_room,
		Vector2i(1, 1), 0.0, Vector2i(1, 0))
	cmm._remove_avatar(43)
	_expect(not cmm._pending_avatar_spawns.has(43),
		"despawn did not clear the pending spawn")
	# Floor change clears every pending entry.
	cmm._request_avatar_spawn(44, &"life_motel", missing_room,
		Vector2i(1, 1), 0.0, Vector2i(1, 0))
	cmm._apply_transition_spawn({})
	_expect(cmm._pending_avatar_spawns.is_empty(),
		"floor transition did not clear pending spawns")
	# Retry path: queue while unsynced -> stays pending; once synced
	# but room still missing -> still pending; room appears -> spawn.
	cmm.world_synced = false
	cmm._request_avatar_spawn(45, &"life_motel", missing_room,
		Vector2i(1, 1), 0.0, Vector2i(1, 0))
	_expect(cmm._pending_avatar_spawns.has(45),
		"pre-sync spawn was not queued")
	cmm.world_synced = true
	cmm._try_avatar_spawn(45)
	_expect(cmm._pending_avatar_spawns.has(45)
		and not cmm._avatars.has(45),
		"spawn applied before its room existed")
	# Materialize the room through the replica path, retry -> avatar.
	var added := cfm.replica_add_room(&"life_motel", {
		"room_id": [2, 0], "global_origin": [16, 0], "size": [8, 8]})
	_expect(added != null, "replica_add_room for (2,0) failed")
	cmm._try_avatar_spawn(45)
	_expect(cmm._avatars.has(45),
		"queued spawn did not apply once the room existed")
	_expect(not cmm._pending_avatar_spawns.has(45),
		"applied spawn stayed queued")
	# A state for the same peer now updates the live avatar instead
	# of queueing — no duplicate instance.
	var avatars_before := cmm._avatars.size()
	cmm._request_avatar_spawn(45, &"life_motel", missing_room,
		Vector2i(3, 3), 0.0, Vector2i(0, 1))
	_expect(cmm._avatars.size() == avatars_before,
		"state for live avatar spawned a duplicate")
	_expect(not cmm._pending_avatar_spawns.has(45),
		"live-avatar state was queued")
	cmm.queue_free()
	cfm.queue_free()
	cworld.queue_free()
	cplayer.queue_free()

	# --- P4.3: transition rejections are transition-id matched --------
	var fx2 := _make_client()
	var mm2: MultiplayerManager = fx2["mm"]
	var player2: Player = fx2["player"]
	var results: Array = []
	mm2.transition_result.connect(
		func(a: bool, r: StringName): results.append([a, r]))
	mm2._begin_client_transition()
	var serial := mm2._transition_request_serial
	# Stale rejection (wrong id) must not clear the pending request.
	mm2._handle_transition_rejected(&"unknown_floor", serial + 999)
	_expect(mm2._transition_pending,
		"stale rejection cleared the pending transition")
	_expect(results.is_empty(),
		"stale rejection emitted a transition result")
	# Matching rejection completes it: pending cleared, input
	# unlocked, failure result emitted.
	mm2._handle_transition_rejected(&"unknown_floor", serial)
	_expect(not mm2._transition_pending,
		"matching rejection did not clear the pending transition")
	_expect(not player2.local_input_locked,
		"matching rejection left input locked")
	_expect(results.size() == 1 and results[0][0] == false
		and results[0][1] == &"unknown_floor",
		"matching rejection did not emit transition_result(false)")
	# A rejection with no pending transition is ignored entirely.
	var result_count := results.size()
	mm2._handle_transition_rejected(&"busy", serial)
	_expect(results.size() == result_count,
		"rejection with no pending transition emitted a result")
	# Unversioned rejection (transition_id 0) still applies to the
	# live pending request — backwards-compatible path.
	mm2._begin_client_transition()
	serial = mm2._transition_request_serial
	mm2._handle_transition_rejected(&"busy", 0)
	_expect(not mm2._transition_pending,
		"unversioned rejection did not clear the pending transition")
	mm2.queue_free()
	(fx2["fm"] as FloorManager).queue_free()
	(fx2["world"] as RoomWorld).queue_free()
	player2.queue_free()

func _report() -> void:
	if _failures.is_empty():
		print("PORTAL_LIFECYCLE_SMOKE: OK")
	else:
		print("PORTAL_LIFECYCLE_SMOKE: FAILED (%d)" % _failures.size())
		for failure in _failures:
			print("  FAIL: %s" % failure)
