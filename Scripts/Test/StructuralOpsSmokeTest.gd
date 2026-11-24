extends SceneTree

## Smoke test for Phase C3 authoritative room structural ops. Boots a
## real WorldBootstrap headless, stands up a SERVER-mode
## MultiplayerManager, simulates client bodies on two floors, and
## drives _handle_struct_op directly (RPC sends fail harmlessly
## without an ENet peer — the server-side state changes are what is
## asserted). Covers: create/delete/visibility success, duplicate ids,
## invalid specs, contents/occupancy/last-room/connectivity delete
## refusals, wrong-floor requests, op-id replay, conflicting creates,
## identical room ids on separate floors, client replica apply without
## persistence, transition gating, and broadcast queue filtering.

const BOOTSTRAP_SCENE := "res://Scenes/World/WorldBootstrap.tscn"
const GRID_PATH := "res://Resources/IsometricGrid/TestGrid.tres"
const TILE_CATALOG_PATH := "res://Resources/TileCatalog.tres"
const BLOCK_CATALOG_PATH := "res://Resources/BlockCatalog.tres"
const FURNITURE_CATALOG_PATH := "res://Resources/FurnitureCatalog.tres"
const CARPET_CATALOG_PATH := "res://Resources/CarpetCatalog.tres"
const BLOCK_SCENE_PATH := "res://Scenes/Objects/Block.tscn"
const PLAYER_SCENE_PATH := "res://Scenes/Player/Player.tscn"
const SCRATCH_ROOT := "user://smoke_struct_ops"

var _world: WorldBootstrap
var _mm: MultiplayerManager
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

func _spec(room_id: Vector2i, origin: Vector2i, size: Vector2i) -> FloorRoomSpec:
	var spec := FloorRoomSpec.new()
	spec.room_id = room_id
	spec.global_origin = origin
	spec.size = size
	return spec

func _entry(spec: FloorRoomSpec) -> Dictionary:
	return FloorSaveSystem.spec_to_layout_entry(spec)

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

## Drives one structural op through the server handler. Returns the
## op_id used (for dedup assertions callers pass explicit ids via
## _struct_op_id instead).
func _struct(peer_id: int, op: Dictionary) -> int:
	_op_serial += 1
	_mm._handle_struct_op(peer_id, _op_serial, op)
	return _op_serial

func _struct_with_id(peer_id: int, op_id: int, op: Dictionary) -> void:
	_mm._handle_struct_op(peer_id, op_id, op)

func _layout_room_ids(floor_id: StringName) -> Array:
	var ids: Array = []
	for entry in FloorSaveSystem.load_layout(floor_id).get("rooms", []):
		var rid: Variant = entry.get("room_id")
		if rid is Array and rid.size() == 2:
			ids.append(Vector2i(int(rid[0]), int(rid[1])))
	return ids

