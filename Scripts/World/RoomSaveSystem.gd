class_name RoomSaveSystem
extends RefCounted

## Serializes the logical state of a World/Room (dimensions, placements,
## spawn, player position) to JSON files under user://saves/.
## Visual scene nodes are never serialized; rooms are rebuilt from
## catalog definitions on load.

const SAVE_DIR := "user://saves"
const VERSION := 1
const DEFAULT_ROOM_NAME := "room"
const MAX_ROOM_DIMENSION := 4096

# ------------------------------------------------------------------
# Public API
# ------------------------------------------------------------------

static func save_path(room_name: String) -> String:
	return SAVE_DIR.path_join("%s.json" % sanitize_room_name(room_name))

static func sanitize_room_name(room_name: String) -> String:
	var re := RegEx.new()
	re.compile("[^A-Za-z0-9_-]+")
	var cleaned := re.sub(room_name.strip_edges(), "_", true)
	return cleaned if not cleaned.is_empty() else DEFAULT_ROOM_NAME

## Saves the current state of the world's room. When room_name is empty
## the room_definition's room_id is used as the save name.
static func save_room(world: World, room_name := "") -> Error:
	if world == null or world.room == null or world.block_layer == null:
		push_error("RoomSaveSystem.save_room requires a World with Room and BlockLayer.")
		return ERR_INVALID_PARAMETER
	if room_name.is_empty():
		room_name = _room_name(world)
	if not _ensure_save_dir():
		push_error("RoomSaveSystem could not create save dir '%s'." % SAVE_DIR)
		return ERR_CANT_CREATE
	var path := save_path(room_name)
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		push_error("RoomSaveSystem could not open '%s' for writing: %s" % [path, error_string(FileAccess.get_open_error())])
		return FileAccess.get_open_error()
	file.store_string(JSON.stringify(collect_room_data(world), "\t"))
	file.close()
	return OK

## Loads a saved room into the world. When room_name is empty, the save
## matching the current room_id is used; if missing, the most recently
## modified save in the save directory is loaded instead.
static func load_room(world: World, room_name := "") -> bool:
	if world == null or world.room == null or world.block_layer == null:
		push_error("RoomSaveSystem.load_room requires a World with Room and BlockLayer.")
		return false
	var path := resolve_save_path(world, room_name)
	if path.is_empty():
		push_error("RoomSaveSystem: no save files found in '%s'." % SAVE_DIR)
		return false
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		push_error("RoomSaveSystem could not open '%s': %s" % [path, error_string(FileAccess.get_open_error())])
		return false
	var text := file.get_as_text()
	file.close()
	var parsed: Variant = JSON.parse_string(text)
	if not (parsed is Dictionary):
		push_error("RoomSaveSystem: '%s' is not valid JSON." % path)
		return false
	var data: Dictionary = parsed
	var validation := validate_data(data)
	if not validation["ok"]:
		for error in validation["errors"]:
			push_error("RoomSaveSystem: %s" % str(error))
		return false
	return apply_data(world, data)

## Returns save metadata (name, path, modified_time) sorted newest first.
static func list_saves() -> Array[Dictionary]:
	var saves: Array[Dictionary] = []
	var dir := DirAccess.open(SAVE_DIR)
	if dir == null:
		return saves
	dir.list_dir_begin()
	var file_name := dir.get_next()
	while file_name != "":
		if not dir.current_is_dir() and file_name.ends_with(".json"):
			var path := SAVE_DIR.path_join(file_name)
			saves.append({
				"name": file_name.get_basename(),
				"path": path,
				"modified_time": FileAccess.get_modified_time(path),
			})
		file_name = dir.get_next()
	dir.list_dir_end()
	saves.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return a["modified_time"] > b["modified_time"])
	return saves

# ------------------------------------------------------------------
# RoomWorld room states (keyed by room coordinates, no player data)
# ------------------------------------------------------------------

static func room_state_name(room_coordinates: Vector2i, size: Vector2i) -> String:
	return "room_%d_%d_%dx%d" % [room_coordinates.x, room_coordinates.y, size.x, size.y]

static func room_state_path(room_coordinates: Vector2i, size: Vector2i) -> String:
	return SAVE_DIR.path_join("%s.json" % room_state_name(room_coordinates, size))

