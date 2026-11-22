class_name FloorSaveSystem
extends RefCounted

## Floor-level persistence. Each floor gets its own directory
## (user://floors/<floor_id>/ by default) containing:
##   floor.json             — this manifest (version, floor_id, metadata)
##   room_*.json            — standard RoomSaveSystem room states
##   connections.json       — standard RoomSaveSystem connection graph
##   player_state.json      — standard RoomSaveSystem player position
##
## Room serialization is NOT duplicated here: FloorManager/RoomWorld
## point RoomSaveSystem.save_dir at the floor directory while saving or
## loading, so every existing room/connections/player code path is
## reused unchanged. This class only owns the directory layout and the
## floor manifest, which acts as the commit marker and compatibility
## gate for the whole floor save.
##
## save_root is a static var (not const) so tests can redirect floor
## saves to a scratch directory; gameplay never changes it.

static var save_root := "user://floors"
const MANIFEST_NAME := "floor.json"
const LAYOUT_NAME := "layout.json"
const VERSION := 1

# ------------------------------------------------------------------
# Paths
# ------------------------------------------------------------------

## Directory holding one floor's saves, or "" when the floor id cannot
## be used as a single path segment.
static func floor_dir(floor_id: StringName) -> String:
	var id := _sanitize_floor_id(floor_id)
	if id.is_empty():
		return ""
	return save_root.path_join(id)

static func manifest_path(floor_id: StringName) -> String:
	var dir := floor_dir(floor_id)
	return "" if dir.is_empty() else dir.path_join(MANIFEST_NAME)

static func layout_path(floor_id: StringName) -> String:
	var dir := floor_dir(floor_id)
	return "" if dir.is_empty() else dir.path_join(LAYOUT_NAME)

## Rejects ids that are empty, dot-relative, or contain characters that
## are unsafe in directory names.
static func _sanitize_floor_id(floor_id: StringName) -> String:
	var id := String(floor_id)
	if id.is_empty() or id.begins_with("."):
		return ""
	for index in id.length():
		var code := id.unicode_at(index)
		# Control chars plus / \ : * ? " < > | — the Windows-hostile set.
		if code < 32 or code == 47 or code == 92 or code == 58 or code == 42 or code == 63 or code == 34 or code == 60 or code == 62 or code == 124:
			return ""
	return id

# ------------------------------------------------------------------
# Manifest
# ------------------------------------------------------------------

## Writes floor.json for the floor. Called by FloorManager only after
## every room/connection/player file for the floor has been written
## successfully, so a valid manifest means the save set is complete.
static func save_manifest(floor_def: Floor) -> Error:
	if floor_def == null:
		push_error("FloorSaveSystem.save_manifest requires a Floor.")
		return ERR_INVALID_PARAMETER
	var dir := floor_dir(floor_def.floor_id)
	if dir.is_empty():
		push_error("FloorSaveSystem: floor id '%s' cannot be used as a save directory." % floor_def.floor_id)
		return ERR_INVALID_PARAMETER
	if DirAccess.make_dir_recursive_absolute(dir) != OK:
		push_error("FloorSaveSystem could not create floor save dir '%s'." % dir)
		return ERR_CANT_CREATE
	var path := dir.path_join(MANIFEST_NAME)
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		push_error("FloorSaveSystem could not open '%s': %s" % [path, error_string(FileAccess.get_open_error())])
		return FileAccess.get_open_error()
	file.store_string(JSON.stringify({
		"version": VERSION,
		"floor_save": true,
		"floor_id": String(floor_def.floor_id),
		"display_name": floor_def.display_name,
		"metadata": floor_def.metadata,
		"saved_at": Time.get_unix_time_from_system(),
	}, "\t"))
	file.close()
	return OK

## Inspects a floor's saved data without touching the world.
## Returns {"status", "data", "reasons"} where status is:
##   "none"    — no manifest; the floor has never been saved
##   "ok"      — manifest is valid and belongs to this floor
##   "corrupt" — a manifest exists but is unreadable, wrong version,
##               belongs to a different floor, or is not a floor save
## A corrupt manifest must never be silently overwritten: callers
## abort the operation and preserve existing data.
static func check_save(floor_id: StringName) -> Dictionary:
	var result := {"status": "none", "data": {}, "reasons": []}
	var path := manifest_path(floor_id)
	if path.is_empty():
		result["status"] = "corrupt"
		result["reasons"] = ["floor id cannot be used as a save directory"]
		return result
	if not FileAccess.file_exists(path):
		return result
	var reasons: Array[String] = []
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		reasons.append("cannot open manifest: %s" % error_string(FileAccess.get_open_error()))
		result["status"] = "corrupt"
		result["reasons"] = reasons
		return result
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	file.close()
	if not (parsed is Dictionary):
		reasons.append("manifest is not valid JSON")
	else:
		var data: Dictionary = parsed
		var version: Variant = data.get("version")
		if not _is_int_like(version) or int(version) != VERSION:
			reasons.append("unsupported manifest version (expected %d)" % VERSION)
		if data.get("floor_save") != true:
			reasons.append("file is not a floor save manifest")
		var saved_id := str(data.get("floor_id", ""))
		if saved_id != String(floor_id):
			reasons.append("manifest belongs to floor '%s', not '%s'" % [saved_id, floor_id])
		if reasons.is_empty():
			result["status"] = "ok"
			result["data"] = data
	if not reasons.is_empty():
		result["status"] = "corrupt"
		result["reasons"] = reasons
	return result

