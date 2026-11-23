extends SceneTree

## Smoke test for WorldSnapshot: the server-authoritative world state
## transfer. Builds a world with placed contents on a "server" side,
## snapshots it, then reconstructs it on an independent "client" side
## (separate FloorManager + RoomWorld + player) and verifies rooms,
## connections, blocks, furniture, carpets and tile overrides match —
## while stale local saves are never consulted.

const GRID_PATH := "res://Resources/IsometricGrid/TestGrid.tres"
const TILE_CATALOG_PATH := "res://Resources/TileCatalog.tres"
const BLOCK_CATALOG_PATH := "res://Resources/BlockCatalog.tres"
const FURNITURE_CATALOG_PATH := "res://Resources/FurnitureCatalog.tres"
const CARPET_CATALOG_PATH := "res://Resources/CarpetCatalog.tres"
const BLOCK_SCENE_PATH := "res://Scenes/Objects/Block.tscn"
const PLAYER_SCENE_PATH := "res://Scenes/Player/Player.tscn"
const SCRATCH_ROOT := "user://smoke_snapshot_saves"

var _server_fm: FloorManager
var _server_world: RoomWorld
var _client_fm: FloorManager
var _client_world: RoomWorld
var _client_player: Player
var _frames := 0
var _failures: Array[String] = []
var _snapshot: Dictionary = {}
var _client_synced := false

func _initialize() -> void:
	FloorSaveSystem.save_root = SCRATCH_ROOT
	_remove_dir_contents(SCRATCH_ROOT)
	# Server side: its own FloorManager + RoomWorld.
	_server_fm = FloorManager.new()
	_server_fm.name = "ServerFloorManager"
	root.add_child(_server_fm)
	_server_world = _make_room_world("ServerWorld")
	_server_fm.room_world = _server_world
	# Client side: independent FloorManager + RoomWorld + player.
	_client_fm = FloorManager.new()
	_client_fm.name = "ClientFloorManager"
	root.add_child(_client_fm)
	_client_world = _make_room_world("ClientWorld")
	_client_fm.room_world = _client_world
	# Registration and world building are deferred to _process: node
	# _ready hooks run on the first frame in SceneTree scripts.

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
	var link := RoomConnection.new()
	link.connection_id = &"snap_link"
	link.source_room_id = Vector2i(0, 0)
	link.destination_room_id = Vector2i(1, 0)
	link.source_cells = [Vector2i(7, 3)]
	link.destination_cells = [Vector2i(0, 3)]
	link.interactive = false
	link.bidirectional = true
	var links: Array[RoomConnection] = [link]
	floor_def.connections = links
	return floor_def

func _spawn_client_player() -> void:
	var scene := load(PLAYER_SCENE_PATH) as PackedScene
	_client_player = scene.instantiate() as Player
	_client_player.grid = _client_world.grid
	_client_player.move_duration = 0.0
	_client_world.entity_layer.add_child(_client_player)

func _setup() -> void:
	# Same floor definition registered on both sides (independent
	# instances, like two processes loading the same .tres).
	var server_floor := _floor(&"snap_a")
	var client_floor := _floor(&"snap_a")
	_server_fm.register_floor(server_floor)
	_client_fm.register_floor(client_floor)
	_expect(_server_fm.load_floor(&"snap_a"), "server load_floor failed")
	# Client boots the MP way: definition only, no saves, no layout.
	_expect(_client_fm.load_floor_without_save(&"snap_a"), "client load_floor_without_save failed")
	_expect(_client_fm.active_floor != null, "client has no active floor")
	_spawn_client_player()
	# Give the client a STALE local save containing a block the server
	# never placed; the snapshot path must ignore it entirely.
	_write_stale_client_save()
	# Server world contents: two blocks, a chair, a carpet, a tile
	# elevation override — spread across both rooms.
	var room_a := _server_world.get_room(Vector2i(0, 0))
	var room_b := _server_world.get_room(Vector2i(1, 0))
	_place_block(room_a, &"standard_block", Vector2i(2, 2))
	_place_block(room_a, &"crate", Vector2i(5, 5))
	_place_furniture(room_a, Vector2i(3, 3))
	_place_carpet(room_a, Vector2i(6, 6))
	_place_tile_override(room_a, Vector2i(1, 1))
	_place_block(room_b, &"brick_block", Vector2i(4, 4))
	_expect(room_a != null and room_b != null, "server rooms missing")
	_snapshot = WorldSnapshot.build(_server_fm, _server_world)
	_expect(not _snapshot.is_empty(), "WorldSnapshot.build returned empty")
	# Simulate JSON round-trip: the wire format is JSON text.
	var json := JSON.stringify(_snapshot)
	var parsed: Variant = JSON.parse_string(json)
	_expect(parsed is Dictionary, "snapshot JSON round-trip failed")
	_snapshot = parsed

func _process(_delta: float) -> bool:
	_frames += 1
	if _frames == 1:
		_setup()
	if _frames == 2 and not _snapshot.is_empty():
		# Client applies the snapshot — the same call the RPC end
		# handler makes after reassembling chunks.
		_client_synced = WorldSnapshot.apply(
			_client_fm, _client_world, _client_player, _snapshot)
	if _frames < 5:
		return false
	_run_checks()
	_report()
	quit()
	return true