## Pre-dimension filenames shared saves across different room sizes; kept
## only as a read fallback so existing saves are not orphaned.
static func legacy_room_state_path(room_coordinates: Vector2i) -> String:
	return SAVE_DIR.path_join("room_%d_%d.json" % [room_coordinates.x, room_coordinates.y])

static func room_state_candidates(room_coordinates: Vector2i, size: Vector2i) -> Array[String]:
	var paths: Array[String] = []
	var current := room_state_path(room_coordinates, size)
	if FileAccess.file_exists(current):
		paths.append(current)
	var legacy := legacy_room_state_path(room_coordinates)
	if FileAccess.file_exists(legacy):
		paths.append(legacy)
	return paths

static func player_state_path() -> String:
	return SAVE_DIR.path_join("player_state.json")

static func connections_path() -> String:
	return SAVE_DIR.path_join("connections.json")

## Saves the RoomWorld's explicit room connection graph. Connections are
## world-layout data, stored separately from per-room contents.
static func save_connections(room_world: RoomWorld) -> Error:
	if room_world == null:
		push_error("RoomSaveSystem.save_connections requires a RoomWorld.")
		return ERR_INVALID_PARAMETER
	if not _ensure_save_dir():
		push_error("RoomSaveSystem could not create save dir '%s'." % SAVE_DIR)
		return ERR_CANT_CREATE
	var path := connections_path()
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		push_error("RoomSaveSystem could not open '%s' for writing: %s" % [path, error_string(FileAccess.get_open_error())])
		return FileAccess.get_open_error()
	file.store_string(JSON.stringify({
		"version": VERSION,
		"connections": room_world.connections.serialize_all(),
	}, "\t"))
	file.close()
	return OK

## Restores the room connection graph. Must be called after all rooms are
## registered; entries referencing missing rooms or invalid cells are
## skipped with warnings. Returns false when no connections file exists.
static func load_connections(room_world: RoomWorld) -> bool:
	if room_world == null:
		push_error("RoomSaveSystem.load_connections requires a RoomWorld.")
		return false
	var path := connections_path()
	if not FileAccess.file_exists(path):
		return false
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		push_error("RoomSaveSystem could not open '%s': %s" % [path, error_string(FileAccess.get_open_error())])
		return false
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	file.close()
	if not (parsed is Dictionary):
		push_error("RoomSaveSystem: '%s' is not valid JSON." % path)
		return false
	var data: Dictionary = parsed
	if _as_int(data.get("version")) != VERSION:
		push_error("RoomSaveSystem: '%s' has unsupported version." % path)
		return false
	var loaded := room_world.connections.deserialize_all(data.get("connections", []))
	print("RoomSaveSystem loaded %d room connection(s) from '%s'." % [loaded, path])
	return true

## Saves a single RoomWorld room's contents (blocks, furniture, carpets,
## tiles). Player position is stored separately via save_player_state().
static func save_room_world_room(room_world: RoomWorld, room: Room) -> Error:
	if room_world == null or room == null or room.block_layer == null:
		push_error("RoomSaveSystem.save_room_world_room requires a RoomWorld and a Room with BlockLayer.")
		return ERR_INVALID_PARAMETER
	if not _ensure_save_dir():
		push_error("RoomSaveSystem could not create save dir '%s'." % SAVE_DIR)
		return ERR_CANT_CREATE
	var path := room_state_path(room.room_coordinates, room.size)
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		push_error("RoomSaveSystem could not open '%s' for writing: %s" % [path, error_string(FileAccess.get_open_error())])
		return FileAccess.get_open_error()
	var state_name := room_state_name(room.room_coordinates, room.size)
	var spawn := Vector2i(room.size.x >> 1, room.size.y >> 1)
	file.store_string(JSON.stringify(_collect_room_data(room, room.block_layer, null, state_name, state_name, spawn), "\t"))
	file.close()
	return OK