## True when the floor has a valid saved state (manifest present and
## compatible). Corrupt saves report false here; use check_save() to
## distinguish "never saved" from "corrupt".
static func has_save(floor_id: StringName) -> bool:
	return String(check_save(floor_id)["status"]) == "ok"

static func _is_int_like(value: Variant) -> bool:
	return (value is int or value is float) and float(value) == floorf(float(value))

# ------------------------------------------------------------------
# Layout overrides (user-created floor edits)
# ------------------------------------------------------------------
##
## Floor definitions ship as res:// .tres resources which must never be
## modified at runtime. Creation Mode edits are persisted separately as
## layout.json inside the floor's user:// save directory; FloorManager
## applies it over the resource specs whenever the floor loads.
##
## The file stores room SPECS only (id, global origin, size, optional
## RoomDefinition path, floor colors). Room contents keep using the
## standard room_*.json files — this is a definition overlay, not a
## second serializer.

## Writes the floor's current room specs as its layout override.
static func save_layout(floor_def: Floor) -> Error:
	if floor_def == null:
		push_error("FloorSaveSystem.save_layout requires a Floor.")
		return ERR_INVALID_PARAMETER
	var dir := floor_dir(floor_def.floor_id)
	if dir.is_empty():
		push_error("FloorSaveSystem: floor id '%s' cannot be used as a save directory." % floor_def.floor_id)
		return ERR_INVALID_PARAMETER
	if DirAccess.make_dir_recursive_absolute(dir) != OK:
		push_error("FloorSaveSystem could not create floor save dir '%s'." % dir)
		return ERR_CANT_CREATE
	var entries: Array = []
	for spec in floor_def.rooms:
		if spec == null:
			continue
		var entry := {
			"room_id": [spec.room_id.x, spec.room_id.y],
			"global_origin": [spec.global_origin.x, spec.global_origin.y],
			"size": [spec.size.x, spec.size.y],
			"definition": spec.room_definition.resource_path if spec.room_definition != null else "",
			"floor_colors": [],
			"show_from_outside": spec.show_from_outside,
			"show_outside": spec.show_outside,
		}
		for color in spec.floor_colors:
			entry["floor_colors"].append(color.to_html())
		entries.append(entry)
	var path := dir.path_join(LAYOUT_NAME)
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		push_error("FloorSaveSystem could not open '%s': %s" % [path, error_string(FileAccess.get_open_error())])
		return FileAccess.get_open_error()
	file.store_string(JSON.stringify({
		"version": VERSION,
		"floor_save": true,
		"floor_id": String(floor_def.floor_id),
		"entry_room_id": [floor_def.entry_room_id.x, floor_def.entry_room_id.y],
		"spawn_position": [floor_def.spawn_position.x, floor_def.spawn_position.y],
		"rooms": entries,
	}, "\t"))
	file.close()
	return OK

## Reads the floor's layout override. Returns {"rooms": [...]} with raw
## entry dictionaries, or {} when no override exists. A missing or
## invalid file is reported with push_warning and treated as "no
## override" — it never blocks floor loading and is never deleted.
static func load_layout(floor_id: StringName) -> Dictionary:
	var path := layout_path(floor_id)
	if path.is_empty() or not FileAccess.file_exists(path):
		return {}
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		push_warning("FloorSaveSystem could not open layout '%s': %s" % [path, error_string(FileAccess.get_open_error())])
		return {}
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	file.close()
	if not (parsed is Dictionary):
		push_warning("FloorSaveSystem layout '%s' is not valid JSON; ignoring." % path)
		return {}
	var data: Dictionary = parsed
	if data.get("floor_id") != String(floor_id):
		push_warning("FloorSaveSystem layout '%s' belongs to floor '%s', not '%s'; ignoring." % [
			path, str(data.get("floor_id", "")), floor_id])
		return {}
	var entries: Variant = data.get("rooms")
	if not (entries is Array):
		push_warning("FloorSaveSystem layout '%s' has no rooms array; ignoring." % path)
		return {}
	return {
		"rooms": entries,
		"entry_room_id": data.get("entry_room_id"),
		"spawn_position": data.get("spawn_position"),
	}
