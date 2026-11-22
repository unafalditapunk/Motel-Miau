class_name RoomWorld
extends Node2D

const DEFAULT_ROOM_SCENE := preload("res://Scenes/World/Room.tscn")
const ROOM_LABEL_SCRIPT := preload("res://Scripts/World/RoomLabel.gd")
const NEIGHBOR_DEEMPHASIS_SHADER := preload("res://Shaders/NeighborDeemphasis.gdshader")

@export var grid: IsometricGrid
@export var room_scene: PackedScene
@export var room_dimensions := Vector2i(16, 16)
@export var default_tile_id: StringName
@export var floor_texture: Texture2D
@export var debug_coordinates := false
@export var show_room_labels := false
@export var room_label_color := Color(1.0, 1.0, 1.0, 0.85)
@export var block_scene: PackedScene
@export var block_catalog: BlockCatalog
@export var furniture_catalog: FurnitureCatalog
@export var tile_catalog: TileCatalog
@export var carpet_catalog: CarpetCatalog
@export var player_scene: PackedScene

@export_group("Primary Room")
@export var primary_room_coordinates := Vector2i.ZERO
@export var deemphasize_neighbors := true
@export var hide_rooms_outside_neighborhood := true
@export var room_slide_duration := 0.22
@export var room_slide_distance := 240.0

@export_group("Neighbor De-Emphasis")
@export var neighbor_saturation := 0.2
@export var neighbor_brightness := 0.65
@export var neighbor_alpha := 1.0
@export var neighbor_blur := 2.0
@export var emphasis_transition_duration := 0.15

var registry := RoomRegistry.new()
var entity_layer: Node2D
var _room_materials: Dictionary = {}
var _emphasis_from: Dictionary = {}
var _emphasis_to: Dictionary = {}
var _emphasis_tween: Tween
var _hydrated_rooms: Dictionary = {}
var _room_home: Dictionary = {}
var _room_slide: Dictionary = {}

func _ready() -> void:
	add_to_group(&"room_worlds")
	entity_layer = Node2D.new()
	entity_layer.name = "EntityLayer"
	entity_layer.y_sort_enabled = false
	add_child(entity_layer)
	if grid == null:
		push_error("RoomWorld requires an IsometricGrid resource.")

func room_cell_origin(room_coordinates: Vector2i, room_size := Vector2i.ZERO) -> Vector2i:
	var dimensions := room_size if room_size != Vector2i.ZERO else room_dimensions
	return Vector2i(room_coordinates.x * dimensions.x, room_coordinates.y * dimensions.y)

func room_screen_offset(room_coordinates: Vector2i, room_size := Vector2i.ZERO) -> Vector2:
	if grid == null:
		return Vector2.ZERO
	var cell_origin := room_cell_origin(room_coordinates, room_size)
	return grid.grid_to_screen(cell_origin) - grid.grid_to_screen(Vector2i.ZERO)

func register_room(room: Room, room_coordinates: Vector2i) -> bool:
	if grid == null:
		push_error("RoomWorld requires an IsometricGrid before registering rooms.")
		return false
	if room == null:
		push_error("RoomWorld.register_room requires a Room.")
		return false
	if room.size.x <= 0 or room.size.y <= 0:
		push_error("Room '%s' has invalid size %s." % [room.name, room.size])
		return false
	if room.get_parent() != null and room.get_parent() != self:
		push_error("Room '%s' already has parent '%s'; add it to this RoomWorld first." % [room.name, room.get_parent().name])
		return false
	if not registry.register(room, room_coordinates):
		return false

	room.room_coordinates = room_coordinates
	room.cell_origin = room_cell_origin(room_coordinates, room.size)
	room.position = room_screen_offset(room_coordinates, room.size)
	_room_home[room] = room.position
	if room.get_parent() == null:
		add_child(room)
	ensure_room_layers(room)
	if show_room_labels:
		_apply_room_label(room)
	_apply_room_emphasis(room)
	return true

func unregister_room(room_coordinates: Vector2i) -> bool:
	var room := get_room(room_coordinates)
	if room != null:
		_kill_room_slide(room)
		_room_materials.erase(room)
		_room_home.erase(room)
	return registry.unregister(room_coordinates)

func get_room(room_coordinates: Vector2i) -> Room:
	return registry.get_room(room_coordinates)

func has_room(room_coordinates: Vector2i) -> bool:
	return registry.has_room(room_coordinates)

func get_rooms() -> Array[Room]:
	return registry.get_rooms()