## Loads a saved room state into a RoomWorld room. Returns false when no
## save exists for the room's coordinates or the save is invalid.
static func load_room_world_room(room_world: RoomWorld, room: Room) -> bool:
	if room_world == null or room == null or room.block_layer == null:
		push_error("RoomSaveSystem.load_room_world_room requires a RoomWorld and a Room with BlockLayer.")
		return false
	var candidates := room_state_candidates(room.room_coordinates, room.size)
	if candidates.is_empty():
		return false
	var tile_layer := room.get_node_or_null(^"TileLayer") as TileLayer
	var carpet_layer := room.get_node_or_null(^"CarpetLayer") as CarpetLayer
	for path in candidates:
		var data := _read_save_file(path)
		if data.is_empty():
			continue
		var size := _read_size(data.get("size"))
		if size == Vector2i.ZERO or size != room.size:
			push_warning("RoomSaveSystem: save '%s' size %s does not match room size %s; skipped." % [path, size, room.size])
			continue
		return _apply_data(
			room, room.block_layer, tile_layer, carpet_layer, null,
			room_world.grid, room_world.block_catalog, room_world.furniture_catalog,
			room_world.carpet_catalog, room_world.tile_catalog, data)
	return false

## Persists which room the player is in and where they stand, so the next
## session can restore the exact position.
static func save_player_state(room_coordinates: Vector2i, position: Vector2i, elevation: float) -> Error:
	if not _ensure_save_dir():
		push_error("RoomSaveSystem could not create save dir '%s'." % SAVE_DIR)
		return ERR_CANT_CREATE
	var path := player_state_path()
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		push_error("RoomSaveSystem could not open '%s' for writing: %s" % [path, error_string(FileAccess.get_open_error())])
		return FileAccess.get_open_error()
	file.store_string(JSON.stringify({
		"version": VERSION,
		"room_coordinates": [room_coordinates.x, room_coordinates.y],
		"position": [position.x, position.y],
		"elevation": elevation,
	}, "\t"))
	file.close()
	return OK

## Returns {"room_coordinates", "position", "elevation"} or an empty
## Dictionary when no valid player state exists.
static func load_player_state() -> Dictionary:
	var result := {}
	var path := player_state_path()
	if not FileAccess.file_exists(path):
		return result
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return result
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	file.close()
	if not (parsed is Dictionary):
		return result
	var data: Dictionary = parsed
	if _as_int(data.get("version")) != VERSION:
		return result
	var coordinates = _read_vec2i(data.get("room_coordinates"))
	var position = _read_vec2i(data.get("position"))
	var elevation: Variant = data.get("elevation", 0.0)
	if coordinates == null or position == null or not _is_finite_number(elevation):
		return result
	result["room_coordinates"] = coordinates
	result["position"] = position
	result["elevation"] = float(elevation)
	return result

static func _read_save_file(path: String) -> Dictionary:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		push_error("RoomSaveSystem could not open '%s': %s" % [path, error_string(FileAccess.get_open_error())])
		return {}
	var text := file.get_as_text()
	file.close()
	var parsed: Variant = JSON.parse_string(text)
	if not (parsed is Dictionary):
		push_error("RoomSaveSystem: '%s' is not valid JSON." % path)
		return {}
	var data: Dictionary = parsed
	var validation := validate_data(data)
	if not validation["ok"]:
		for error in validation["errors"]:
			push_error("RoomSaveSystem: %s" % str(error))
		return {}
	return data

# ------------------------------------------------------------------
# Data collection
# ------------------------------------------------------------------

static func collect_room_data(world: World) -> Dictionary:
	var room_def := world.room_definition
	var spawn := Vector2i(1, 1)
	var room_id := ""
	var display_name := ""
	if room_def != null:
		room_id = str(room_def.room_id)
		display_name = room_def.display_name
		spawn = room_def.spawn_position
	return _collect_room_data(world.room, world.block_layer, world.player, room_id, display_name, spawn)

