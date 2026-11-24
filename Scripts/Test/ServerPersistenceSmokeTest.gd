extends SceneTree

## Smoke test for Phase D authoritative server persistence. Covers:
## floor-scoped dirty tracking (content changes, struct ops, visibility,
## floor create/delete), hydration/rejected/replica paths NOT marking
## dirty, per-floor save_floor_state isolation, save_all_dirty,
## failed-save dirty retention, restart reload through a fresh
## FloorManager, and the MultiplayerManager autosave/shutdown-save
## wrappers including _shutting_down op rejection.

const GRID_PATH := "res://Resources/IsometricGrid/TestGrid.tres"
const TILE_CATALOG_PATH := "res://Resources/TileCatalog.tres"
const BLOCK_CATALOG_PATH := "res://Resources/BlockCatalog.tres"
const FURNITURE_CATALOG_PATH := "res://Resources/FurnitureCatalog.tres"
const CARPET_CATALOG_PATH := "res://Resources/CarpetCatalog.tres"
const BLOCK_SCENE_PATH := "res://Scenes/Objects/Block.tscn"
const PLAYER_SCENE_PATH := "res://Scenes/Player/Player.tscn"
const BOOTSTRAP_SCENE := "res://Scenes/World/WorldBootstrap.tscn"
const SCRATCH_ROOT := "user://smoke_server_persist"
const BLOCKER_PATH := "user://smoke_persist_blocker"

var _floor_manager: FloorManager
var _room_world: RoomWorld
var _world_b: RoomWorld
var _net_world: WorldBootstrap
var _frames := 0
var _failures: Array[String] = []

func _initialize() -> void:
	FloorSaveSystem.save_root = SCRATCH_ROOT
	_remove_dir_contents(SCRATCH_ROOT)
	# A plain FILE where a directory is expected makes every floor
	# save fail — used to prove dirty state survives failed saves.
	var blocker := FileAccess.open(BLOCKER_PATH, FileAccess.WRITE)
	if blocker != null:
		blocker.store_string("not a directory")
		blocker.close()
	_floor_manager = FloorManager.new()
	_floor_manager.name = "FloorManager"
	root.add_child(_floor_manager)
	_room_world = _make_room_world("BoundWorld")
	_floor_manager.room_world = _room_world
	_world_b = _make_room_world("RuntimeWorldB")

func _setup() -> void:
	# pd_a: two rooms on the bound world. pd_b: one room on a runtime
	# world — the multiplayer secondary-floor shape.
	_floor_manager.register_floor(_floor(&"pd_a", [
		_spec(Vector2i(0, 0), Vector2i(0, 0), Vector2i(8, 8)),
		_spec(Vector2i(1, 0), Vector2i(8, 0), Vector2i(8, 8)),
	], Vector2i(0, 0), Vector2i(1, 1)))
	_floor_manager.register_floor(_floor(&"pd_b", [
		_spec(Vector2i(0, 0), Vector2i(0, 0), Vector2i(8, 8)),
	], Vector2i(0, 0), Vector2i(1, 1)))
	_expect(_floor_manager.activate_floor(&"pd_a"), "activate pd_a failed")
	_expect(_floor_manager.materialize_runtime_floor(&"pd_b", _world_b),
		"materialize pd_b runtime world failed")

func _process(_delta: float) -> bool:
	_frames += 1
	if _frames == 1:
		_setup()
	if _frames == 6:
		_run_checks()
	# The net world boots inside _run_checks; give _ready a few frames
	# before exercising the autosave/shutdown wrappers.
	if _frames == 12:
		_run_net_checks()
		_report()
		quit()
		return true
	return false

func _make_room_world(world_name: String) -> RoomWorld:
	var world := RoomWorld.new()
	world.name = world_name
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

func _spec(room_id: Vector2i, origin: Vector2i, size: Vector2i) -> FloorRoomSpec:
	var spec := FloorRoomSpec.new()
	spec.room_id = room_id
	spec.global_origin = origin
	spec.size = size
	return spec

func _floor(id: StringName, rooms: Array, entry: Vector2i, spawn: Vector2i) -> Floor:
	var floor_def := Floor.new()
	floor_def.floor_id = id
	floor_def.display_name = String(id)
	floor_def.entry_room_id = entry
	floor_def.spawn_position = spawn
	floor_def.auto_connect_adjacent = false
	floor_def.rooms.assign(rooms)
	return floor_def

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

