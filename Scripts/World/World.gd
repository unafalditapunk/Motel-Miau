class_name World
extends Node2D

@export var room_definition: RoomDefinition
@export var furniture_catalog: FurnitureCatalog
@export var block_catalog: BlockCatalog
@export var tile_catalog: TileCatalog
@export var carpet_catalog: CarpetCatalog
@export var player_scene: PackedScene
@export var block_scene: PackedScene
@export var room_scene: PackedScene
@export var debug_coordinates := false

const DEFAULT_ROOM_SCENE := preload("res://Scenes/World/Room.tscn")
const DEBUG_HUD_SCRIPT := preload("res://Scripts/Debug/DebugHud.gd")
const SAVE_KEY := KEY_F5
const LOAD_KEY := KEY_F6

var room: Room
var tile_layer: TileLayer
var carpet_layer: CarpetLayer
var block_layer: BlockLayer
var entity_layer: Node2D
var player: Player

@onready var placement_controller: BlockPlacementController = $BlockPlacementController
@onready var world_camera: WorldCamera = $WorldCamera

func _ready() -> void:
	add_to_group(&"world")
	if room_definition == null:
		push_error("World requires a RoomDefinition.")
		return
	var grid := room_definition.grid
	if grid == null:
		push_error("RoomDefinition '%s' has no IsometricGrid assigned." % room_definition.room_id)
		return
	if furniture_catalog == null or block_catalog == null or player_scene == null or block_scene == null:
		push_error("World is missing required catalogs or scenes.")
		return

	_build_room(grid)
	_build_tile_layer(grid)
	_build_carpet_layer(grid)
	_build_block_layer(grid)
	_load_room_carpets()
	_build_entity_layer()
	_spawn_player(grid)
	_build_debug_hud(grid)
	_wire_placement_controller()
	_try_autoload()

func _exit_tree() -> void:
	_autosave()

func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		_autosave()

func _save_room_name() -> String:
	if room_definition != null and not str(room_definition.room_id).is_empty():
		return str(room_definition.room_id)
	return "room"

func _autosave() -> void:
	if room == null or block_layer == null or not is_instance_valid(room) or not is_instance_valid(block_layer):
		return
	var room_name := _save_room_name()
	if RoomSaveSystem.save_room(self, room_name) == OK:
		print("Room auto-saved to '%s'." % RoomSaveSystem.save_path(room_name))

func _try_autoload() -> void:
	var room_name := _save_room_name()
	var path := RoomSaveSystem.save_path(room_name)
	if FileAccess.file_exists(path) and RoomSaveSystem.load_room(self, room_name):
		print("Room auto-loaded from '%s'." % path)

func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventKey):
		return
	var key_event := event as InputEventKey
	if not key_event.pressed or key_event.echo:
		return
	if key_event.keycode == SAVE_KEY:
		_on_save_requested()
		get_viewport().set_input_as_handled()
	elif key_event.keycode == LOAD_KEY:
		_on_load_requested()
		get_viewport().set_input_as_handled()

func _on_save_requested() -> void:
	save_room()

func save_room() -> Error:
	var room_name := _save_room_name()
	var error := RoomSaveSystem.save_room(self, room_name)
	if error == OK:
		print("Room saved to '%s'." % RoomSaveSystem.save_path(room_name))
	else:
		push_error("Failed to save room (error %d)." % error)
	return error

func _on_load_requested() -> void:
	if RoomSaveSystem.load_room(self):
		print("Room loaded successfully.")
	else:
		push_error("Failed to load room.")

func _build_room(grid: IsometricGrid) -> void:
	var scene := room_scene if room_scene != null else DEFAULT_ROOM_SCENE
	room = scene.instantiate() as Room
	if room == null:
		push_error("Room scene must instantiate to a Room.")
		return
	room.name = "Room"
	room.grid = grid
	room.size = room_definition.size
	room.floor_texture = room_definition.floor_texture
	room.default_tile = _resolve_default_tile()
	room.debug_coordinates = debug_coordinates
	add_child(room)

func _resolve_default_tile() -> TileDefinition:
	if room_definition == null or room_definition.default_tile_id == &"":
		return null
	if tile_catalog == null:
		push_warning("World: room_definition '%s' sets default_tile_id but no TileCatalog is assigned." % room_definition.room_id)
		return null
	var definition := tile_catalog.get_definition(room_definition.default_tile_id)
	if definition == null:
		push_warning("World: no tile definition found for id '%s'." % room_definition.default_tile_id)
	return definition

func _build_tile_layer(grid: IsometricGrid) -> void:
	tile_layer = TileLayer.new()
	tile_layer.name = "TileLayer"
	tile_layer.grid = grid
	tile_layer.room = room
	add_child(tile_layer)

func _build_carpet_layer(grid: IsometricGrid) -> void:
	carpet_layer = CarpetLayer.new()
	carpet_layer.name = "CarpetLayer"
	carpet_layer.grid = grid
	carpet_layer.room = room
	add_child(carpet_layer)

func _load_room_carpets() -> void:
	if room_definition == null or room == null:
		return
	for placement_resource in room_definition.carpet_placements:
		var placement := placement_resource as CarpetPlacement
		if placement == null:
			push_error("Invalid carpet placement in RoomDefinition.")
			continue
		var definition := carpet_catalog.get_definition(placement.carpet_id) if carpet_catalog != null else null
		if definition == null:
			push_error("Missing carpet definition for id: " + str(placement.carpet_id))
			continue
		room.place_carpet(definition, placement.grid_position, placement.rotation_degrees, false, placement.elevation)

func _build_block_layer(grid: IsometricGrid) -> void:
	block_layer = BlockLayer.new()
	block_layer.name = "BlockLayer"
	block_layer.grid = grid
	block_layer.room_size = room_definition.size
	block_layer.block_scene = block_scene
	block_layer.block_catalog = block_catalog
	block_layer.furniture_catalog = furniture_catalog
	block_layer.furniture_placements = room_definition.furniture_placements
	add_child(block_layer)
	if room != null:
		room.block_layer = block_layer

func _build_entity_layer() -> void:
	entity_layer = Node2D.new()
	entity_layer.name = "EntityLayer"
	entity_layer.y_sort_enabled = false
	add_child(entity_layer)

func _spawn_player(grid: IsometricGrid) -> void:
	if entity_layer == null:
		return
	var spawned := player_scene.instantiate() as Player
	if spawned == null:
		push_error("Player scene must instantiate to a Player.")
		return
	player = spawned
	player.grid = grid
	player.block_layer = block_layer
	player.room_size = room_definition.size
	player.grid_position = room_definition.spawn_position
	player.elevation = 0.0
	entity_layer.add_child(player)

func _build_debug_hud(grid: IsometricGrid) -> void:
	var hud: DebugHud = DEBUG_HUD_SCRIPT.new()
	hud.name = "DebugHud"
	hud.player = player
	hud.grid = grid
	add_child(hud)

func _wire_placement_controller() -> void:
	var selector := get_node_or_null(^"BuildingSelector") as BuildingSelector
	if placement_controller != null:
		placement_controller.block_layer = block_layer
		placement_controller.room = room
		placement_controller.building_selector = selector
	var catalog_panel := get_node_or_null(^"CatalogPanel") as CatalogPanel
	var toolbar := get_node_or_null(^"BuildingToolbar") as BuildingToolbar
	if catalog_panel != null:
		catalog_panel.set_building_selector(selector)
	if toolbar != null:
		toolbar.setup(placement_controller, selector, self, catalog_panel)