static func _collect_room_data(room: Room, block_layer: BlockLayer, player: Player, room_id: String, display_name: String, spawn: Vector2i) -> Dictionary:
	var block_placements: Array = []
	var furniture_placements: Array = []
	var carpet_placements: Array = []
	for block in block_layer.blocks:
		if not is_instance_valid(block):
			continue
		var entry := _serialize_block(block)
		var furniture := block as Furniture
		if furniture != null:
			entry["rotation"] = furniture.furniture_rotation_degrees
			furniture_placements.append(entry)
		else:
			block_placements.append(entry)
	for coordinates in room.cells:
		var cell: RoomCell = room.cells[coordinates]
		if cell.carpet != null and cell.carpet_anchor == coordinates:
			carpet_placements.append(_serialize_carpet(cell))

	return {
		"version": VERSION,
		"room_id": room_id,
		"display_name": display_name,
		"size": [room.size.x, room.size.y],
		"global_origin": [room.cell_origin.x, room.cell_origin.y],
		"grid_resource": room.grid.resource_path if room.grid != null else "",
		"spawn_position": [spawn.x, spawn.y],
		"player": _serialize_player(player),
		"block_placements": block_placements,
		"furniture_placements": furniture_placements,
		"carpet_placements": carpet_placements,
		"tiles": _collect_tiles(room),
		"saved_at": Time.get_unix_time_from_system(),
	}

static func _serialize_block(block: Block) -> Dictionary:
	var sprite := block.get_node_or_null(^"Sprite") as Sprite2D
	return {
		"id": String(block.block_id),
		"position": [block.grid_position.x, block.grid_position.y],
		"elevation": block.elevation,
		"flip": sprite != null and sprite.flip_h,
	}

static func _serialize_carpet(cell: RoomCell) -> Dictionary:
	return {
		"id": String(cell.carpet.object_id),
		"position": [cell.carpet_anchor.x, cell.carpet_anchor.y],
		"rotation": cell.carpet_rotation_degrees,
		"flip": cell.carpet_flip,
		"elevation": cell.carpet_elevation,
	}

static func _serialize_player(player: Player) -> Dictionary:
	if player == null:
		return {}
	return {
		"position": [player.grid_position.x, player.grid_position.y],
		"elevation": player.elevation,
	}

## Saves only cells whose tile differs from the room's default tile, so a
## uniformly tiled room produces a compact save. An empty id means the cell
## was explicitly cleared (no tile).
static func _collect_tiles(room: Room) -> Array:
	var tiles: Array = []
	var default_tile_id := StringName()
	if room.default_tile != null:
		default_tile_id = room.default_tile.object_id
	for coordinates in room.cells:
		var cell: RoomCell = room.cells[coordinates]
		var tile_id := cell.tile.object_id if cell.tile != null else StringName()
		if tile_id == default_tile_id and is_equal_approx(cell.tile_elevation, 0.0):
			continue
		tiles.append({
			"position": [coordinates.x, coordinates.y],
			"id": String(tile_id),
			"elevation": cell.tile_elevation,
		})
	return tiles

# ------------------------------------------------------------------
# Loading / reconstruction
# ------------------------------------------------------------------

static func resolve_save_path(world: World, room_name := "") -> String:
	var name := room_name
	if name.is_empty():
		name = _room_name(world)
	if not name.is_empty():
		var exact := save_path(name)
		if FileAccess.file_exists(exact):
			return exact
	var saves := list_saves()
	return saves[0]["path"] if not saves.is_empty() else ""

static func apply_data(world: World, data: Dictionary) -> bool:
	var definition_grid: IsometricGrid = null
	if world.room_definition != null:
		definition_grid = world.room_definition.grid
	return _apply_data(
		world.room, world.block_layer, world.tile_layer, world.carpet_layer, world.player,
		definition_grid, world.block_catalog, world.furniture_catalog, world.carpet_catalog, world.tile_catalog,
		data)