func _dirty() -> Array:
	return _floor_manager.dirty_floor_ids()

func _has_dirty(id: StringName) -> bool:
	return _dirty().has(id)

func _place_block(world: RoomWorld, room_id: Vector2i, cell: Vector2i) -> void:
	var room := world.get_room(room_id)
	var def: BlockDefinition = world.block_catalog.get_definition(&"standard_block")
	if room == null or room.block_layer == null or def == null:
		_failures.append("cannot place test block in %s" % room_id)
		return
	room.block_layer.place_block(def, cell, 0.0)

func _manifest_exists(id: StringName) -> bool:
	return FileAccess.file_exists(FloorSaveSystem.manifest_path(id))

func _run_checks() -> void:
	var fm := _floor_manager
	_expect(fm.active_floor != null and fm.active_floor.floor_id == &"pd_a",
		"pd_a not active")

	# --- hydration/activation does not leave floors dirty --------------
	# activate_floor + materialize_runtime_floor both ran during setup;
	# a clean save of pd_a then proves activation alone doesn't dirty
	# the OTHER floor, and materialization didn't dirty pd_b.
	_expect(_has_dirty(&"pd_a"), "activate_floor did not mark pd_a dirty")
	_expect(not _has_dirty(&"pd_b"),
		"materialize_runtime_floor hydration marked pd_b dirty")
	_expect(fm.save_floor_state(&"pd_a"), "save_floor_state(pd_a) failed")
	_expect(_dirty().is_empty(), "dirty floors remain after save: %s" % [_dirty()])

	# --- content change marks only its own floor ------------------------
	_place_block(_room_world, Vector2i(0, 0), Vector2i(2, 2))
	_expect(_dirty() == [&"pd_a"], "block on pd_a marked wrong floors: %s" % [_dirty()])
	_place_block(_world_b, Vector2i(0, 0), Vector2i(3, 3))
	_expect(_dirty().has(&"pd_a") and _dirty().has(&"pd_b")
		and _dirty().size() == 2,
		"block on pd_b runtime world not attributed: %s" % [_dirty()])

	# --- struct ops mark the target floor -------------------------------
	fm.save_all_dirty()
	_expect(_dirty().is_empty(), "dirty floors remain before struct ops")
	var new_spec := _spec(Vector2i(1, 0), Vector2i(8, 0), Vector2i(4, 4))
	var added := fm.add_room_to_floor(&"pd_b", new_spec)
	_expect(added != null, "add_room_to_floor(pd_b) failed")
	_expect(_dirty() == [&"pd_b"],
		"room create on pd_b marked wrong floors: %s" % [_dirty()])
	# Rejected ops must not mark anything: duplicate room id on pd_a.
	fm.save_all_dirty()
	var dup := _spec(Vector2i(0, 0), Vector2i(20, 0), Vector2i(4, 4))
	_expect(fm.add_room_to_floor(&"pd_a", dup) == null,
		"duplicate room id was accepted")
	_expect(_dirty().is_empty(), "rejected room create marked floors dirty")
	# Visibility change marks its floor.
	_expect(fm.set_room_visibility_on_floor(&"pd_b", Vector2i(0, 0),
		false, true), "set_room_visibility_on_floor failed")
	_expect(_dirty() == [&"pd_b"],
		"visibility change marked wrong floors: %s" % [_dirty()])

	# --- per-floor save isolation ---------------------------------------
	_place_block(_room_world, Vector2i(0, 0), Vector2i(4, 4))
	_expect(_dirty().has(&"pd_a") and _dirty().has(&"pd_b"),
		"expected both floors dirty before isolation save")
	var pd_b_manifest := FloorSaveSystem.manifest_path(&"pd_b")
	var pd_b_mtime := FileAccess.get_modified_time(pd_b_manifest)
	_expect(fm.save_floor_state(&"pd_a"), "isolation save pd_a failed")
	_expect(not _has_dirty(&"pd_a") and _has_dirty(&"pd_b"),
		"save_floor_state cleared the wrong floor's dirty flag")
	# pd_b was NOT saved: its manifest mtime must be untouched.
	_expect(FileAccess.get_modified_time(pd_b_manifest) == pd_b_mtime,
		"pd_b manifest rewritten by pd_a's save — floors not isolated")
	var result := fm.save_all_dirty()
	_expect((result["saved"] as Array) == [&"pd_b"]
		and (result["failed"] as Array).is_empty(),
		"save_all_dirty result wrong: %s" % [result])
	_expect(_dirty().is_empty(), "dirty floors remain after save_all_dirty")
	_expect(_manifest_exists(&"pd_a") and _manifest_exists(&"pd_b"),
		"manifest missing after save_all_dirty")
	# save_floor_state writes room contents + connections but never
	# player_state.json — bodies are transient session state.
	_expect(not FileAccess.file_exists(
		FloorSaveSystem.floor_dir(&"pd_a").path_join("player_state.json")),
		"save_floor_state wrote player_state.json")

	# --- failed save keeps the floor dirty ------------------------------
	_place_block(_world_b, Vector2i(0, 0), Vector2i(5, 5))
	_expect(_dirty() == [&"pd_b"], "pd_b not dirty before failure test")
	var saved_root := FloorSaveSystem.save_root
	FloorSaveSystem.save_root = BLOCKER_PATH
	var failed_result := fm.save_all_dirty()
	FloorSaveSystem.save_root = saved_root
	_expect((failed_result["failed"] as Array) == [&"pd_b"],
		"save under blocker root did not report failure: %s" % [failed_result])
	_expect(_has_dirty(&"pd_b"), "failed save cleared pd_b's dirty flag")
	# Recovery: restore the root and the next autosave-equivalent succeeds.
	_expect(fm.save_all_dirty()["saved"] == [&"pd_b"],
		"pd_b still failing after root restore")
	_expect(_dirty().is_empty(), "pd_b still dirty after recovery save")

	# --- restart: fresh manager + worlds reload persisted state ---------
	var fm2 := FloorManager.new()
	fm2.name = "RestartFM"
	root.add_child(fm2)
	var world_a2 := _make_room_world("RestartWorldA")
	var world_b2 := _make_room_world("RestartWorldB")
	fm2.room_world = world_a2
	fm2.register_floor(_floor(&"pd_a", [
		_spec(Vector2i(0, 0), Vector2i(0, 0), Vector2i(8, 8)),
		_spec(Vector2i(1, 0), Vector2i(8, 0), Vector2i(8, 8)),
	], Vector2i(0, 0), Vector2i(1, 1)))
	fm2.register_floor(_floor(&"pd_b", [
		_spec(Vector2i(0, 0), Vector2i(0, 0), Vector2i(8, 8)),
		_spec(Vector2i(1, 0), Vector2i(8, 0), Vector2i(4, 4)),
	], Vector2i(0, 0), Vector2i(1, 1)))
	_expect(fm2.load_floor(&"pd_a"), "restart load_floor(pd_a) failed")
	var room_a := world_a2.get_room(Vector2i(0, 0))
	_expect(room_a != null and room_a.block_layer != null
		and room_a.block_layer.blocks.size() == 2,
		"pd_a blocks not restored after restart (blocks=%d)" % [
			room_a.block_layer.blocks.size() if room_a != null and room_a.block_layer != null else -1])
	_expect(fm2.materialize_runtime_floor(&"pd_b", world_b2),
		"restart materialize pd_b failed")
	var room_b := world_b2.get_room(Vector2i(0, 0))
	_expect(room_b != null and room_b.block_layer != null
		and room_b.block_layer.blocks.size() == 2,
		"pd_b blocks not restored after restart")
	var room_b2 := world_b2.get_room(Vector2i(1, 0))
	_expect(room_b2 != null, "pd_b created room (1,0) not restored after restart")
	_expect(fm2.dirty_floor_ids().is_empty(),
		"restart hydration left floors dirty: %s" % [fm2.dirty_floor_ids()])
	fm2.queue_free()
	world_a2.queue_free()
	world_b2.queue_free()

	# --- replica applies never mark dirty --------------------------------
	# Materialize pd_r BEFORE any client-mode manager enters the
	# "multiplayer_manager" group: is_client is tree-global, so a CLIENT
	# node would make register_floor refuse as readonly. Real clients
	# register replicas through the unguarded path instead.
	var cfm := FloorManager.new()
	cfm.name = "ReplicaFM"
	root.add_child(cfm)
	var cworld := _make_room_world("ReplicaWorld")
	cfm.room_world = cworld
	cfm.register_floor(_floor(&"pd_r", [
		_spec(Vector2i(0, 0), Vector2i(0, 0), Vector2i(8, 8)),
	], Vector2i(0, 0), Vector2i(1, 1)))
	_expect(cfm.load_floor_without_save(&"pd_r"),
		"replica floor pd_r failed to materialize")
	var replica_mm := MultiplayerManager.new()
	replica_mm.mode = MultiplayerManager.Mode.CLIENT
	replica_mm.add_to_group(&"multiplayer_manager")
	root.add_child(replica_mm)
	_expect(cfm.structural_edits_readonly(), "replica manager not readonly")
	var entry := FloorSaveSystem.spec_to_layout_entry(
		_spec(Vector2i(1, 0), Vector2i(8, 0), Vector2i(4, 4)))
	_expect(cfm.replica_add_room(&"pd_r", entry) != null,
		"replica_add_room failed")
	_expect(cfm.replica_set_room_visibility(&"pd_r", Vector2i(0, 0),
		false, false), "replica_set_room_visibility failed")
	_expect(cfm.dirty_floor_ids().is_empty(),
		"replica apply marked floors dirty: %s" % [cfm.dirty_floor_ids()])
	# Replica nodes are freed IMMEDIATELY (not queue_free): a CLIENT-mode
	# manager left in the "multiplayer_manager" group would make every
	# FloorManager readonly via the tree-global is_client check while
	# the net world below boots.
	_free_now(replica_mm)
	_free_now(cfm)
	_free_now(cworld)

	# --- autosave + shutdown save via a real server manager --------------
	# Boot a real WorldBootstrap; its _ready runs on add_child but the
	# floor materialization is heavy — _run_net_checks runs a few frames
	# later.
	var scene := load(BOOTSTRAP_SCENE) as PackedScene
	_net_world = scene.instantiate() as WorldBootstrap
	_net_world.startup_floor_id = &"motel"
	root.add_child(_net_world)