func create_room(room_coordinates: Vector2i, size := Vector2i.ZERO, floor_colors: Array[Color] = []) -> Room:
	var dimensions := size if size != Vector2i.ZERO else room_dimensions
	if dimensions.x <= 0 or dimensions.y <= 0:
		push_error("RoomWorld.create_room requires a positive room size.")
		return null
	var scene := room_scene if room_scene != null else DEFAULT_ROOM_SCENE
	var room := scene.instantiate() as Room
	if room == null:
		push_error("Room scene must instantiate to a Room.")
		return null
	room.name = _room_node_name(room_coordinates)
	room.grid = grid
	room.size = dimensions
	room.floor_texture = floor_texture
	room.default_tile = _resolve_default_tile()
	if not floor_colors.is_empty():
		room.floor_colors = floor_colors
	room.debug_coordinates = debug_coordinates
	add_child(room)
	if not register_room(room, room_coordinates):
		room.queue_free()
		return null
	return room

func ensure_room_layers(room: Room) -> void:
	if room == null or grid == null:
		return

	var tile_layer := room.get_node_or_null(^"TileLayer") as TileLayer
	var tile_layer_is_new := tile_layer == null
	if tile_layer_is_new:
		tile_layer = TileLayer.new()
		tile_layer.name = "TileLayer"
	tile_layer.grid = grid
	tile_layer.room = room
	tile_layer.cell_origin = room.cell_origin
	tile_layer.compact_depth = true
	if tile_layer_is_new:
		room.add_child(tile_layer)

	var carpet_layer := room.get_node_or_null(^"CarpetLayer") as CarpetLayer
	var carpet_layer_is_new := carpet_layer == null
	if carpet_layer_is_new:
		carpet_layer = CarpetLayer.new()
		carpet_layer.name = "CarpetLayer"
	carpet_layer.grid = grid
	carpet_layer.room = room
	carpet_layer.cell_origin = room.cell_origin
	carpet_layer.compact_depth = true
	if carpet_layer_is_new:
		room.add_child(carpet_layer)

	var block_layer := room.get_node_or_null(^"BlockLayer") as BlockLayer
	var block_layer_is_new := block_layer == null
	if block_layer_is_new:
		block_layer = BlockLayer.new()
		block_layer.name = "BlockLayer"
	block_layer.grid = grid
	block_layer.room = room
	block_layer.room_size = room.size
	block_layer.cell_origin = room.cell_origin
	block_layer.compact_depth = true
	block_layer.block_scene = block_scene
	block_layer.block_catalog = block_catalog
	block_layer.furniture_catalog = furniture_catalog
	if block_layer_is_new:
		room.add_child(block_layer)
	room.block_layer = block_layer
	block_layer.refresh_depths()
	if room.is_node_ready():
		room._notify_changed()

func get_tile_layer(room_coordinates: Vector2i) -> TileLayer:
	var room := get_room(room_coordinates)
	if room == null:
		return null
	return room.get_node_or_null(^"TileLayer") as TileLayer

func get_carpet_layer(room_coordinates: Vector2i) -> CarpetLayer:
	var room := get_room(room_coordinates)
	if room == null:
		return null
	return room.get_node_or_null(^"CarpetLayer") as CarpetLayer

func get_block_layer(room_coordinates: Vector2i) -> BlockLayer:
	var room := get_room(room_coordinates)
	if room == null:
		return null
	return room.get_node_or_null(^"BlockLayer") as BlockLayer

func get_room_at_world_cell(world_cell: Vector2i) -> Room:
	for room in registry.get_rooms():
		var local_cell := world_cell - room.cell_origin
		if local_cell.x >= 0 and local_cell.y >= 0 and local_cell.x < room.size.x and local_cell.y < room.size.y:
			return room
	return null

# ------------------------------------------------------------------
# Room state persistence
# ------------------------------------------------------------------

## Loads the room's saved state the first time it is needed. Rooms without
## a save file keep their current (freshly created) contents.
func ensure_room_loaded(room: Room) -> bool:
	if room == null:
		return false
	var coordinates := room.room_coordinates
	if _hydrated_rooms.has(coordinates):
		return true
	_hydrated_rooms[coordinates] = true
	if RoomSaveSystem.room_state_candidates(coordinates, room.size).is_empty():
		return false
	return RoomSaveSystem.load_room_world_room(self, room)

## Forgets that a room was hydrated so its save is reloaded on next ensure.
func reset_room_state(room: Room) -> void:
	if room != null:
		_hydrated_rooms.erase(room.room_coordinates)

func save_room_state(room: Room) -> Error:
	return RoomSaveSystem.save_room_world_room(self, room)

