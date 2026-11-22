class_name RoomWorldTest
extends Node2D

@onready var room_world: RoomWorld = $RoomWorld
@onready var world_camera: WorldCamera = $RoomWorld/WorldCamera
@onready var debug_hud: DebugHud = $DebugHud

var player: Player

# Temporary test-only floor tints so the nine rooms are visually
# distinguishable. Do NOT port these to the main game.
var _floor_tints: Array[Color] = [
	Color(1.00, 0.96, 0.90),
	Color(0.92, 1.00, 0.94),
	Color(0.90, 0.96, 1.00),
	Color(1.00, 0.90, 0.95),
	Color(0.95, 0.90, 1.00),
	Color(1.00, 1.00, 0.85),
	Color(0.85, 1.00, 1.00),
	Color(1.00, 0.85, 0.85),
	Color(0.90, 0.85, 1.00),
]

func _ready() -> void:
	if room_world == null or room_world.grid == null:
		push_error("RoomWorldTest requires a configured RoomWorld.")
		return
	_build_rooms()
	_spawn_player()

func _room_coordinates() -> Array[Vector2i]:
	var coordinates: Array[Vector2i] = []
	for x in range(-1, 2):
		for y in range(-1, 2):
			coordinates.append(Vector2i(x, y))
	return coordinates

func _build_rooms() -> void:
	var index := 0
	for coordinates in _room_coordinates():
		var room := room_world.create_room(coordinates)
		if room == null:
			push_error("RoomWorldTest failed to create room at %s." % coordinates)
			return
		_tint_room_floor(room, index)
		_populate_room(room, index)
		index += 1

func _tint_room_floor(room: Room, index: int) -> void:
	var tile_layer := room_world.get_tile_layer(room.room_coordinates)
	if tile_layer != null:
		tile_layer.modulate = _floor_tints[index % _floor_tints.size()]

func _populate_room(room: Room, index: int) -> void:
	var block_layer := room.block_layer
	if block_layer == null:
		return
	var offset_x := index % 3
	var offset_y := int(index / 3.0)
	var standard := block_layer.get_definition(&"standard_block")
	var crate := block_layer.get_definition(&"crate")
	if standard != null:
		block_layer.place_block(standard, Vector2i(2 + offset_x, 2 + offset_y), 0.0)
	if crate != null:
		block_layer.place_block(crate, Vector2i(6 + offset_y, 7 + offset_x), 0.0)
	if room_world.furniture_catalog != null:
		var chair := room_world.furniture_catalog.get_definition(&"chair")
		if chair != null:
			block_layer.place_furniture(chair, Vector2i(11 - offset_x, 12 - offset_y), 0.0, (index * 90) % 360)

func _spawn_player() -> void:
	var center_room := room_world.get_room(Vector2i.ZERO)
	if center_room == null or room_world.player_scene == null:
		return
	player = room_world.player_scene.instantiate() as Player
	if player == null:
		push_error("RoomWorldTest player scene must instantiate to a Player.")
		return
	player.grid = room_world.grid
	player.block_layer = center_room.block_layer
	player.room = center_room
	player.room_size = center_room.size
	player.grid_position = Vector2i(7, 7)
	player.elevation = 0.0
	room_world.entity_layer.add_child(player)
	if debug_hud != null:
		debug_hud.player = player