func _run_checks() -> void:
	_expect(_world != null and _world.floor_manager != null
		and _world.floor_manager.active_floor != null
		and _world.floor_manager.active_floor.floor_id == &"motel",
		"motel floor did not boot")
	if _world == null or _world.floor_manager == null:
		return
	var fm := _world.floor_manager

	# floor_b: 2x2 cluster — deletable rooms with redundant neighbors.
	var specs_b: Array[FloorRoomSpec] = [
		_spec(Vector2i(0, 0), Vector2i(0, 0), Vector2i(8, 8)),
		_spec(Vector2i(1, 0), Vector2i(8, 0), Vector2i(8, 8)),
		_spec(Vector2i(0, 1), Vector2i(0, 8), Vector2i(8, 8)),
		_spec(Vector2i(1, 1), Vector2i(8, 8), Vector2i(8, 8)),
	]
	var floor_b := fm.create_floor(&"floor_b", "Floor B", specs_b)
	_expect(floor_b != null, "create_floor floor_b failed")
	# floor_line: three rooms in a row — deleting the middle isolates.
	var specs_line: Array[FloorRoomSpec] = [
		_spec(Vector2i(0, 0), Vector2i(0, 0), Vector2i(8, 8)),
		_spec(Vector2i(1, 0), Vector2i(8, 0), Vector2i(8, 8)),
		_spec(Vector2i(2, 0), Vector2i(16, 0), Vector2i(8, 8)),
	]
	var floor_line := fm.create_floor(&"floor_line", "Floor Line", specs_line)
	_expect(floor_line != null, "create_floor floor_line failed")
	# floor_last: a single room — nothing may be deleted.
	var specs_last: Array[FloorRoomSpec] = [
		_spec(Vector2i(0, 0), Vector2i(0, 0), Vector2i(8, 8)),
	]
	var floor_last := fm.create_floor(&"floor_last", "Floor Last", specs_last)
	_expect(floor_last != null, "create_floor floor_last failed")
	if floor_b == null or floor_line == null or floor_last == null:
		return

	_make_server()
	var body_a: Player = _mm._spawn_body(7)
	var body_b: Player = _mm._spawn_body(8)
	var body_c: Player = _mm._spawn_body(9)
	_expect(body_a != null and body_b != null and body_c != null,
		"server bodies failed to spawn")
	if body_a == null or body_b == null or body_c == null:
		return
	_mm._peer_floor[7] = &"motel"
	_mm._peer_floor[8] = &"motel"
	_mm._peer_floor[9] = &"motel"

	# Peer 8 and 9 travel to floor_b — materializes its runtime world.
	_mm._handle_floor_transition(8, &"floor_b")
	_mm._handle_floor_transition(9, &"floor_b")
	var world_b: RoomWorld = fm.world_for_floor(&"floor_b")
	_expect(world_b != null and world_b.get_rooms().size() == 4,
		"floor_b runtime world not materialized")
	if world_b == null:
		return
	var motel_world := _world.room_world

	# --- replica apply: snapshot -> client replica -> replica_* ops ----
	var snapshot := WorldSnapshot.build(fm, world_b, floor_b)
	var parsed: Variant = JSON.parse_string(JSON.stringify(snapshot))
	_expect(parsed is Dictionary, "floor_b snapshot round-trip failed")
	if parsed is Dictionary:
		var client_fm := FloorManager.new()
		client_fm.name = "ClientFM"
		root.add_child(client_fm)
		var client_world := _make_replica_world()
		client_fm.room_world = client_world
		var client_player := _make_replica_player(client_world)
		_expect(WorldSnapshot.apply(client_fm, client_world, client_player, parsed),
			"floor_b snapshot apply failed on replica")
		var client_def := client_fm.get_floor(&"floor_b")
		_expect(client_def != null, "floor_b not registered on replica")
		if client_def != null:
			# Create: room (2,0) at (16,0) shares an edge with (1,0).
			var new_spec := _spec(Vector2i(2, 0), Vector2i(16, 0), Vector2i(8, 8))
			_expect(client_fm.replica_add_room(&"floor_b", _entry(new_spec)) != null,
				"replica_add_room failed")
			_expect(client_world.get_room(Vector2i(2, 0)) != null
				and client_def.find_room_spec(Vector2i(2, 0)) != null,
				"replica create missing room or spec")
			# Replica ops must never persist: layout.json stays without it.
			_expect(not _layout_room_ids(&"floor_b").has(Vector2i(2, 0)),
				"replica_add_room persisted layout.json")
			# Visibility flags apply to room + spec, still no persist.
			_expect(client_fm.replica_set_room_visibility(&"floor_b",
					Vector2i(0, 0), false, true),
				"replica_set_room_visibility failed")
			var flags_room := client_world.get_room(Vector2i(0, 0))
			var flags_spec := client_def.find_room_spec(Vector2i(0, 0))
			_expect(flags_room != null and flags_spec != null
				and not flags_room.show_from_outside
				and flags_spec.show_outside,
				"replica visibility flags not applied")
			# Delete removes room + spec, connections pruned, no persist.
			_expect(client_fm.replica_remove_room(&"floor_b", Vector2i(2, 0)),
				"replica_remove_room failed")
			_expect(client_world.get_room(Vector2i(2, 0)) == null
				and client_def.find_room_spec(Vector2i(2, 0)) == null,
				"replica delete left room or spec")
			_expect(not _layout_room_ids(&"floor_b").has(Vector2i(2, 0)),
				"replica ops wrote layout.json")
		client_fm.queue_free()
		client_world.queue_free()

	# --- server create on floor_b (runtime world, peer 8) --------------
	var create_b := {"op": "create", "floor_id": &"floor_b",
		"spec": _entry(_spec(Vector2i(2, 0), Vector2i(16, 0), Vector2i(8, 8)))}
	_struct(8, create_b)
	_expect(world_b.get_room(Vector2i(2, 0)) != null
		and floor_b.find_room_spec(Vector2i(2, 0)) != null,
		"server create on floor_b failed")
	_expect(_layout_room_ids(&"floor_b").has(Vector2i(2, 0)),
		"server create did not persist layout.json")
	# Same room id again -> rejected.
	_struct(8, {"op": "create", "floor_id": &"floor_b",
		"spec": _entry(_spec(Vector2i(2, 0), Vector2i(16, 0), Vector2i(8, 8)))})
	_expect(world_b.get_rooms().size() == 5, "duplicate create applied")
	# Invalid spec: below minimum size.
	_struct(8, {"op": "create", "floor_id": &"floor_b",
		"spec": _entry(_spec(Vector2i(7, 7), Vector2i(40, 0), Vector2i(1, 1)))})
	_expect(world_b.get_rooms().size() == 5, "undersized spec applied")
	# Invalid spec: overlaps an existing room.
	_struct(8, {"op": "create", "floor_id": &"floor_b",
		"spec": _entry(_spec(Vector2i(9, 9), Vector2i(0, 0), Vector2i(8, 8)))})
	_expect(world_b.get_rooms().size() == 5, "overlapping spec applied")
	# Invalid spec: no shared edge (orphan).
	_struct(8, {"op": "create", "floor_id": &"floor_b",
		"spec": _entry(_spec(Vector2i(9, 9), Vector2i(200, 200), Vector2i(8, 8)))})
	_expect(world_b.get_rooms().size() == 5, "orphan spec applied")
	# Malformed spec payload.
	_struct(8, {"op": "create", "floor_id": &"floor_b", "spec": "junk"})
	_expect(world_b.get_rooms().size() == 5, "malformed spec applied")

	# --- visibility on floor_b -----------------------------------------
	_struct(8, {"op": "visibility", "floor_id": &"floor_b",
		"room_id": Vector2i(2, 0), "show_from_outside": false,
		"show_outside": false})
	var vis_room := world_b.get_room(Vector2i(2, 0))
	var vis_spec := floor_b.find_room_spec(Vector2i(2, 0))
	_expect(vis_room != null and vis_spec != null
		and not vis_room.show_from_outside and not vis_room.show_outside
		and not vis_spec.show_from_outside and not vis_spec.show_outside,
		"visibility op did not update room+spec")
	var layout_data := FloorSaveSystem.load_layout(&"floor_b")
	var persisted_flags := false
	for entry in layout_data.get("rooms", []):
		var rid: Variant = entry.get("room_id")
		if rid is Array and rid.size() == 2 \
				and int(rid[0]) == 2 and int(rid[1]) == 0:
			persisted_flags = entry.get("show_from_outside") == false \
				and entry.get("show_outside") == false
	_expect(persisted_flags, "visibility flags not persisted to layout.json")
	# Unknown room -> rejected.
	_struct(8, {"op": "visibility", "floor_id": &"floor_b",
		"room_id": Vector2i(50, 50)})

	# --- delete refusals on floor_b -------------------------------------
	# Contents: drop a block into room (1,0), then delete must refuse.
	var room_10 := world_b.get_room(Vector2i(1, 0))
	_expect(room_10 != null, "floor_b room (1,0) missing")
	if room_10 != null:
		var placed: Variant = BuildOps.apply_place_any(world_b, room_10,
			&"block", Vector2i(1, 1), &"standard_block", 0.0, 0, false)
		_expect(placed != null, "test block placement failed")
	_struct(8, {"op": "delete", "floor_id": &"floor_b", "room_id": Vector2i(1, 0)})
	_expect(world_b.get_room(Vector2i(1, 0)) != null,
		"delete applied to room with contents")
	# Occupancy: park peer 8's body inside room (1,1), delete must refuse.
	var room_11 := world_b.get_room(Vector2i(1, 1))
	if room_11 != null:
		body_b.room = room_11
		body_b.room_size = room_11.size
		body_b.block_layer = room_11.block_layer
		body_b.grid_position = Vector2i(1, 1)
	_struct(8, {"op": "delete", "floor_id": &"floor_b", "room_id": Vector2i(1, 1)})
	_expect(world_b.get_room(Vector2i(1, 1)) != null,
		"delete applied to occupied room")
	# Move the body out -> delete succeeds.
	var room_00 := world_b.get_room(Vector2i(0, 0))
	if room_00 != null and room_11 != null:
		body_b.room = room_00
		body_b.block_layer = room_00.block_layer
		body_b.grid_position = Vector2i(1, 1)
	_struct(8, {"op": "delete", "floor_id": &"floor_b", "room_id": Vector2i(1, 1)})
	_expect(world_b.get_room(Vector2i(1, 1)) == null
		and floor_b.find_room_spec(Vector2i(1, 1)) == null,
		"valid delete on floor_b failed")
	_expect(not _layout_room_ids(&"floor_b").has(Vector2i(1, 1)),
		"delete not persisted to layout.json")
	# Deleting it again -> refused (no longer instantiated).
	_struct(8, {"op": "delete", "floor_id": &"floor_b", "room_id": Vector2i(1, 1)})

	# --- wrong floor / replay / malformed --------------------------------
	# Peer 7 sits on motel; a floor_b op must be rejected.
	_struct(7, {"op": "delete", "floor_id": &"floor_b", "room_id": Vector2i(0, 0)})
	_expect(world_b.get_room(Vector2i(0, 0)) != null,
		"wrong-floor delete applied on floor_b")
	# Unknown floor entirely.
	_struct(7, {"op": "delete", "floor_id": &"floor_line", "room_id": Vector2i(0, 0)})
	# Op-id replay: reuse peer 8's last op id.
	var replay_id := _op_serial
	_struct_with_id(8, replay_id, {"op": "visibility", "floor_id": &"floor_b",
		"room_id": Vector2i(2, 0)})
	# Peer with no body at all.
	_struct(77, {"op": "delete", "floor_id": &"floor_b", "room_id": Vector2i(2, 0)})
	_expect(world_b.get_room(Vector2i(2, 0)) != null,
		"ghost-peer delete applied")

	# --- identical room ids on separate floors ---------------------------
	# Peer 9 creates (3,0) on floor_b; peer 8 tries the same id — the
	# second must fail even though motel may reuse ids freely.
	_struct(9, {"op": "create", "floor_id": &"floor_b",
		"spec": _entry(_spec(Vector2i(3, 0), Vector2i(24, 0), Vector2i(8, 8)))})
	_expect(world_b.get_room(Vector2i(3, 0)) != null,
		"peer 9 create on floor_b failed")
	_struct(8, {"op": "create", "floor_id": &"floor_b",
		"spec": _entry(_spec(Vector2i(3, 0), Vector2i(24, 0), Vector2i(8, 8)))})
	_expect(world_b.get_rooms().size() == 5,
		"conflicting create applied twice")

	# --- motel (bound world) ops via peer 7 -------------------------------
	# Visibility on an existing motel room exercises the bound-world
	# path (world_for_floor -> room_world).
	_struct(7, {"op": "visibility", "floor_id": &"motel",
		"room_id": Vector2i.ZERO,
		"show_from_outside": false, "show_outside": false})
	var motel_room := motel_world.get_room(Vector2i.ZERO)
	var motel_spec := fm.active_floor.find_room_spec(Vector2i.ZERO)
	_expect(motel_room != null and motel_spec != null
		and not motel_room.show_from_outside,
		"visibility op on bound world failed")
	# The motel entry room holds contents (and the server's avatar) —
	# deleting it must refuse.
	_struct(7, {"op": "delete", "floor_id": &"motel", "room_id": Vector2i.ZERO})
	_expect(motel_world.get_room(Vector2i.ZERO) != null,
		"delete applied to occupied/contents motel room")
	# Restore the flags for cleanliness.
	_struct(7, {"op": "visibility", "floor_id": &"motel",
		"room_id": Vector2i.ZERO,
		"show_from_outside": true, "show_outside": true})

	# --- FloorManager-level edge cases on never-visited floors -----------
	var line_world := _world.create_floor_world(&"floor_line")
	_expect(line_world != null
		and fm.materialize_runtime_floor(&"floor_line", line_world),
		"floor_line materialization failed")
	if line_world != null:
		# Middle room of a 3-line: deletion would isolate a neighbor.
		var line_verdict := fm.can_delete_room_on_floor(&"floor_line",
			Vector2i(1, 0), {})
		_expect(not bool(line_verdict.get("allowed", false)),
			"connectivity-breaking delete allowed on floor_line")
		var last_world := _world.create_floor_world(&"floor_last")
		if last_world != null \
				and fm.materialize_runtime_floor(&"floor_last", last_world):
			var last_verdict := fm.can_delete_room_on_floor(&"floor_last",
				Vector2i.ZERO, {})
			_expect(not bool(last_verdict.get("allowed", false)),
				"last-room delete allowed on floor_last")
			last_world.queue_free()
		line_world.queue_free()

	# --- client gating + broadcast queue -------------------------------
	var client_mm := MultiplayerManager.new()
	client_mm.name = "ClientMM"
	client_mm.mode = MultiplayerManager.Mode.CLIENT
	root.add_child(client_mm)
	_expect(not client_mm.request_struct_delete(Vector2i(0, 0)),
		"unconnected client struct request accepted")
	client_mm._connected = true
	client_mm.world_synced = true
	client_mm._my_floor_id = &"floor_b"
	_expect(client_mm.request_struct_delete(Vector2i(0, 0)),
		"connected client struct delete refused")
	client_mm._transition_pending = true
	_expect(not client_mm.can_request_struct(),
		"struct request allowed during pending transition")
	_expect(not client_mm.request_struct_delete(Vector2i(0, 0)),
		"struct request sent during pending transition")
	client_mm._transition_pending = false
	# Accepted broadcast while unsynced queues instead of applying.
	client_mm.world_synced = false
	client_mm._handle_struct_result(500, true, &"", {
		"op": "delete", "floor_id": &"floor_b", "room_id": Vector2i(9, 9)})
	_expect(client_mm._pending_struct_ops.size() == 1,
		"pre-sync struct broadcast not queued")
	# After sync on a DIFFERENT floor the queued op is dropped.
	client_mm.world_synced = true
	client_mm._my_floor_id = &"motel"
	client_mm._world = _world
	client_mm._flush_pending_struct_ops()
	_expect(client_mm._pending_struct_ops.is_empty(),
		"queued struct op not flushed")
	_expect(motel_world.get_room(Vector2i(9, 9)) == null,
		"other-floor struct op applied locally")
	client_mm.queue_free()

	# --- world equivalence ----------------------------------------------
	var b_ids: Array = []
	for r in world_b.registry.get_rooms():
		b_ids.append(r.room_coordinates)
	var spec_ids: Array = []
	for s in floor_b.rooms:
		if s != null:
			spec_ids.append(s.room_id)
	spec_ids.sort()
	b_ids.sort()
	_expect(b_ids == spec_ids,
		"floor_b world/spec room ids diverged: %s vs %s" % [b_ids, spec_ids])

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
		print("STRUCTURAL_OPS_SMOKE: OK")
	else:
		print("STRUCTURAL_OPS_SMOKE: FAILED (%d)" % _failures.size())
		for failure in _failures:
			print("  FAIL: %s" % failure)
