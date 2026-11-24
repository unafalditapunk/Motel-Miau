extends SceneTree

## Smoke test for Phase C2 per-player floor transitions. Boots a real
## WorldBootstrap headless, stands up a SERVER-mode MultiplayerManager
## against it, simulates two client bodies, and drives
## _handle_floor_transition directly (RPC sends fail harmlessly without
## an ENet peer — the server-side state changes are what is asserted).
## Also verifies the client half: a destination-floor snapshot built
## with an explicit floor_def applies cleanly onto a replica
## FloorManager/RoomWorld that never had the floor registered.

const BOOTSTRAP_SCENE := "res://Scenes/World/WorldBootstrap.tscn"
const GRID_PATH := "res://Resources/IsometricGrid/TestGrid.tres"
const TILE_CATALOG_PATH := "res://Resources/TileCatalog.tres"
const BLOCK_CATALOG_PATH := "res://Resources/BlockCatalog.tres"
const FURNITURE_CATALOG_PATH := "res://Resources/FurnitureCatalog.tres"
const CARPET_CATALOG_PATH := "res://Resources/CarpetCatalog.tres"
const BLOCK_SCENE_PATH := "res://Scenes/Objects/Block.tscn"
const PLAYER_SCENE_PATH := "res://Scenes/Player/Player.tscn"
const SCRATCH_ROOT := "user://smoke_floor_transition"

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