## Saves every registered room plus the player's current room/position.
func save_all_rooms() -> void:
	var saved := 0
	for room in registry.get_rooms():
		var error := save_room_state(room)
		if error == OK:
			saved += 1
		else:
			push_error("RoomWorld failed to save room %s (error %d)." % [room.room_coordinates, error])
	var player := _player()
	if player != null and player.room != null:
		var error := RoomSaveSystem.save_player_state(player.room.room_coordinates, player.grid_position, player.elevation)
		if error != OK:
			push_error("RoomWorld failed to save player state (error %d)." % error)
	print("RoomWorld saved %d room(s) to '%s'." % [saved, RoomSaveSystem.SAVE_DIR])

## Loads every registered room's saved state (when present) and restores
## the player's saved room and position.
func load_all_rooms() -> void:
	_hydrated_rooms.clear()
	var loaded := 0
	for room in registry.get_rooms():
		if ensure_room_loaded(room):
			loaded += 1
	_apply_saved_player_state()
	print("RoomWorld loaded %d room(s) from '%s'." % [loaded, RoomSaveSystem.SAVE_DIR])

func _apply_saved_player_state() -> void:
	var player := _player()
	if player == null:
		return
	var state := RoomSaveSystem.load_player_state()
	if state.is_empty():
		return
	var coordinates: Vector2i = state["room_coordinates"]
	var room := get_room(coordinates)
	if room == null:
		return
	var saved_cell: Vector2i = state["position"]
	if saved_cell.x < 0 or saved_cell.y < 0 or saved_cell.x >= room.size.x or saved_cell.y >= room.size.y:
		saved_cell = Vector2i(room.size.x >> 1, room.size.y >> 1)
	player.room = room
	player.block_layer = room.block_layer
	player.room_size = room.size
	player.place_at(saved_cell, float(state["elevation"]))
	set_primary_room(coordinates)

func _player() -> Player:
	if not is_inside_tree():
		return null
	return get_tree().get_first_node_in_group(&"player") as Player

func get_world_cell_bounds() -> Rect2i:
	var minimum := Vector2i(2147483647, 2147483647)
	var maximum := Vector2i(-2147483647 - 1, -2147483647 - 1)
	var has_rooms := false
	for room in registry.get_rooms():
		has_rooms = true
		var origin := room.cell_origin
		var end := origin + room.size
		minimum = Vector2i(mini(minimum.x, origin.x), mini(minimum.y, origin.y))
		maximum = Vector2i(maxi(maximum.x, end.x), maxi(maximum.y, end.y))
	if not has_rooms:
		return Rect2i()
	return Rect2i(minimum, maximum - minimum)

func _resolve_default_tile() -> TileDefinition:
	if default_tile_id == StringName() or tile_catalog == null:
		return null
	var definition := tile_catalog.get_definition(default_tile_id)
	if definition == null:
		push_warning("RoomWorld: no tile definition found for id '%s'." % default_tile_id)
	return definition

func set_primary_room(room_coordinates: Vector2i) -> void:
	if room_coordinates == primary_room_coordinates:
		return
	primary_room_coordinates = room_coordinates
	_begin_emphasis_transition()

## Re-applies emphasis targets instantly (no transition). Useful after
## changing the neighbor_* exports at runtime.
func refresh_room_emphasis() -> void:
	_kill_emphasis_tween()
	_update_deemphasis_material()
	for room in registry.get_rooms():
		_apply_room_emphasis(room)

func _is_neighbor_room(room_coordinates: Vector2i) -> bool:
	if room_coordinates == primary_room_coordinates:
		return false
	var delta := room_coordinates - primary_room_coordinates
	return absi(delta.x) <= 1 and absi(delta.y) <= 1

func _target_emphasis(room_coordinates: Vector2i) -> float:
	if not deemphasize_neighbors or room_coordinates == primary_room_coordinates:
		return 0.0
	return 1.0

func _apply_room_emphasis(room: Room) -> void:
	if room == null:
		return
	_update_room_visibility(room)
	_set_room_strength(room, _target_emphasis(room.room_coordinates))

func _update_room_visibility(room: Room) -> void:
	var is_primary := room.room_coordinates == primary_room_coordinates
	var is_neighbor := _is_neighbor_room(room.room_coordinates)
	var should_show := is_primary or is_neighbor or not hide_rooms_outside_neighborhood
	var slide: Dictionary = _room_slide.get(room, {})
	var exiting := bool(slide.get("exiting", false))

	if should_show:
		if exiting:
			_kill_room_slide(room)
			room.position = _room_home.get(room, room.position)
		if not room.visible:
			room.visible = true
			if room_slide_duration > 0.0 and is_inside_tree():
				_start_room_slide(room, false)
	elif not exiting:
		if room.visible:
			if room_slide_duration > 0.0 and is_inside_tree():
				_start_room_slide(room, true)
			else:
				room.visible = false

