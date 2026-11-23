class_name BlockPlacementController
extends Node

signal construction_mode_changed(enabled: bool)

const EPSILON := 0.001

@export var block_layer_path: NodePath
@export var room_path: NodePath
@export var block_id: StringName = &"standard_block"
@export var place_on_right_click := true
@export var remove_on_left_click := true
@export var construction_mode := false:
	set(value):
		if construction_mode == value:
			return
		construction_mode = value
		construction_mode_changed.emit(value)
@export var toggle_key := KEY_E
@export var rotate_key := KEY_R
@export var flip_key := KEY_T
@export var building_selector: BuildingSelector:
	set(value):
		if building_selector != null and building_selector.selection_changed.is_connected(_on_selection_changed):
			building_selector.selection_changed.disconnect(_on_selection_changed)
		building_selector = value
		if building_selector != null:
			building_selector.selection_changed.connect(_on_selection_changed)
			_on_selection_changed(building_selector.selected_definition)

var block_layer: BlockLayer
var room: Room
var selected_definition: PlaceableDefinition
var rotation_degrees := 0
var flipped := false
var _player: Player

func _ready() -> void:
	add_to_group(&"block_placement_controller")
	if not block_layer_path.is_empty():
		block_layer = get_node_or_null(block_layer_path) as BlockLayer
	if not room_path.is_empty():
		room = get_node_or_null(room_path) as Room

func _process(_delta: float) -> void:
	var tree := get_tree()
	if tree == null:
		return
	if _player == null or not is_instance_valid(_player):
		_player = tree.get_first_node_in_group(&"player") as Player
	if _player == null:
		return
	var target_room := _player.room
	if target_room == null or target_room == room:
		return
	_bind_room(target_room)

func _bind_room(new_room: Room) -> void:
	room = new_room
	block_layer = new_room.block_layer if new_room != null else null

func _unhandled_input(event: InputEvent) -> void:
	# Modal world UI (FloorPanel) and Creation Mode suspend all building
	# interaction. Events are left unhandled so F-keys and other UI
	# shortcuts keep working.
	if FloorPanel.any_open(get_tree()) or FloorEditor.any_active(get_tree()):
		return
	if event is InputEventKey:
		var key_event := event as InputEventKey
		if not key_event.pressed or key_event.echo:
			return
		if key_event.keycode == toggle_key:
			construction_mode = not construction_mode
			get_viewport().set_input_as_handled()
			return
		if key_event.keycode == rotate_key:
			_rotate_selection()
			get_viewport().set_input_as_handled()
			return
		if key_event.keycode == flip_key:
			_flip_selection()
			get_viewport().set_input_as_handled()
			return
	if not (event is InputEventMouseButton):
		return
	var mouse_button := event as InputEventMouseButton
	if not mouse_button.pressed:
		return
	if mouse_button.button_index == MOUSE_BUTTON_RIGHT and place_on_right_click:
		if try_place_at_mouse():
			get_viewport().set_input_as_handled()
	elif mouse_button.button_index == MOUSE_BUTTON_LEFT and remove_on_left_click:
		if try_remove_at_mouse():
			get_viewport().set_input_as_handled()

func try_place_at_mouse() -> bool:
	if not construction_mode:
		return false
	if block_layer == null or room == null or room.grid == null:
		return false
	var world_position := get_viewport().get_canvas_transform().affine_inverse() * get_viewport().get_mouse_position()
	var coordinates := room.grid.screen_to_grid(world_position) - room.cell_origin
	if not room.grid.is_valid(coordinates, room.size):
		return false
	return place_at(coordinates)

func place_at(coordinates: Vector2i) -> bool:
	if block_layer == null or room == null or room.grid == null:
		return false
	if not room.grid.is_valid(coordinates, room.size):
		return false
	var definition := _resolve_definition()
	if definition == null:
		push_error("BlockPlacementController: no object selected.")
		return false
	var net := _net_manager()
	var net_client := net != null and net.mode == MultiplayerManager.Mode.CLIENT
	# Phase B1: on a multiplayer client ONLY plain block placement is
	# synchronized. Tiles, carpets and furniture would mutate the local
	# replica without server authority — refuse them outright.
	if net_client and not (definition is BlockDefinition):
		return false
	if definition is TileDefinition:
		return room.set_cell_tile(coordinates, definition, block_layer.get_top_z_at(coordinates))
	if definition is CarpetDefinition:
		return room.place_carpet(definition, coordinates, rotation_degrees, flipped, block_layer.get_top_z_at(coordinates))
	if _is_player_cell(coordinates):
		return false
	var elevation := block_layer.get_top_z_at(coordinates)
	var placed: Block = null
	if definition is FurnitureDefinition:
		placed = block_layer.place_furniture(definition, coordinates, elevation, rotation_degrees)
	elif definition is BlockDefinition:
		if net_client:
			return net.request_build_place(room.room_coordinates,
				coordinates, definition.object_id, flipped)
		placed = block_layer.place_block(definition, coordinates, elevation)
	else:
		push_error("BlockPlacementController: unsupported definition type for '%s'." % definition.object_id)
		return false
	if placed != null:
		_apply_flip(placed)
	return placed != null