func _run_checks() -> void:
	_expect(_world != null and _world.floor_manager != null
		and _world.floor_manager.active_floor != null
		and _world.floor_manager.active_floor.floor_id == &"motel",
		"motel floor did not boot: %s" % str(_world.floor_manager.active_floor))
	if _world == null or _world.floor_manager == null:
		return
	var fm := _world.floor_manager

	# A second floor the server knows about.
	var specs: Array[FloorRoomSpec] = [
		_spec(Vector2i(0, 0), Vector2i(0, 0), Vector2i(8, 8)),
		_spec(Vector2i(1, 0), Vector2i(8, 0), Vector2i(8, 8)),
	]
	var floor_b := fm.create_floor(&"floor_b", "Floor B", specs)
	_expect(floor_b != null, "server create_floor floor_b failed")
	if floor_b == null:
		return

	_make_server()
	_expect(_mm._primary_floor_id() == &"motel", "primary floor id wrong")

	# Two simulated client bodies, both starting on the motel floor.
	var body_a: Player = _mm._spawn_body(7)
	var body_b: Player = _mm._spawn_body(8)
	_expect(body_a != null and body_b != null, "server bodies failed to spawn")
	if body_a == null or body_b == null:
		return
	_mm._peer_floor[7] = &"motel"
	_mm._peer_floor[8] = &"motel"
	var motel_world := _world.room_world
	var motel_rooms := motel_world.registry.get_rooms().size()
	_expect(motel_rooms > 0, "motel world has no rooms")

	# --- rejections leave everything untouched -------------------------
	_mm._handle_floor_transition(77, &"floor_b")   # no body -> not_ready
	_expect(not _mm._peer_floor.has(77), "ghost peer gained a floor")
	_mm._handle_floor_transition(7, &"no_such_floor")
	_expect(_mm._peer_floor.get(7) == &"motel", "unknown floor changed peer floor")
	_expect(body_a.get_parent() == motel_world.entity_layer,
		"rejected transition reparented the body")
	_mm._handle_floor_transition(7, &"motel")     # already there
	_expect(_mm._peer_floor.get(7) == &"motel", "same-floor transition changed peer floor")

	# --- valid transition ----------------------------------------------
	_mm._handle_floor_transition(7, &"floor_b")
	_expect(_mm._peer_floor.get(7) == &"floor_b", "peer floor not updated")
	var dest_world: RoomWorld = fm.world_for_floor(&"floor_b")
	_expect(dest_world != null and dest_world != motel_world,
		"floor_b has no distinct runtime world")
	if dest_world == null:
		return
	_expect(dest_world.get_rooms().size() == 2, "floor_b world room count wrong")
	_expect(body_a.get_parent() == dest_world.entity_layer,
		"body A not reparented into floor_b world")
	_expect(body_a.room_world == dest_world,
		"body A room_world not updated to floor_b world")
	_expect(body_b.room_world == motel_world,
		"body B room_world changed")
	_expect(body_a.room != null and body_a.room.room_coordinates == Vector2i.ZERO,
		"body A not placed in floor_b entry room")

	# The untouched peer keeps its floor, world, and room.
	_expect(_mm._peer_floor.get(8) == &"motel", "peer B floor changed")
	_expect(body_b.get_parent() == motel_world.entity_layer,
		"peer B body moved worlds")
	_expect(motel_world.registry.get_rooms().size() == motel_rooms,
		"motel world room count changed")
	# And the bound world still serves the active floor.
	_expect(fm.world_for_floor(&"motel") == motel_world, "motel world binding lost")

	# --- per-player snapshot: build for floor_b, apply on a replica ----
	var snapshot := WorldSnapshot.build(fm, dest_world, floor_b)
	_expect(not snapshot.is_empty(), "destination snapshot build failed")
	_expect(String(snapshot.get("floor_id", "")) == "floor_b",
		"snapshot floor_id wrong")
	var parsed: Variant = JSON.parse_string(JSON.stringify(snapshot))
	_expect(parsed is Dictionary, "snapshot JSON round-trip failed")
	if not (parsed is Dictionary):
		return

	# Client replica: FloorManager + RoomWorld that only know motel.
	var client_fm := FloorManager.new()
	client_fm.name = "ClientFloorManager"
	root.add_child(client_fm)
	var client_world := _make_replica_world()
	client_fm.room_world = client_world
	# The client already has the motel floor registered from its join
	# snapshot; floor_b is unknown — apply must register it as replica.
	var client_motel := Floor.new()
	client_motel.floor_id = &"motel"
	client_motel.display_name = "Motel"
	client_motel.entry_room_id = Vector2i.ZERO
	var cm_spec := _spec(Vector2i.ZERO, Vector2i.ZERO, Vector2i(8, 8))
	client_motel.rooms.assign([cm_spec])
	client_fm.register_floor(client_motel)

	var client_player := _make_replica_player(client_world)
	var applied := WorldSnapshot.apply(client_fm, client_world, client_player, parsed)
	_expect(applied, "destination snapshot apply failed on replica")
	_expect(client_fm.get_floor(&"floor_b") != null, "floor_b not registered on replica")
	_expect(client_world.get_rooms().size() == 2,
		"replica floor_b room count wrong")
	_expect(client_fm.active_floor != null and client_fm.active_floor.floor_id == &"floor_b",
		"replica active floor not floor_b")

	# --- client request gating ------------------------------------------
	var client_mm := MultiplayerManager.new()
	client_mm.name = "ClientMM"
	client_mm.mode = MultiplayerManager.Mode.CLIENT
	root.add_child(client_mm)
	_expect(not client_mm.request_floor_transition(&"floor_b"),
		"unconnected client transition request accepted")
	client_mm._connected = true
	client_mm.world_synced = true
	client_mm._my_floor_id = &"motel"
	_expect(client_mm.request_floor_transition(&"floor_b"),
		"connected client transition request refused")
	_expect(client_mm._transition_pending, "transition pending flag not set")
	_expect(not client_mm.can_request_build(), "build allowed during pending transition")
	_expect(not client_mm.request_floor_transition(&"floor_b"),
		"duplicate transition request accepted while pending")
	client_mm.queue_free()

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
		print("FLOOR_TRANSITION_SMOKE: OK")
	else:
		print("FLOOR_TRANSITION_SMOKE: FAILED (%d)" % _failures.size())
		for failure in _failures:
			print("  FAIL: %s" % failure)