static func _apply_data(
	room: Room,
	block_layer: BlockLayer,
	tile_layer: TileLayer,
	carpet_layer: CarpetLayer,
	player: Player,
	definition_grid: IsometricGrid,
	block_catalog: BlockCatalog,
	furniture_catalog: FurnitureCatalog,
	carpet_catalog: CarpetCatalog,
	tile_catalog: TileCatalog,
	data: Dictionary
) -> bool:
	if room == null or block_layer == null:
		push_error("RoomSaveSystem.apply_data requires a Room and BlockLayer.")
		return false
	var size := _read_size(data.get("size"))
	if size == Vector2i.ZERO:
		push_error("RoomSaveSystem: cannot apply data with invalid size.")
		return false
	# The room's position in the world layout is owned by RoomWorld
	# registration, not by the save. The saved origin is kept for
	# reference/migration; a mismatch is reported but never applied here.
	var saved_origin = _read_vec2i(data.get("global_origin"))
	if saved_origin != null and saved_origin != room.cell_origin:
		push_warning("RoomSaveSystem: save global_origin %s differs from room origin %s; room keeps its registered position." % [saved_origin, room.cell_origin])
	var grid := _resolve_grid(room, definition_grid, str(data.get("grid_resource", "")))
	if grid == null:
		push_error("RoomSaveSystem: no IsometricGrid available for load.")
		return false

	room.grid = grid
	room.set_size(size)
	block_layer.grid = grid
	block_layer.room_size = size
	if tile_layer != null:
		tile_layer.grid = grid
	if carpet_layer != null:
		carpet_layer.grid = grid
	if player != null:
		player.grid = grid
		player.room_size = size
	block_layer.clear_blocks()

	# Sort by elevation ascending so elevated objects find their support.
	var pending: Array[Dictionary] = []
	for entry in data.get("block_placements", []):
		pending.append({"kind": "block", "entry": entry, "order": pending.size()})
	for entry in data.get("furniture_placements", []):
		pending.append({"kind": "furniture", "entry": entry, "order": pending.size()})
	pending.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		var ea := float(a["entry"].get("elevation", 0.0))
		var eb := float(b["entry"].get("elevation", 0.0))
		if not is_equal_approx(ea, eb):
			return ea < eb
		return int(a["order"]) < int(b["order"]))

	var skipped := 0
	for item in pending:
		var entry: Dictionary = item["entry"]
		var object_id := StringName(str(entry.get("id", "")))
		var position = _read_vec2i(entry.get("position"))
		var elevation := float(entry.get("elevation", 0.0))
		var flip := bool(entry.get("flip", false))
		var placed: Block = null
		if item["kind"] == "block":
			var def: BlockDefinition = block_catalog.get_definition(object_id) if block_catalog != null else null
			if def == null:
				push_warning("RoomSaveSystem: missing block definition '%s'; skipped." % object_id)
				skipped += 1
				continue
			placed = block_layer.place_block(def, position, elevation)
		else:
			var def: FurnitureDefinition = furniture_catalog.get_definition(object_id) if furniture_catalog != null else null
			if def == null:
				push_warning("RoomSaveSystem: missing furniture definition '%s'; skipped." % object_id)
				skipped += 1
				continue
			var rotation := posmod(int(entry.get("rotation", 0)), 360)
			placed = block_layer.place_furniture(def, position, elevation, rotation)
		if placed == null:
			push_warning("RoomSaveSystem: could not place '%s' at %s (elevation %.2f); skipped." % [object_id, position, elevation])
			skipped += 1
		elif flip:
			var sprite := placed.get_node_or_null(^"Sprite") as Sprite2D
			if sprite != null:
				sprite.flip_h = true

	var carpet_entries: Variant = data.get("carpet_placements", [])
	if carpet_entries is Array:
		for entry in carpet_entries:
			if not (entry is Dictionary):
				push_warning("RoomSaveSystem: invalid carpet placement entry; skipped.")
				skipped += 1
				continue
			var carpet_entry: Dictionary = entry
			var object_id := StringName(str(carpet_entry.get("id", "")))
			var position = _read_vec2i(carpet_entry.get("position"))
			var definition: CarpetDefinition = carpet_catalog.get_definition(object_id) if carpet_catalog != null else null
			if definition == null or position == null:
				push_warning("RoomSaveSystem: missing carpet definition '%s'; skipped." % object_id)
				skipped += 1
				continue
			var rotation := posmod(int(carpet_entry.get("rotation", 0)), 360)
			var flip := bool(carpet_entry.get("flip", false))
			var elevation := float(carpet_entry.get("elevation", 0.0))
			if not room.place_carpet(definition, position, rotation, flip, elevation):
				push_warning("RoomSaveSystem: could not place carpet '%s' at %s; skipped." % [object_id, position])
				skipped += 1
	if skipped > 0:
		push_warning("RoomSaveSystem: %d placement(s) skipped during load." % skipped)

	_apply_tiles(tile_catalog, room, data)
	_place_player(player, data, size)
	return true