func place_block_at(coordinates: Vector2i) -> bool:
	return place_at(coordinates)

func try_remove_at_mouse() -> bool:
	if not construction_mode:
		return false
	if block_layer == null or room == null or room.grid == null:
		return false
	var world_position := get_viewport().get_canvas_transform().affine_inverse() * get_viewport().get_mouse_position()
	var coordinates := room.grid.screen_to_grid(world_position) - room.cell_origin
	if not room.grid.is_valid(coordinates, room.size):
		return false
	return remove_at(coordinates)

func remove_at(coordinates: Vector2i) -> bool:
	if block_layer == null or room == null:
		return false
	if _is_player_cell(coordinates):
		return false
	var cell := room.get_cell(coordinates)
	var kind := 0
	var best_z := -INF
	var best_priority := -1
	var top_block: Block = null
	var block_z := -INF
	for block in block_layer.get_blocks_at(coordinates):
		if block.top_z() > block_z:
			block_z = block.top_z()
			top_block = block
	if top_block != null:
		kind = 1
		best_z = block_z
		best_priority = 0
	if cell != null and cell.tile != null:
		var tile_z := cell.tile_elevation
		if _is_above(tile_z, 1, best_z, best_priority):
			kind = 2
			best_z = tile_z
			best_priority = 1
	if cell != null and cell.carpet != null:
		var carpet_z := cell.carpet_elevation
		if _is_above(carpet_z, 2, best_z, best_priority):
			kind = 3
			best_z = carpet_z
			best_priority = 2
	if kind == 3:
		# Carpet removal is not synchronized yet (Phase B1 scope).
		return not _is_net_client() and room.clear_cell_carpet(coordinates)
	if kind == 2:
		# Tile removal is not synchronized yet (Phase B1 scope).
		return not _is_net_client() and room.clear_cell_tile(coordinates)
	if kind == 1 and top_block != null:
		if _is_net_client():
			# Only plain blocks sync; furniture stays local-only for now.
			if top_block.block_definition == null:
				return false
			var net := _net_manager()
			return net != null and net.request_build_remove(
				room.room_coordinates, coordinates,
				StringName(top_block.block_id), top_block.grid_position,
				top_block.elevation)
		block_layer.remove_block(top_block)
		return true
	return false

func _is_above(z: float, priority: int, best_z: float, best_priority: int) -> bool:
	if z > best_z + EPSILON:
		return true
	return absf(z - best_z) <= EPSILON and priority > best_priority

func remove_block_at(coordinates: Vector2i) -> bool:
	return remove_at(coordinates)

func get_active_definition() -> PlaceableDefinition:
	return _resolve_definition()

func _resolve_definition() -> PlaceableDefinition:
	if selected_definition != null:
		return selected_definition
	if block_layer != null:
		return block_layer.get_definition(block_id)
	return null

func _on_selection_changed(definition: PlaceableDefinition) -> void:
	selected_definition = definition
	rotation_degrees = building_selector.rotation_degrees if building_selector != null else 0
	flipped = building_selector.flipped if building_selector != null else flipped

func _rotate_selection() -> void:
	if building_selector != null:
		building_selector.rotate()
	else:
		rotation_degrees = posmod(rotation_degrees + 90, 360)

func _flip_selection() -> void:
	if building_selector != null:
		building_selector.flip()
	else:
		flipped = not flipped

func _apply_flip(block: Block) -> void:
	if not flipped:
		return
	var sprite := block.get_node_or_null(^"Sprite") as Sprite2D
	if sprite != null:
		sprite.flip_h = true

func _net_manager() -> MultiplayerManager:
	return get_tree().get_first_node_in_group(&"multiplayer_manager") as MultiplayerManager

func _is_net_client() -> bool:
	var net := _net_manager()
	return net != null and net.mode == MultiplayerManager.Mode.CLIENT

func _is_player_cell(coordinates: Vector2i) -> bool:
	var player := get_tree().get_first_node_in_group(&"player") as Player
	if player == null:
		return false
	if room != null:
		coordinates += room.cell_origin
	if player.room != null:
		return player.room.world_cell_coordinates(player.grid_position) == coordinates
	return player.grid_position == coordinates
