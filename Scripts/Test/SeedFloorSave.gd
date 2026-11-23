extends SceneTree

## Dev tool: writes a REAL floor save (manifest + room states +
## connections) for the Motel floor into an isolated save root, with
## known placed contents, so multiplayer snapshot tests have
## authoritative server-side world data to replicate.
##
## Usage:
##   godot --headless --path . -s res://Scripts/Test/SeedFloorSave.gd -- \
##       --root=user://mp_verify/server --block=standard_block --at=3,3 \
##       --block=crate --at=8,8 --carpet=flower_carpet --at=5,5
##
## --root defaults to user://mp_verify/server. Re-running wipes the
## root first so results are deterministic.

const GRID_PATH := "res://Resources/IsometricGrid/TestGrid.tres"
const TILE_CATALOG_PATH := "res://Resources/TileCatalog.tres"
const BLOCK_CATALOG_PATH := "res://Resources/BlockCatalog.tres"
const FURNITURE_CATALOG_PATH := "res://Resources/FurnitureCatalog.tres"
const CARPET_CATALOG_PATH := "res://Resources/CarpetCatalog.tres"
const BLOCK_SCENE_PATH := "res://Scenes/Objects/Block.tscn"
const PLAYER_SCENE_PATH := "res://Scenes/Player/Player.tscn"
const FLOOR_ID := &"motel"
const ENTRY_ROOM := Vector2i(0, 0)

var _root := "user://mp_verify/server"
var _blocks: Array = []   # [{id, at}]
var _carpets: Array = []  # [{id, at}]
var _fm: FloorManager
var _world: RoomWorld
var _frames := 0

func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--root="):
			_root = arg.get_slice("=", 1)
		elif arg.begins_with("--block="):
			var spec := arg.get_slice("=", 1)
			_blocks.append({"id": spec.get_slice("@", 0),
				"at": _parse_cell(spec.get_slice("@", 1))})
		elif arg.begins_with("--carpet="):
			var spec := arg.get_slice("=", 1)
			_carpets.append({"id": spec.get_slice("@", 0),
				"at": _parse_cell(spec.get_slice("@", 1))})
	FloorSaveSystem.save_root = _root
	_remove_dir_contents(_root)
	_fm = FloorManager.new()
	_fm.name = "SeedFloorManager"
	root.add_child(_fm)
	_world = RoomWorld.new()
	_world.name = "SeedWorld"
	_world.grid = load(GRID_PATH) as IsometricGrid
	_world.room_dimensions = Vector2i(16, 16)
	_world.default_tile_id = &"floor_iso"
	_world.tile_catalog = load(TILE_CATALOG_PATH) as TileCatalog
	_world.block_catalog = load(BLOCK_CATALOG_PATH) as BlockCatalog
	_world.furniture_catalog = load(FURNITURE_CATALOG_PATH) as FurnitureCatalog
	_world.carpet_catalog = load(CARPET_CATALOG_PATH) as CarpetCatalog
	_world.block_scene = load(BLOCK_SCENE_PATH) as PackedScene
	_world.player_scene = load(PLAYER_SCENE_PATH) as PackedScene
	_world.hide_rooms_outside_neighborhood = false
	_world.deemphasize_neighbors = false
	root.add_child(_world)
	_fm.room_world = _world

func _parse_cell(text: String) -> Vector2i:
	var parts := text.split(",")
	if parts.size() != 2:
		return Vector2i(3, 3)
	return Vector2i(parts[0].to_int(), parts[1].to_int())

func _process(_delta: float) -> bool:
	_frames += 1
	if _frames == 1:
		return false
	# FloorManager._ready has auto-registered res:// floors by now.
	if not _fm.has_floor(FLOOR_ID):
		push_error("SEED FAIL: floor '%s' not registered." % FLOOR_ID)
		quit(1)
		return true
	if not _fm.load_floor(FLOOR_ID):
		push_error("SEED FAIL: load_floor failed.")
		quit(1)
		return true
	var room := _world.get_room(ENTRY_ROOM)
	if room == null:
		push_error("SEED FAIL: entry room %s missing." % ENTRY_ROOM)
		quit(1)
		return true
	for entry in _blocks:
		var def: BlockDefinition = _world.block_catalog.get_definition(StringName(entry["id"]))
		if def == null:
			push_error("SEED FAIL: unknown block '%s'." % entry["id"])
			quit(1)
			return true
		room.block_layer.place_block(def, entry["at"], 0.0)
	for entry in _carpets:
		var def: CarpetDefinition = _world.carpet_catalog.get_definition(StringName(entry["id"]))
		if def == null:
			push_error("SEED FAIL: unknown carpet '%s'." % entry["id"])
			quit(1)
			return true
		room.place_carpet(def, entry["at"], 0, false, 0.0)
	if not _fm.save_active_floor():
		push_error("SEED FAIL: save_active_floor failed.")
		quit(1)
		return true
	print("SEED OK: floor '%s' saved to '%s' (%d block(s), %d carpet(s))." % [
		FLOOR_ID, FloorSaveSystem.floor_dir(FLOOR_ID), _blocks.size(), _carpets.size()])
	quit()
	return true

func _remove_dir_contents(path: String) -> void:
	var dir := DirAccess.open(path)
	if dir == null:
		return
	for file_name in dir.get_files():
		dir.remove(file_name)
	for sub in dir.get_directories():
		_remove_dir_contents(path.path_join(sub))
		DirAccess.remove_absolute(path.path_join(sub))
