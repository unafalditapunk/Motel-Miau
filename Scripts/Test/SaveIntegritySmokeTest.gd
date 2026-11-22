extends SceneTree

## Smoke test for save integrity: room saves carry identity metadata
## (version, room_coordinates, size, global_origin), incompatible saves are
## rejected without being applied or deleted, and the audit/quarantine
## developer tools classify and preserve stale files.

const GRID_PATH := "res://Resources/IsometricGrid/TestGrid.tres"
const TILE_CATALOG_PATH := "res://Resources/TileCatalog.tres"
const BLOCK_CATALOG_PATH := "res://Resources/BlockCatalog.tres"
const FURNITURE_CATALOG_PATH := "res://Resources/FurnitureCatalog.tres"
const CARPET_CATALOG_PATH := "res://Resources/CarpetCatalog.tres"
const BLOCK_SCENE_PATH := "res://Scenes/Objects/Block.tscn"
const TEST_SAVE_DIR := "user://smoke_saves/save_integrity"

var _room_world: RoomWorld
var _frames := 0
var _failures: Array[String] = []

func _initialize() -> void:
	RoomSaveSystem.save_dir = TEST_SAVE_DIR
	_reset_save_dir()
	var grid := load(GRID_PATH) as IsometricGrid
	_room_world = RoomWorld.new()
	_room_world.name = "RoomWorld"
	_room_world.grid = grid
	_room_world.room_dimensions = Vector2i(8, 8)
	_room_world.default_tile_id = &"floor_iso"
	_room_world.tile_catalog = load(TILE_CATALOG_PATH) as TileCatalog
	_room_world.block_catalog = load(BLOCK_CATALOG_PATH) as BlockCatalog
	_room_world.furniture_catalog = load(FURNITURE_CATALOG_PATH) as FurnitureCatalog
	_room_world.carpet_catalog = load(CARPET_CATALOG_PATH) as CarpetCatalog
	_room_world.block_scene = load(BLOCK_SCENE_PATH) as PackedScene
	_room_world.hide_rooms_outside_neighborhood = false
	_room_world.deemphasize_neighbors = false
	_room_world.emphasis_transition_duration = 0.0
	_room_world.room_slide_duration = 0.0
	root.add_child(_room_world)
	_room_world.create_room_at(Vector2i(0, 0), Vector2i(0, 0), Vector2i(8, 8))
	_room_world.create_room_at(Vector2i(1, 0), Vector2i(8, 0), Vector2i(8, 8))

func _process(_delta: float) -> bool:
	_frames += 1
	if _frames < 6:
		return false
	_run_checks()
	_cleanup()
	_report()
	quit()
	return true

func _reset_save_dir() -> void:
	_remove_dir_contents(RoomSaveSystem.save_dir)

func _remove_dir_contents(path: String) -> void:
	var dir := DirAccess.open(path)
	if dir == null:
		return
	for file_name in dir.get_files():
		dir.remove(file_name)
	for sub in dir.get_directories():
		_remove_dir_contents(path.path_join(sub))
		DirAccess.remove_absolute(path.path_join(sub))

func _write_json(path: String, data: Dictionary) -> void:
	DirAccess.make_dir_recursive_absolute(RoomSaveSystem.save_dir)
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string(JSON.stringify(data))
	file.close()

func _expect(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)