func _write_stale_client_save() -> void:
	# A local room save for the client's floor dir carrying a block
	# the server world does not have. load_floor_without_save must
	# never read it; apply() must overwrite whatever it built.
	var dir := FloorSaveSystem.floor_dir(&"snap_a")
	DirAccess.make_dir_recursive_absolute(dir)
	var path := dir.path_join("room_0_0_8x8.json")
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string(JSON.stringify({
		"version": 1,
		"room_id": "stale",
		"room_coordinates": [0, 0],
		"size": [8, 8],
		"global_origin": [0, 0],
		"spawn_position": [1, 1],
		"block_placements": [{
			"id": "wood_log", "position": [7, 7], "elevation": 0.0, "flip": false}],
		"furniture_placements": [],
		"carpet_placements": [],
		"tiles": [],
	}))
	file.close()

func _place_block(room: Room, object_id: StringName, cell: Vector2i) -> void:
	var def: BlockDefinition = _server_world.block_catalog.get_definition(object_id)
	if def == null or room == null or room.block_layer == null:
		_failures.append("cannot place block %s" % object_id)
		return
	room.block_layer.place_block(def, cell, 0.0)

func _place_furniture(room: Room, cell: Vector2i) -> void:
	var def: FurnitureDefinition = _server_world.furniture_catalog.get_definition(&"chair")
	if def == null or room == null or room.block_layer == null:
		_failures.append("cannot place furniture")
		return
	room.block_layer.place_furniture(def, cell, 0.0, 0)

func _place_carpet(room: Room, cell: Vector2i) -> void:
	var def: CarpetDefinition = _server_world.carpet_catalog.get_definition(&"flower_carpet")
	if def == null or room == null:
		_failures.append("cannot place carpet")
		return
	room.place_carpet(def, cell, 0, false, 0.0)

func _place_tile_override(room: Room, cell: Vector2i) -> void:
	var def: TileDefinition = _server_world.tile_catalog.get_definition(&"floor_iso")
	if def == null or room == null:
		_failures.append("cannot place tile override")
		return
	room.set_cell_tile(cell, def, 0.5)

func _client_room(room_id: Vector2i) -> Room:
	return _client_world.get_room(room_id)

func _run_checks() -> void:
	_expect(_client_synced, "WorldSnapshot.apply failed on client")
	if not _client_synced:
		return
	# Layout: same rooms, same bounds, same connection count.
	_expect(_client_world.registry.get_rooms().size() == 2,
		"client room count %d != 2" % _client_world.registry.get_rooms().size())
	var room_a := _client_room(Vector2i(0, 0))
	var room_b := _client_room(Vector2i(1, 0))
	_expect(room_a != null and room_b != null, "client rooms missing")
	if room_a == null or room_b == null:
		return
	_expect(room_a.global_bounds() == Rect2i(Vector2i(0, 0), Vector2i(8, 8)),
		"client room (0,0) bounds wrong: %s" % room_a.global_bounds())
	_expect(room_b.global_bounds() == Rect2i(Vector2i(8, 0), Vector2i(8, 8)),
		"client room (1,0) bounds wrong: %s" % room_b.global_bounds())
	_expect(_client_world.connections.size() == 1,
		"client connections %d != 1" % _client_world.connections.size())
	# Blocks: same ids on both sides (order may differ).
	var server_a_ids := _block_ids_sorted(_server_world.get_room(Vector2i(0, 0)))
	var client_a_ids := _block_ids_sorted(room_a)
	_expect(server_a_ids == client_a_ids,
		"room (0,0) block ids differ: server %s vs client %s" % [server_a_ids, client_a_ids])
	var server_b_ids := _block_ids_sorted(_server_world.get_room(Vector2i(1, 0)))
	var client_b_ids := _block_ids_sorted(room_b)
	_expect(server_b_ids == client_b_ids,
		"room (1,0) block ids differ: server %s vs client %s" % [server_b_ids, client_b_ids])
	# The stale wood_log at (7,7) must NOT exist on the client.
	for block in room_a.block_layer.blocks:
		_expect(String(block.block_id) != "wood_log",
			"stale local-save block leaked into client world")
	# Carpet anchor present on client.
	var carpet_cell := room_a.get_cell(Vector2i(6, 6))
	_expect(carpet_cell != null and carpet_cell.carpet != null
		and String(carpet_cell.carpet.object_id) == "flower_carpet",
		"client carpet missing at (6,6)")
	# Tile elevation override survived.
	var tile_cell := room_a.get_cell(Vector2i(1, 1))
	_expect(tile_cell != null and not is_equal_approx(tile_cell.tile_elevation, 0.0),
		"client tile elevation override missing")
	# Player re-placed at the floor entry spawn.
	_expect(_client_player.room == room_a, "client player not in entry room")
	_expect(_client_player.grid_position == Vector2i(2, 2),
		"client player pos %s != spawn (2,2)" % _client_player.grid_position)
	# Client floor def now carries the server layout.
	_expect(_client_fm.active_floor != null
		and _client_fm.active_floor.rooms.size() == 2,
		"client floor specs not updated from snapshot")

func _block_ids_sorted(room: Room) -> Array:
	var ids: Array = []
	if room != null and room.block_layer != null:
		for block in room.block_layer.blocks:
			ids.append(String(block.block_id))
	ids.sort()
	return ids

func _expect(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)

func _report() -> void:
	if _failures.is_empty():
		print("WORLD_SNAPSHOT_SMOKE: OK")
	else:
		for failure in _failures:
			push_error("WORLD_SNAPSHOT_SMOKE FAIL: %s" % failure)
		print("WORLD_SNAPSHOT_SMOKE: FAILED (%d)" % _failures.size())

func _remove_dir_contents(path: String) -> void:
	var dir := DirAccess.open(path)
	if dir == null:
		return
	for file_name in dir.get_files():
		dir.remove(file_name)
	for sub in dir.get_directories():
		_remove_dir_contents(path.path_join(sub))
		DirAccess.remove_absolute(path.path_join(sub))