static func _apply_tiles(tile_catalog: TileCatalog, room: Room, data: Dictionary) -> void:
	var entries: Variant = data.get("tiles", [])
	if not (entries is Array) or (entries as Array).is_empty():
		return
	var catalog := tile_catalog
	for entry in entries:
		if not (entry is Dictionary):
			continue
		var position = _read_vec2i(entry.get("position"))
		if position == null:
			continue
		var tile_id := str(entry.get("id", ""))
		var elevation := float(entry.get("elevation", 0.0))
		if tile_id.is_empty():
			room.clear_cell_tile(position)
			continue
		if catalog == null:
			push_warning("RoomSaveSystem: saved tile '%s' but World has no TileCatalog; skipped." % tile_id)
			continue
		var definition := catalog.get_definition(StringName(tile_id))
		if definition == null:
			push_warning("RoomSaveSystem: missing tile definition '%s'; skipped." % tile_id)
			continue
		room.set_cell_tile(position, definition, elevation)

static func _place_player(player: Player, data: Dictionary, size: Vector2i) -> void:
	if player == null:
		return
	var player_data: Variant = data.get("player", {})
	if player_data is Dictionary:
		var position = _read_vec2i(player_data.get("position"))
		if position != null and _in_bounds(position, size):
			player.place_at(position, float(player_data.get("elevation", 0.0)))
			return
	var spawn = _read_vec2i(data.get("spawn_position"))
	if spawn == null or not _in_bounds(spawn, size):
		spawn = Vector2i(1, 1)
	player.place_at(spawn, player.stand_elevation_at(spawn))

static func _resolve_grid(room: Room, definition_grid: IsometricGrid, grid_path: String) -> IsometricGrid:
	if not grid_path.is_empty() and grid_path.begins_with("res://") and ResourceLoader.exists(grid_path):
		var resource := ResourceLoader.load(grid_path)
		if resource is IsometricGrid:
			return resource
		push_warning("RoomSaveSystem: saved grid '%s' is not an IsometricGrid; keeping current grid." % grid_path)
	if room != null and room.grid != null:
		return room.grid
	if definition_grid != null:
		return definition_grid
	push_error("RoomSaveSystem: no IsometricGrid available for load.")
	return null

# ------------------------------------------------------------------
# Validation
# ------------------------------------------------------------------

static func validate_data(data: Dictionary) -> Dictionary:
	var errors: Array[String] = []

	var version = _as_int(data.get("version"))
	if version == null or version != VERSION:
		errors.append("unsupported or missing save version (expected %d)." % VERSION)

	var size := _read_size(data.get("size"))
	if size == Vector2i.ZERO:
		errors.append("missing or invalid room size.")

	var room_id = data.get("room_id", "")
	if not (room_id is String):
		errors.append("room_id must be a string.")

	var spawn = _read_vec2i(data.get("spawn_position"))
	if spawn == null:
		errors.append("missing or invalid spawn_position.")
	elif size != Vector2i.ZERO and not _in_bounds(spawn, size):
		errors.append("spawn_position %s is outside room bounds %s." % [spawn, size])

	var grid_resource = data.get("grid_resource", "")
	if not (grid_resource is String):
		errors.append("grid_resource must be a string.")

	_validate_player(data.get("player", {}), size, errors)
	_validate_placements(data.get("block_placements"), "block_placements", size, errors)
	_validate_placements(data.get("furniture_placements"), "furniture_placements", size, errors)
	if data.has("carpet_placements"):
		_validate_placements(data.get("carpet_placements"), "carpet_placements", size, errors)
	_validate_tiles(data.get("tiles"), size, errors)

	return {"ok": errors.is_empty(), "errors": errors}

static func _validate_player(player_data: Variant, size: Vector2i, errors: Array[String]) -> void:
	if player_data == null:
		return
	if not (player_data is Dictionary):
		errors.append("player must be an object.")
		return
	if (player_data as Dictionary).is_empty():
		return
	var position = _read_vec2i(player_data.get("position"))
	if position == null:
		errors.append("invalid player position.")
	elif size != Vector2i.ZERO and not _in_bounds(position, size):
		errors.append("player position %s is outside room bounds %s." % [position, size])
	var elevation: Variant = player_data.get("elevation", 0.0)
	if not _is_finite_number(elevation) or float(elevation) < 0.0:
		errors.append("invalid player elevation.")

