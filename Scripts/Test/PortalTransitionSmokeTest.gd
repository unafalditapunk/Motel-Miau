extends SceneTree

## Smoke test for Phase P2 multiplayer floor portals. Boots a real
## WorldBootstrap headless, stands up a SERVER-mode MultiplayerManager,
## simulates client bodies, and drives _handle_portal_transition /
## _handle_floor_transition directly (RPC sends fail harmlessly
## without an ENet peer — the server-side state changes are what is
## asserted). Also covers client-side request gating, the transition
## timeout watchdog, the server in-flight guard, and portal delivery
## through WorldSnapshot.

const BOOTSTRAP_SCENE := "res://Scenes/World/WorldBootstrap.tscn"
const GRID_PATH := "res://Resources/IsometricGrid/TestGrid.tres"
const TILE_CATALOG_PATH := "res://Resources/TileCatalog.tres"
const BLOCK_CATALOG_PATH := "res://Resources/BlockCatalog.tres"
const FURNITURE_CATALOG_PATH := "res://Resources/FurnitureCatalog.tres"
const CARPET_CATALOG_PATH := "res://Resources/CarpetCatalog.tres"
const BLOCK_SCENE_PATH := "res://Scenes/Objects/Block.tscn"
const PLAYER_SCENE_PATH := "res://Scenes/Player/Player.tscn"
const SCRATCH_ROOT := "user://smoke_portal_transition"

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

## Places a portal on floor_id at the world cell under body, moves the
## body onto it, and returns the portal's world cell (ZERO if the
## cell refused placement).
func _portal_under_body(floor_id: StringName, body: Player,
		destination: StringName) -> Vector2i:
	var fm := _world.floor_manager
	var cell := body.room.world_cell_coordinates(body.grid_position)
	if fm.place_portal_on_floor(floor_id, cell, destination):
		return cell
	# Spawn cell may sit on an interactive connection — try neighbours.
	for dy in range(-1, 2):
		for dx in range(-1, 2):
			var local := body.grid_position + Vector2i(dx, dy)
			if not body.room.has_cell(local):
				continue
			var wc := body.room.world_cell_coordinates(local)
			if fm.place_portal_on_floor(floor_id, wc, destination):
				body.place_at(local, body.stand_elevation_at(local))
				return wc
	return Vector2i.ZERO

