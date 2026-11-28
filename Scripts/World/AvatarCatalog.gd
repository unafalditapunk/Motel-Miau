class_name AvatarCatalog
extends RefCounted

## Auto-discovers playable characters under
## res://Assets/Characters/<race>/<variant>/. Adding a new race or
## variant is pure content: drop the folder in with the expected
## structure and it appears in the avatar menu — no code or catalog
## edits required.
##
## Expected layout per variant:
##   rotations/<dir>.png        — 4 idle sprites, one per facing
##   animations/Walking/<dir>/  — optional walk cycles (frame_*.png);
##                                east directions may be omitted, the
##                                player mirrors the west frames
##
## A variant is "ready" when all four rotation files exist; variants
## without art are still listed (disabled in the UI) so upcoming
## content is visible. The active selection persists in
## user://avatar_selection.json.

const CHARACTERS_ROOT := "res://Assets/Characters"
const SELECTION_PATH := "user://avatar_selection.json"
## Active selection file. Tests redirect this to a scratch path so
## they never touch the player's real avatar preference.
static var selection_path := SELECTION_PATH
const SELECTION_VERSION := 1

## Rotation file names, one per facing. The Player maps these onto its
## directional sprite exports; kept here so the catalog and Player
## agree on the on-disk convention.
const ROTATION_FILES := {
	"south-east": "sprite_down_right",
	"north-west": "sprite_up_left",
	"south-west": "sprite_down_left",
	"north-east": "sprite_up_right",
}

static var _cache := {}

## Rescans the characters root and returns
## {"races": [{id, name, variants: [avatar_id, ...]}], "by_id": {id: entry}}.
## Races and variants are sorted by display name for a stable menu.
static func scan() -> Dictionary:
	if not _cache.is_empty():
		return _cache
	_cache = _build_scan()
	return _cache

## Forces a rescan on next scan() — call after adding character art
## while the game is running.
static func refresh() -> void:
	_cache = {}

static func _build_scan() -> Dictionary:
	var by_id := {}
	var races := {}
	var root := DirAccess.open(CHARACTERS_ROOT)
	if root == null:
		return {"races": [], "by_id": by_id}
	root.list_dir_begin()
	var race_dir := root.get_next()
	while race_dir != "":
		if root.current_is_dir() and not race_dir.begins_with("."):
			_scan_race(race_dir, by_id, races)
		race_dir = root.get_next()
	root.list_dir_end()
	var race_list: Array = []
	for race_id in races:
		var race: Dictionary = races[race_id]
		race["variants"].sort_custom(func(a: String, b: String) -> bool:
			return by_id[a]["variant_name"] < by_id[b]["variant_name"])
		race_list.append(race)
	race_list.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return a["name"] < b["name"])
	return {"races": race_list, "by_id": by_id}

static func _scan_race(race_id: String, by_id: Dictionary, races: Dictionary) -> void:
	var race_path := "%s/%s" % [CHARACTERS_ROOT, race_id]
	var race_access := DirAccess.open(race_path)
	if race_access == null:
		return
	var variants: Array = []
	if not races.has(race_id):
		races[race_id] = {"id": race_id, "name": _pretty(race_id), "variants": variants}
	else:
		variants = races[race_id]["variants"]
	race_access.list_dir_begin()
	var variant_dir := race_access.get_next()
	while variant_dir != "":
		if race_access.current_is_dir() and not variant_dir.begins_with("."):
			var entry: Variant = _scan_variant(race_id, variant_dir)
			if entry != null:
				by_id[entry["id"]] = entry
				variants.append(entry["id"])
		variant_dir = race_access.get_next()
	race_access.list_dir_end()

static func _scan_variant(race_id: String, variant_id: String) -> Variant:
	var root := "%s/%s/%s" % [CHARACTERS_ROOT, race_id, variant_id]
	var missing: Array[String] = []
	var rotations := {}
	var preview: Texture2D = null
	for dir_name in ROTATION_FILES:
		var path := "%s/rotations/%s.png" % [root, dir_name]
		# ResourceLoader.exists first: load() logs an engine error for
		# every missing file, which floods the console for art-less
		# placeholder variants.
		var texture: Texture2D = null
		if ResourceLoader.exists(path):
			texture = load(path) as Texture2D
		if texture == null:
			missing.append("rotations/%s.png" % dir_name)
		else:
			rotations[dir_name] = texture
			if dir_name == "south-east" or preview == null:
				preview = texture
	var ready := missing.is_empty()
	if not DirAccess.dir_exists_absolute("%s/animations/Walking" % root):
		missing.append("animations/Walking/")
	return {
		"id": "%s/%s" % [race_id, variant_id],
		"root": root,
		"race_id": race_id,
		"variant_id": variant_id,
		"race_name": _pretty(race_id),
		"variant_name": _pretty(variant_id),
		"display_name": "%s %s" % [_pretty(variant_id), _pretty(race_id)],
		"preview": preview,
		"ready": ready,
		"rotations": rotations,
		"missing": missing,
	}

## "new-era"/"crybaby"/"cat" -> "New Era"/"Crybaby"/"Cat".
static func _pretty(folder: String) -> String:
	var words := folder.replace("_", " ").replace("-", " ").split(" ", false)
	var parts: Array[String] = []
	for word in words:
		parts.append(word.capitalize())
	return " ".join(parts)

# ------------------------------------------------------------------
# Lookups
# ------------------------------------------------------------------

static func find(avatar_id: StringName) -> Variant:
	return scan()["by_id"].get(String(avatar_id))

## Character root path for an avatar id, or "" when unknown.
static func root_for(avatar_id: StringName) -> String:
	var entry: Variant = find(avatar_id)
	return String(entry.get("root", "")) if entry is Dictionary else ""

## Avatar id ("race/variant") for a character root path, or &"".
static func id_for_root(root_path: String) -> StringName:
	for avatar_id in scan()["by_id"]:
		var entry: Dictionary = scan()["by_id"][avatar_id]
		if entry["root"] == root_path:
			return StringName(avatar_id)
	return &""

## First ready variant in scan order — the fallback when nothing is
## selected or the saved choice no longer exists.
static func default_id() -> StringName:
	for race in scan()["races"]:
		for avatar_id in race["variants"]:
			var entry: Dictionary = scan()["by_id"][avatar_id]
			if entry["ready"]:
				return StringName(avatar_id)
	return &""

# ------------------------------------------------------------------
# Persisted selection
# ------------------------------------------------------------------

## Saved avatar id, or &"" when unset/unreadable. The id is returned
## raw — callers should check find() before applying it.
static func load_selection() -> StringName:
	if not FileAccess.file_exists(selection_path):
		return &""
	var file := FileAccess.open(selection_path, FileAccess.READ)
	if file == null:
		return &""
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	file.close()
	if not (parsed is Dictionary):
		return &""
	var data: Dictionary = parsed
	if int(data.get("version", 0)) != SELECTION_VERSION:
		return &""
	var avatar_id := String(data.get("avatar_id", ""))
	return StringName(avatar_id) if not avatar_id.is_empty() else &""

static func save_selection(avatar_id: StringName) -> Error:
	var file := FileAccess.open(selection_path, FileAccess.WRITE)
	if file == null:
		return FileAccess.get_open_error()
	file.store_string(JSON.stringify({
		"version": SELECTION_VERSION,
		"avatar_id": String(avatar_id),
	}, "\t"))
	file.close()
	return OK
