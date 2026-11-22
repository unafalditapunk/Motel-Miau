class_name Main
extends Node2D

const WORLD_SCENE := preload("res://Scenes/World/World.tscn")
const NEIGHBOR_COORDINATES: Array[Vector2i] = [
	Vector2i(-1, -1), Vector2i(0, -1), Vector2i(1, -1),
	Vector2i(-1, 0), Vector2i(1, 0),
	Vector2i(-1, 1), Vector2i(0, 1), Vector2i(1, 1),
]

func _ready() -> void:
	var world := WORLD_SCENE.instantiate() as World
	if world == null:
		push_error("Main: failed to instantiate World scene.")
		return
	add_child(world)
	if world.room == null or world.room.grid == null:
		push_error("Main: World did not build a room.")
		return
	var room_world := RoomWorld.new()
	room_world.name = "RoomWorld"
	_configure_room_world(room_world, world)
	add_child(room_world)
	world.room.reparent(room_world)
	room_world.register_room(world.room, Vector2i.ZERO)
	for room_coordinates in NEIGHBOR_COORDINATES:
		room_world.create_room(room_coordinates)
	world.room_world = room_world
	room_world.load_all_rooms()

func _configure_room_world(room_world: RoomWorld, world: World) -> void:
	room_world.grid = world.room.grid
	room_world.room_dimensions = world.room.size
	room_world.floor_texture = world.room.floor_texture
	room_world.default_tile_id = world.room_definition.default_tile_id if world.room_definition != null else &""
	room_world.debug_coordinates = world.debug_coordinates
	room_world.tile_catalog = world.tile_catalog
	room_world.block_catalog = world.block_catalog
	room_world.furniture_catalog = world.furniture_catalog
	room_world.carpet_catalog = world.carpet_catalog
	room_world.block_scene = world.block_scene