func _run_checks() -> void:
	_expect(_world != null and _world.floor_manager != null
		and _world.floor_manager.active_floor != null
		and _world.floor_manager.active_floor.floor_id == &"motel",
		"motel floor did not boot")
	if _world == null or _world.floor_manager == null:
		return
	var fm := _world.floor_manager

	var specs: Array[FloorRoomSpec] = [
		_spec(Vector2i(0, 0), Vector2i(0, 0), Vector2i(8, 8)),
		_spec(Vector2i(1, 0), Vector2i(8, 0), Vector2i(8, 8)),
	]
	_expect(fm.create_floor(&"floor_b", "Floor B", specs) != null,
		"server create_floor floor_b failed")
	_expect(fm.create_floor(&"floor_c", "Floor C", specs) != null,
		"server create_floor floor_c failed")

	_make_server()
	var body_a: Player = _mm._spawn_body(7)
	var body_b: Player = _mm._spawn_body(8)
	_expect(body_a != null and body_b != null, "server bodies failed to spawn")
	if body_a == null or body_b == null:
		return
	_mm._peer_floor[7] = &"motel"
	_mm._peer_floor[8] = &"motel"
	var motel_world := _world.room_world

	# Portal on the motel floor under body A -> floor_b.
	var portal_cell := _portal_under_body(&"motel", body_a, &"floor_b")
	_expect(portal_cell != Vector2i.ZERO, "could not place portal under body A")
	if portal_cell == Vector2i.ZERO:
		return
	# Random spawns can collide: B must NOT already stand on the
	# portal cell or its "wrong cell" rejection checks would be
	# legitimately accepted transitions instead.
	if body_b.room.world_cell_coordinates(body_b.grid_position) == portal_cell:
		for dy in range(-2, 3):
			for dx in range(-2, 3):
				var alt := body_b.grid_position + Vector2i(dx, dy)
				if body_b.room.has_cell(alt) \
						and body_b.room.world_cell_coordinates(alt) != portal_cell:
					body_b.place_at(alt, body_b.stand_elevation_at(alt))
					break
			if body_b.room.world_cell_coordinates(body_b.grid_position) != portal_cell:
				break
	_expect(body_b.room.world_cell_coordinates(body_b.grid_position) != portal_cell,
		"could not move body B off the portal cell")
	_expect(fm.portal_at_on_floor(&"motel", portal_cell) != null,
		"portal not registered on motel floor")

	# --- validation rejections leave everything untouched -------------
	_mm._handle_portal_transition(77, portal_cell)      # no body
	_expect(not _mm._peer_floor.has(77), "ghost peer gained a floor")
	_mm._handle_portal_transition(8, Vector2i(9999, 9999))  # no portal
	_expect(_mm._peer_floor.get(8) == &"motel", "unknown cell changed peer floor")
	# Peer 8 is NOT standing on the portal cell -> not_at_portal.
	_mm._handle_portal_transition(8, portal_cell)
	_expect(_mm._peer_floor.get(8) == &"motel",
		"portal request from wrong cell changed peer floor")
	_expect(body_b.get_parent() == motel_world.entity_layer,
		"rejected portal transition reparented body B")

	# Self-destination and missing-destination portals bypass the
	# placement API (which refuses them) — inject raw spec data.
	var motel_def := fm.get_floor(&"motel")
	var self_portal := FloorPortal.new()
	self_portal.portal_id = &"portal_self"
	self_portal.room_id = body_b.room.room_coordinates
	self_portal.world_cell = body_b.room.world_cell_coordinates(body_b.grid_position)
	self_portal.destination_floor_id = &"motel"
	motel_def.portals.append(self_portal)
	var ghost_portal := FloorPortal.new()
	ghost_portal.portal_id = &"portal_ghost"
	ghost_portal.room_id = body_b.room.room_coordinates
	ghost_portal.world_cell = body_b.room.world_cell_coordinates(
		body_b.grid_position + Vector2i(1, 0))
	ghost_portal.destination_floor_id = &"ghost_floor"
	motel_def.portals.append(ghost_portal)
	_mm._handle_portal_transition(8, self_portal.world_cell)
	_expect(_mm._peer_floor.get(8) == &"motel", "self-destination portal transitioned")
	_mm._handle_portal_transition(8, ghost_portal.world_cell)
	_expect(_mm._peer_floor.get(8) == &"motel", "missing-destination portal transitioned")
	motel_def.portals.erase(self_portal)
	motel_def.portals.erase(ghost_portal)

	# --- valid portal transition --------------------------------------
	_mm._handle_portal_transition(7, portal_cell)
	_expect(_mm._peer_floor.get(7) == &"floor_b", "portal transition did not update peer floor")
	var dest_world: RoomWorld = fm.world_for_floor(&"floor_b")
	_expect(dest_world != null and dest_world != motel_world,
		"floor_b has no distinct runtime world")
	if dest_world == null:
		return
	_expect(body_a.get_parent() == dest_world.entity_layer,
		"body A not reparented into floor_b world")
	_expect(body_a.room_world == dest_world, "body A room_world not updated")
	_expect(body_b.room_world == motel_world, "body B room_world changed")
	_expect(_mm._peer_floor.get(8) == &"motel", "peer B floor changed")
	_expect(body_b.get_parent() == motel_world.entity_layer,
		"peer B body moved worlds")
	# Destination spawn: body A stands in a floor_b room at a spawn.
	_expect(body_a.room != null, "body A has no room after portal transition")

	# --- portal arrival-cell override (portal chains) -----------------
	# Peer 11 portals motel -> floor_c arriving on global cell (3,3) —
	# inside floor_c room (0,0) — instead of a random spawn point.
	var body_d: Player = _mm._spawn_body(11)
	_expect(body_d != null, "arrival-test body failed to spawn")
	if body_d != null:
		_mm._peer_floor[11] = &"motel"
		var arrival_cell := Vector2i(3, 3)
		var placed_cell := Vector2i.ZERO
		var base_cell := body_d.room.world_cell_coordinates(body_d.grid_position)
		for dy in range(-1, 2):
			for dx in range(-1, 2):
				var wc := base_cell + Vector2i(dx, dy)
				if fm.place_portal_on_floor(&"motel", wc, &"floor_c",
						arrival_cell):
					placed_cell = wc
					break
			if placed_cell != Vector2i.ZERO:
				break
		_expect(placed_cell != Vector2i.ZERO,
			"could not place arrival-override portal")
		if placed_cell != Vector2i.ZERO:
			# Stand the body on the portal cell.
			var p_room := motel_world.get_room_at_global_cell(placed_cell)
			_expect(p_room != null, "arrival portal cell not in a motel room")
			if p_room != null:
				var p_local := placed_cell - p_room.cell_origin
				body_d.room = p_room
				body_d.block_layer = p_room.block_layer
				body_d.room_size = p_room.size
				body_d.place_at(p_local, body_d.stand_elevation_at(p_local))
				_mm._handle_portal_transition(11, placed_cell)
				_expect(_mm._peer_floor.get(11) == &"floor_c",
					"arrival-override portal transition failed")
				var floor_c_world: RoomWorld = fm.world_for_floor(&"floor_c")
				_expect(body_d.room_world == floor_c_world,
					"arrival body not in floor_c world")
				if body_d.room != null:
					_expect(body_d.room.room_coordinates == Vector2i(0, 0),
						"arrival body wrong room: %s" % body_d.room.room_coordinates)
					_expect(body_d.grid_position == \
							arrival_cell - body_d.room.cell_origin,
						"arrival body not on override cell: %s" % body_d.grid_position)

	# --- in-flight guard: pipelined request right after commit ---------
	# Peer 7 just transitioned; an immediate second request must be
	# refused as busy and leave the peer on floor_b.
	_mm._handle_floor_transition(7, &"motel")
	_expect(_mm._peer_floor.get(7) == &"floor_b",
		"pipelined transition bypassed the in-flight guard")
	# A DIFFERENT peer is unaffected by peer 7's guard window.
	_mm._handle_portal_transition(8, portal_cell)
	# Peer 8 still isn't on the cell -> rejected; move B onto it first.
	_expect(_mm._peer_floor.get(8) == &"motel", "peer B floor changed unexpectedly")

	# Move B onto the portal cell and transition — peer isolation.
	# Resolve the room containing the portal world cell.
	var portal_room_id := Vector2i.ZERO
	for spec in motel_def.rooms:
		var origin: Vector2i = spec.global_origin
		var size: Vector2i = spec.size
		if portal_cell.x >= origin.x and portal_cell.x < origin.x + size.x \
				and portal_cell.y >= origin.y and portal_cell.y < origin.y + size.y:
			portal_room_id = spec.room_id
			break
	var portal_room := motel_world.get_room(portal_room_id)
	_expect(portal_room != null, "portal room not found in motel world")
	if portal_room != null:
		var local_cell := portal_cell - portal_room.cell_origin
		body_b.room = portal_room
		body_b.block_layer = portal_room.block_layer
		body_b.room_size = portal_room.size
		body_b.place_at(local_cell, body_b.stand_elevation_at(local_cell))
		_mm._handle_portal_transition(8, portal_cell)
		_expect(_mm._peer_floor.get(8) == &"floor_b",
			"second peer portal transition failed")
		_expect(body_b.room_world == dest_world,
			"body B not in floor_b world after portal transition")

	# --- in-flight guard lifecycle --------------------------------------
	# Both peers' transitions are still unresolved (no client ack in
	# this harness) -> every new request rejects "busy".
	_mm._handle_floor_transition(7, &"motel")
	_expect(_mm._peer_floor.get(7) == &"floor_b",
		"unresolved peer 7 transition was not guarded")
	_mm._handle_floor_transition(8, &"motel")
	_expect(_mm._peer_floor.get(8) == &"floor_b",
		"unresolved peer 8 transition was not guarded")
	# Ack release: _release_transition_guard is the id-matched path
	# _rpc_transition_done uses; a wrong id must NOT release.
	_mm._release_transition_guard(7, 999)
	_expect(_mm._transition_inflight.has(7), "wrong-id ack released the guard")
	_mm._release_transition_guard(7, 0)   # test transitions use id 0
	_expect(not _mm._transition_inflight.has(7), "ack did not release the guard")
	# Released -> the peer can transition again; commit re-acquires.
	_mm._handle_floor_transition(7, &"motel")
	_expect(_mm._peer_floor.get(7) == &"motel", "released guard still blocked peer 7")
	_expect(_mm._transition_inflight.has(7), "guard not re-acquired on commit")
	# Safety expiry: a stamp older than the timeout window frees the
	# peer even without an ack (lost-ack recovery).
	_mm._transition_inflight[7]["msec"] = Time.get_ticks_msec() \
		- MultiplayerManager.TRANSITION_INFLIGHT_TIMEOUT_MS - 1
	_mm._handle_floor_transition(7, &"floor_b")
	_expect(_mm._peer_floor.get(7) == &"floor_b", "expired guard still blocked peer 7")
	# Early validation rejection leaves no stale guard.
	var body_c: Player = _mm._spawn_body(10)
	_mm._peer_floor[10] = &"motel"
	_mm._handle_floor_transition(10, &"no_such_floor")
	_expect(not _mm._transition_inflight.has(10),
		"validation rejection left a stale guard")
	# Disconnect releases the guard and frees the body.
	_mm._handle_floor_transition(10, &"floor_c")
	_expect(_mm._transition_inflight.has(10), "commit did not acquire the guard")
	_mm._on_peer_disconnected(10)
	_expect(not _mm._transition_inflight.has(10), "disconnect did not release the guard")
	_expect(not _mm._bodies.has(10), "disconnect did not free the body")
	if body_c != null and is_instance_valid(body_c):
		body_c.queue_free()
	var snapshot := WorldSnapshot.build(fm, dest_world,
		fm.get_floor(&"floor_b"))
	var parsed: Variant = JSON.parse_string(JSON.stringify(snapshot))
	_expect(parsed is Dictionary, "destination snapshot JSON round-trip failed")
	if parsed is Dictionary:
		# The snapshot's own floor (floor_b) has no portals; build a
		# motel snapshot instead to verify portal delivery.
		var motel_snap := WorldSnapshot.build(fm, motel_world, motel_def)
		var motel_parsed: Variant = JSON.parse_string(JSON.stringify(motel_snap))
		_expect(motel_parsed is Dictionary, "motel snapshot JSON round-trip failed")
		if motel_parsed is Dictionary:
			var client_fm := FloorManager.new()
			client_fm.name = "ClientFloorManager"
			root.add_child(client_fm)
			var client_world := _make_replica_world()
			client_fm.room_world = client_world
			var client_motel := Floor.new()
			client_motel.floor_id = &"motel"
			client_motel.display_name = "Motel"
			client_motel.entry_room_id = Vector2i.ZERO
			var cm_spec := _spec(Vector2i.ZERO, Vector2i.ZERO, Vector2i(8, 8))
			client_motel.rooms.assign([cm_spec])
			client_fm.register_floor(client_motel)
			var client_player := _make_replica_player(client_world)
			var applied := WorldSnapshot.apply(client_fm, client_world,
				client_player, motel_parsed)
			_expect(applied, "motel snapshot apply failed on replica")
			var replica_motel := client_fm.get_floor(&"motel")
			_expect(replica_motel != null
				and replica_motel.portals.any(
					func(p): return p != null and p.world_cell == portal_cell),
				"portal definition did not reach the client replica")

	# --- client-side gating + timeout + snapshot lifecycle ------------
	# A WorldBootstrap stub gives the client mm the floor_manager/
	# room_world/player triple the snapshot epilogue needs.
	var snap_fm := FloorManager.new()
	snap_fm.name = "SnapFloorManager"
	root.add_child(snap_fm)
	var snap_world := _make_replica_world()
	snap_fm.room_world = snap_world
	var snap_motel := Floor.new()
	snap_motel.floor_id = &"motel"
	snap_motel.display_name = "Motel"
	snap_motel.entry_room_id = Vector2i.ZERO
	var sm_spec := _spec(Vector2i.ZERO, Vector2i.ZERO, Vector2i(8, 8))
	snap_motel.rooms.assign([sm_spec])
	snap_fm.register_floor(snap_motel)
	var snap_player := _make_replica_player(snap_world)
	var stub := WorldBootstrap.new()
	stub.floor_manager = snap_fm
	stub.room_world = snap_world
	stub.player = snap_player

	var client_mm := MultiplayerManager.new()
	client_mm.name = "ClientMM"
	client_mm.mode = MultiplayerManager.Mode.CLIENT
	client_mm.transition_timeout = 0.2
	client_mm._world = stub
	root.add_child(client_mm)
	_expect(not client_mm.request_portal_transition(portal_cell),
		"unconnected client portal request accepted")
	client_mm._connected = true
	client_mm.world_synced = true
	client_mm._my_floor_id = &"motel"
	var results: Array = []
	client_mm.transition_result.connect(
		func(a: bool, r: StringName): results.append([a, r]))
	_expect(client_mm.request_portal_transition(portal_cell),
		"connected client portal request refused")
	_expect(client_mm._transition_pending, "portal transition pending flag not set")
	_expect(not client_mm.request_portal_transition(portal_cell),
		"duplicate portal request accepted while pending")
	# Timeout watchdog: drive it directly with the live serial.
	var serial := client_mm._transition_request_serial
	client_mm._on_transition_timeout(serial)
	_expect(not client_mm._transition_pending, "timeout did not clear pending")
	_expect(results.any(func(e): return e[0] == false and e[1] == &"timeout"),
		"timeout did not emit transition_result(timeout)")
	# A stale serial must not clear a newer pending transition.
	client_mm._begin_client_transition()
	client_mm._on_transition_timeout(serial)
	_expect(client_mm._transition_pending,
		"stale timeout cleared a newer pending transition")
	client_mm._transition_pending = false
	if snap_player != null:
		snap_player.local_input_locked = false

	# --- travel snapshot lifecycle --------------------------------------
	# Feed _complete_travel_snapshot the same way _rpc_snapshot_end
	# does: WorldSnapshot.apply first, then the epilogue. transition_id
	# is the client request serial echoed by the server.
	var travel_snap := WorldSnapshot.build(fm, dest_world,
		fm.get_floor(&"floor_b"))
	_expect(not travel_snap.is_empty(), "travel snapshot build failed")

	# Normal completion: pending request + matching transition_id.
	client_mm.request_portal_transition(portal_cell)
	var s1 := client_mm._transition_request_serial
	var snap1: Dictionary = travel_snap.duplicate(true)
	snap1["transition_id"] = s1
	snap1["spawn"] = {"room_id": [0, 0], "cell": [1, 1], "elevation": 0.0}
	_expect(WorldSnapshot.apply(snap_fm, snap_world, snap_player, snap1),
		"travel snapshot apply failed")
	client_mm._my_floor_id = &"floor_b"
	var result_count := results.size()
	client_mm._complete_travel_snapshot(snap1)
	_expect(not client_mm._transition_pending,
		"matching snapshot did not complete the transition")
	_expect(not snap_player.local_input_locked,
		"matching snapshot left input locked")
	_expect(results.size() == result_count + 1
		and results[-1][0] == true and results[-1][1] == &"",
		"matching snapshot did not emit transition_result(true)")

	# Timeout, then the late snapshot: world applies, but no success
	# is reported for the expired request.
	client_mm.request_portal_transition(portal_cell)
	var s2 := client_mm._transition_request_serial
	client_mm._on_transition_timeout(s2)
	_expect(not client_mm._transition_pending, "second timeout did not clear pending")
	var snap2: Dictionary = travel_snap.duplicate(true)
	snap2["transition_id"] = s2
	snap2["spawn"] = {"room_id": [0, 0], "cell": [1, 1], "elevation": 0.0}
	_expect(WorldSnapshot.apply(snap_fm, snap_world, snap_player, snap2),
		"late snapshot apply failed")
	result_count = results.size()
	client_mm._complete_travel_snapshot(snap2)
	_expect(results.size() == result_count,
		"late snapshot emitted a transition result")
	_expect(not client_mm._transition_pending,
		"late snapshot re-pended the client")

	# Stale snapshot while a NEWER transition is pending: applies the
	# world but must not complete, unlock, or report for the new one.
	client_mm.request_portal_transition(portal_cell)
	var s3 := client_mm._transition_request_serial
	_expect(s3 > s2, "request serial did not advance")
	var snap_stale: Dictionary = travel_snap.duplicate(true)
	snap_stale["transition_id"] = s2   # older request's snapshot
	snap_stale["spawn"] = {"room_id": [0, 0], "cell": [1, 1], "elevation": 0.0}
	_expect(WorldSnapshot.apply(snap_fm, snap_world, snap_player, snap_stale),
		"stale snapshot apply failed")
	result_count = results.size()
	client_mm._complete_travel_snapshot(snap_stale)
	_expect(client_mm._transition_pending,
		"stale snapshot cleared the newer pending transition")
	_expect(snap_player.local_input_locked,
		"stale snapshot unlocked input during pending transition")
	_expect(results.size() == result_count,
		"stale snapshot emitted a transition result")
	# The matching snapshot then completes normally.
	var snap3: Dictionary = travel_snap.duplicate(true)
	snap3["transition_id"] = s3
	snap3["spawn"] = {"room_id": [0, 0], "cell": [1, 1], "elevation": 0.0}
	_expect(WorldSnapshot.apply(snap_fm, snap_world, snap_player, snap3),
		"final snapshot apply failed")
	client_mm._complete_travel_snapshot(snap3)
	_expect(not client_mm._transition_pending,
		"final matching snapshot did not complete the transition")
	_expect(results.size() == result_count + 1
		and results[-1][0] == true,
		"final matching snapshot did not emit success")
	_expect(client_mm._my_floor_id == &"floor_b",
		"final client floor does not match authoritative state")
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
		print("PORTAL_TRANSITION_SMOKE: OK")
	else:
		print("PORTAL_TRANSITION_SMOKE: FAILED (%d)" % _failures.size())
		for failure in _failures:
			print("  FAIL: %s" % failure)