func _start_room_slide(room: Room, exiting: bool) -> void:
	_kill_room_slide(room)
	var home: Vector2 = _room_home.get(room, room.position)
	var target := home + Vector2(0.0, room_slide_distance if exiting else -room_slide_distance)
	if not exiting:
		room.position = target
	room.is_sliding = true
	var tween := create_tween()
	tween.set_trans(Tween.TRANS_QUAD)
	tween.set_ease(Tween.EASE_OUT if not exiting else Tween.EASE_IN)
	tween.tween_property(room, "position", home if not exiting else target, room_slide_duration)
	tween.finished.connect(_on_room_slide_finished.bind(room))
	_room_slide[room] = {"tween": tween, "exiting": exiting}

func _on_room_slide_finished(room: Room) -> void:
	if not is_instance_valid(room):
		for key in _room_slide.keys():
			if not is_instance_valid(key):
				_room_slide.erase(key)
		return
	var slide: Dictionary = _room_slide.get(room, {})
	var exiting := bool(slide.get("exiting", false))
	_room_slide.erase(room)
	room.is_sliding = false
	room.position = _room_home.get(room, room.position)
	if exiting:
		room.visible = false

func _kill_room_slide(room: Room) -> void:
	var slide: Dictionary = _room_slide.get(room, {})
	var tween: Tween = slide.get("tween")
	if tween != null and is_instance_valid(tween):
		tween.kill()
	_room_slide.erase(room)
	if is_instance_valid(room):
		room.is_sliding = false

func _begin_emphasis_transition() -> void:
	_kill_emphasis_tween()
	_emphasis_from.clear()
	_emphasis_to.clear()
	for room in registry.get_rooms():
		if room == null:
			continue
		_update_room_visibility(room)
		_emphasis_from[room] = _current_emphasis(room)
		_emphasis_to[room] = _target_emphasis(room.room_coordinates)
	if emphasis_transition_duration <= 0.0 or not is_inside_tree():
		_apply_emphasis_blend(1.0)
		return
	_emphasis_tween = create_tween()
	_emphasis_tween.tween_method(_apply_emphasis_blend, 0.0, 1.0, emphasis_transition_duration).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)

func _apply_emphasis_blend(t: float) -> void:
	for room in _emphasis_from:
		var from := float(_emphasis_from[room])
		var to := float(_emphasis_to.get(room, from))
		_set_room_strength(room, lerpf(from, to, t))

func _current_emphasis(room: Room) -> float:
	if room == null or room.deemphasis_material == null:
		return 0.0
	var mat := room.deemphasis_material as ShaderMaterial
	if mat == null:
		return 0.0
	var value: Variant = mat.get_shader_parameter(&"strength")
	return float(value) if value != null else 0.0

func _set_room_strength(room: Room, strength: float) -> void:
	if room == null:
		return
	if strength <= 0.001:
		if _room_materials.has(room):
			room.clear_deemphasis()
			_room_materials.erase(room)
		return
	var mat := _ensure_room_material(room)
	mat.set_shader_parameter(&"strength", strength)

func _ensure_room_material(room: Room) -> ShaderMaterial:
	var mat: ShaderMaterial = _room_materials.get(room)
	if mat == null or not is_instance_valid(mat):
		mat = ShaderMaterial.new()
		mat.shader = NEIGHBOR_DEEMPHASIS_SHADER
		_set_deemphasis_params(mat)
		_room_materials[room] = mat
		room.set_deemphasis(mat)
	return mat

func _update_deemphasis_material() -> void:
	for mat in _room_materials.values():
		if is_instance_valid(mat):
			_set_deemphasis_params(mat)

func _set_deemphasis_params(mat: ShaderMaterial) -> void:
	mat.set_shader_parameter(&"saturation", neighbor_saturation)
	mat.set_shader_parameter(&"brightness", neighbor_brightness)
	mat.set_shader_parameter(&"alpha", neighbor_alpha)
	mat.set_shader_parameter(&"blur", neighbor_blur)

func _kill_emphasis_tween() -> void:
	if _emphasis_tween != null and is_instance_valid(_emphasis_tween):
		_emphasis_tween.kill()
	_emphasis_tween = null

func _room_node_name(room_coordinates: Vector2i) -> String:
	return "Room_%d_%d" % [room_coordinates.x, room_coordinates.y]

func _apply_room_label(room: Room) -> void:
	if room.get_node_or_null(^"RoomLabel") != null:
		return
	var label = ROOM_LABEL_SCRIPT.new()
	label.name = "RoomLabel"
	label.text = "(%d, %d)" % [room.room_coordinates.x, room.room_coordinates.y]
	label.position = grid.grid_to_screen_position(Vector2(room.size) * 0.5, 0.0) + Vector2(-12.0, -8.0)
	label.z_as_relative = false
	label.z_index = 4096
	label.color = room_label_color
	room.add_child(label)