static func _validate_placements(placements: Variant, key: String, size: Vector2i, errors: Array[String]) -> void:
	if placements == null:
		errors.append("missing %s array." % key)
		return
	if not (placements is Array):
		errors.append("%s must be an array." % key)
		return
	for i in (placements as Array).size():
		var entry: Variant = placements[i]
		if not (entry is Dictionary):
			errors.append("%s[%d] must be an object." % [key, i])
			continue
		var object_id = entry.get("id")
		if not (object_id is String) or String(object_id).is_empty():
			errors.append("%s[%d] has a missing or invalid id." % [key, i])
		var position = _read_vec2i(entry.get("position"))
		if position == null:
			errors.append("%s[%d] has an invalid position." % [key, i])
		elif size != Vector2i.ZERO and not _in_bounds(position, size):
			errors.append("%s[%d] position %s is outside room bounds %s." % [key, i, position, size])
		var elevation: Variant = entry.get("elevation", 0.0)
		if not _is_finite_number(elevation) or float(elevation) < 0.0:
			errors.append("%s[%d] has an invalid elevation." % [key, i])
		if key == "furniture_placements" or key == "carpet_placements":
			var rotation: Variant = entry.get("rotation", 0)
			if not _is_finite_number(rotation):
				errors.append("%s[%d] has an invalid rotation." % [key, i])

static func _validate_tiles(tiles: Variant, size: Vector2i, errors: Array[String]) -> void:
	if tiles == null:
		return
	if not (tiles is Array):
		errors.append("tiles must be an array.")
		return
	for i in (tiles as Array).size():
		var entry: Variant = tiles[i]
		if not (entry is Dictionary):
			errors.append("tiles[%d] must be an object." % i)
			continue
		var position = _read_vec2i(entry.get("position"))
		if position == null:
			errors.append("tiles[%d] has an invalid position." % i)
		elif size != Vector2i.ZERO and not _in_bounds(position, size):
			errors.append("tiles[%d] position %s is outside room bounds %s." % [i, position, size])
		var tile_id: Variant = entry.get("id", "")
		if not (tile_id is String):
			errors.append("tiles[%d] has an invalid id." % i)
		var elevation: Variant = entry.get("elevation", 0.0)
		if not _is_finite_number(elevation) or float(elevation) < 0.0:
			errors.append("tiles[%d] has an invalid elevation." % i)

# ------------------------------------------------------------------
# Conversion helpers
# ------------------------------------------------------------------

static func _room_name(world: World) -> String:
	if world.room_definition != null:
		var id := str(world.room_definition.room_id)
		if not id.is_empty():
			return id
	return DEFAULT_ROOM_NAME

static func _ensure_save_dir() -> bool:
	return DirAccess.make_dir_recursive_absolute(SAVE_DIR) == OK

static func _is_finite_number(value: Variant) -> bool:
	if not (value is int or value is float):
		return false
	var f := float(value)
	return not (is_nan(f) or is_inf(f))

## Reads an integer-valued JSON number (Godot parses all JSON numbers as
## float). Returns null when the value is not an integer.
static func _as_int(value: Variant) -> Variant:
	if not _is_finite_number(value):
		return null
	var f := float(value)
	if f != floor(f) or absf(f) > 9007199254740991.0:
		return null
	return int(f)

static func _read_vec2i(value: Variant) -> Variant:
	if not (value is Array) or (value as Array).size() != 2:
		return null
	var array: Array = value
	var x = _as_int(array[0])
	var y = _as_int(array[1])
	if x == null or y == null:
		return null
	return Vector2i(int(x), int(y))

static func _read_size(value: Variant) -> Vector2i:
	var vec = _read_vec2i(value)
	if vec == null:
		return Vector2i.ZERO
	var size := vec as Vector2i
	if size.x <= 0 or size.y <= 0 or size.x > MAX_ROOM_DIMENSION or size.y > MAX_ROOM_DIMENSION:
		return Vector2i.ZERO
	return size

static func _in_bounds(cell: Vector2i, size: Vector2i) -> bool:
	return cell.x >= 0 and cell.y >= 0 and cell.x < size.x and cell.y < size.y