func _run_net_checks() -> void:
	var net_world := _net_world
	var nfm: FloorManager = net_world.floor_manager if net_world != null else null
	_expect(nfm != null and nfm.active_floor != null,
		"net world floor manager did not boot")
	if nfm == null or net_world.room_world == null:
		return
	var mm := MultiplayerManager.new()
	mm.name = "NetMM"
	mm.mode = MultiplayerManager.Mode.SERVER
	mm._world = net_world
	mm._player_scene = net_world.player_scene
	mm.add_to_group(&"multiplayer_manager")
	root.add_child(mm)
	# Dirty the active floor with a real content change, then autosave.
	var room := net_world.room_world.get_room(Vector2i(0, 0))
	var def: BlockDefinition = null
	if room != null and room.block_layer != null:
		def = net_world.room_world.block_catalog.get_definition(&"standard_block")
		if def != null:
			room.block_layer.place_block(def, Vector2i(9, 9), 0.0)
	_expect(nfm.is_floor_dirty(), "content change did not dirty active floor")
	mm._run_autosave()
	_expect(not nfm.is_floor_dirty(), "autosave did not clear dirty flag")
	_expect(_manifest_exists(nfm.active_floor.floor_id),
		"autosave did not write manifest for active floor")
	# Shutdown save: dirty again, save, verify op rejection afterwards.
	if room != null and room.block_layer != null and def != null:
		room.block_layer.place_block(def, Vector2i(10, 10), 0.0)
	_expect(nfm.is_floor_dirty(), "second content change not dirty")
	mm.shutdown_save()
	_expect(not nfm.is_floor_dirty(), "shutdown_save did not clear dirty")
	_expect(mm._shutting_down, "shutdown_save did not set _shutting_down")
	var floors_before := nfm.floors.size()
	mm._handle_floor_op(99, 1, {"op": "floor_create", "floor_id": &"late_floor"})
	_expect(nfm.floors.size() == floors_before
		and nfm.get_floor(&"late_floor") == null,
		"floor op applied during shutdown")
	_free_now(mm)

func _free_now(node: Node) -> void:
	if node == null:
		return
	if node.get_parent() != null:
		node.get_parent().remove_child(node)
	node.free()

func _report() -> void:
	if _failures.is_empty():
		print("SERVER_PERSISTENCE_SMOKE: OK")
	else:
		print("SERVER_PERSISTENCE_SMOKE: FAILED (%d)" % _failures.size())
		for failure in _failures:
			print("  FAIL: %s" % failure)
