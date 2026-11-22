class_name Main
extends Node2D

const WORLD_SCENE := preload("res://Scenes/World/World.tscn")
## Ring of 4x4 rooms surrounding the 12x12 center room: 5 per long side,
## 3 per short side = 16 rooms. Keys are room ids, values are world-cell
## origins of each room's local (0,0).
const RING_ROOM_SIZE := Vector2i(4, 4)
const RING_LAYOUT := {
	# Top strip (world y -4..-1)
	Vector2i(0, -1): Vector2i(-4, -4),
	Vector2i(1, -1): Vector2i(0, -4),
	Vector2i(2, -1): Vector2i(4, -4),
	Vector2i(3, -1): Vector2i(8, -4),
	Vector2i(4, -1): Vector2i(12, -4),
	# Bottom strip (world y 12..15)
	Vector2i(0, 2): Vector2i(-4, 12),
	Vector2i(1, 2): Vector2i(0, 12),
	Vector2i(2, 2): Vector2i(4, 12),
	Vector2i(3, 2): Vector2i(8, 12),
	Vector2i(4, 2): Vector2i(12, 12),
	# Left column (world x -4..-1)
	Vector2i(-1, 0): Vector2i(-4, 0),
	Vector2i(-1, 1): Vector2i(-4, 4),
	Vector2i(-1, 2): Vector2i(-4, 8),
	# Right column (world x 12..15)
	Vector2i(5, 0): Vector2i(12, 0),
	Vector2i(5, 1): Vector2i(12, 4),
	Vector2i(5, 2): Vector2i(12, 8),
}

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
	for room_id in RING_LAYOUT:
		room_world.create_room_at(room_id, RING_LAYOUT[room_id], RING_ROOM_SIZE)
	world.room_world = room_world
	# Restore saved room contents and any saved connection overrides first,
	# then fill in doors for every edge-adjacent room pair. Saved connections
	# referencing missing rooms are skipped by validation; auto-generated
	# ones duplicate-check cleanly against identical saved entries.
	room_world.load_all_rooms()
	room_world.auto_connect_adjacent_rooms()
	room_world.require_explicit_connections = true

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