func _run_checks() -> void:
	var room := _room_world.get_room(Vector2i(0, 0))
	_expect(room != null, "room (0,0) missing")
	if room == null:
		return

	# --- Round-trip: a valid save loads back ---
	_expect(RoomSaveSystem.save_room_world_room(_room_world, room) == OK, "save_room_world_room failed")
	var good_path := RoomSaveSystem.room_state_path(Vector2i(0, 0), Vector2i(8, 8))
	_expect(FileAccess.file_exists(good_path), "save file missing at %s" % good_path)
	_room_world.reset_room_state(room)
	_expect(RoomSaveSystem.load_room_world_room(_room_world, room), "valid save rejected on load")

	# --- Compatibility metadata checks ---
	var data := RoomSaveSystem.collect_room_state(room, room.block_layer)
	_expect(data.has("room_coordinates"), "save data lacks room_coordinates")
	_expect(data.has("size"), "save data lacks size")
	_expect(data.has("global_origin"), "save data lacks global_origin")
	_expect(data.has("version"), "save data lacks version")
	_expect(RoomSaveSystem.check_room_compatibility(data, room)["ok"], "fresh save reported incompatible")
	var wrong_coords := data.duplicate(true)
	wrong_coords["room_coordinates"] = [5, 5]
	_expect(not RoomSaveSystem.check_room_compatibility(wrong_coords, room)["ok"], "wrong room_coordinates accepted")
	var wrong_origin := data.duplicate(true)
	wrong_origin["global_origin"] = [99, 99]
	_expect(not RoomSaveSystem.check_room_compatibility(wrong_origin, room)["ok"], "wrong global_origin accepted")
	var wrong_size := data.duplicate(true)
	wrong_size["size"] = [4, 4]
	_expect(not RoomSaveSystem.check_room_compatibility(wrong_size, room)["ok"], "wrong size accepted")
	# Legacy saves without identity fields stay compatible on size+origin.
	var legacy := data.duplicate(true)
	legacy.erase("room_coordinates")
	legacy.erase("global_origin")
	_expect(RoomSaveSystem.check_room_compatibility(legacy, room)["ok"], "legacy save without identity rejected")
	# apply_room_state rejects incompatible data directly.
	_expect(not RoomSaveSystem.apply_room_state(_room_world, room, wrong_coords), "apply_room_state accepted wrong room_coordinates")
	_expect(RoomSaveSystem.apply_room_state(_room_world, room, data), "apply_room_state rejected valid data")

	# --- File-level rejection: incompatible save skipped, file preserved ---
	var bad_path := RoomSaveSystem.room_state_path(Vector2i(1, 0), Vector2i(8, 8))
	var bad_data := RoomSaveSystem.collect_room_state(_room_world.get_room(Vector2i(1, 0)), _room_world.get_room(Vector2i(1, 0)).block_layer)
	bad_data["global_origin"] = [42, 42]
	_write_json(bad_path, bad_data)
	var room_b := _room_world.get_room(Vector2i(1, 0))
	_room_world.reset_room_state(room_b)
	_expect(not RoomSaveSystem.load_room_world_room(_room_world, room_b), "incompatible save was applied")
	_expect(FileAccess.file_exists(bad_path), "incompatible save file was deleted")

	# --- Audit: compatible / incompatible / orphan classification ---
	# Orphan: valid save for a room that is not registered.
	var orphan_data := data.duplicate(true)
	orphan_data["room_coordinates"] = [9, 9]
	orphan_data["global_origin"] = [72, 0]
	_write_json(RoomSaveSystem.save_dir.path_join("room_9_9_8x8.json"), orphan_data)
	# Unreadable: corrupt JSON.
	_write_json(RoomSaveSystem.save_dir.path_join("room_2_2_8x8.json"), {"version": 1})
	# The (1,0) file is incompatible (wrong origin), (0,0) is compatible.
	var audit := RoomSaveSystem.audit_room_saves(_room_world)
	var by_name := {}
	for entry in audit:
		by_name[entry["path"].get_file()] = entry["status"]
	_expect(by_name.get(good_path.get_file()) == "compatible", "audit: good save not compatible (%s)" % str(by_name))
	_expect(by_name.get(bad_path.get_file()) == "incompatible", "audit: bad save not incompatible (%s)" % str(by_name))
	_expect(by_name.get("room_9_9_8x8.json") == "orphan", "audit: orphan save misclassified (%s)" % str(by_name))
	_expect(by_name.get("room_2_2_8x8.json") == "unreadable", "audit: corrupt save misclassified (%s)" % str(by_name))

	# --- Quarantine: only incompatible/orphan move, data preserved ---
	var moved := RoomSaveSystem.quarantine_incompatible_saves(_room_world)
	_expect(moved == 2, "quarantine moved %d files, expected 2" % moved)
	_expect(not FileAccess.file_exists(bad_path), "incompatible save still in place after quarantine")
	_expect(not FileAccess.file_exists(RoomSaveSystem.save_dir.path_join("room_9_9_8x8.json")), "orphan save still in place after quarantine")
	_expect(FileAccess.file_exists(good_path), "compatible save removed by quarantine")
	_expect(FileAccess.file_exists(RoomSaveSystem.save_dir.path_join("_quarantine").path_join(bad_path.get_file())), "quarantined file missing")
	_expect(FileAccess.file_exists(good_path), "compatible save lost")
	# After quarantine the room loads cleanly again.
	_room_world.reset_room_state(room_b)
	# The bad file moved away, so no save exists for room_b -> load returns false
	# but nothing incompatible is applied.
	_expect(not RoomSaveSystem.load_room_world_room(_room_world, room_b), "room_b unexpectedly loaded after quarantine")

func _cleanup() -> void:
	RoomSaveSystem.save_dir = RoomSaveSystem.SAVE_DIR

func _report() -> void:
	if _failures.is_empty():
		print("SAVE_INTEGRITY_SMOKE: OK")
	else:
		for failure in _failures:
			push_error("SAVE_INTEGRITY_SMOKE FAIL: " + failure)
		print("SAVE_INTEGRITY_SMOKE: FAILED (%d)" % _failures.size())
