extends Node2D

## Visual test scene: a 16x16 center room surrounded by a ring of twelve
## 8x8 rooms on one shared isometric world grid. Run the scene directly
## (not headless) to inspect the layout.

const GRID_PATH := "res://Resources/IsometricGrid/TestGrid.tres"
const TILE_CATALOG_PATH := "res://Resources/TileCatalog.tres"
const BLOCK_CATALOG_PATH := "res://Resources/BlockCatalog.tres"
const FURNITURE_CATALOG_PATH := "res://Resources/FurnitureCatalog.tres"
const CARPET_CATALOG_PATH := "res://Resources/CarpetCatalog.tres"
const BLOCK_SCENE_PATH := "res://Scenes/Objects/Block.tscn"
const PLAYER_SCENE_PATH := "res://Scenes/Player/Player.tscn"

# room_id -> {origin, size}
# A 16x16 center room at the world origin, fully surrounded by a ring of
# twelve 8x8 rooms (picture frame): 4 on top, 4 on bottom, 2 per side.
const CENTER_ID := Vector2i(0, 0)
const CENTER_ORIGIN := Vector2i(0, 0)
const CENTER_SIZE := Vector2i(16, 16)
const RING_SIZE := Vector2i(8, 8)
const LAYOUT := {
	# Top strip (y -8..-1)
	Vector2i(0, -1): {"origin": Vector2i(-8, -8)},
	Vector2i(1, -1): {"origin": Vector2i(0, -8)},
	Vector2i(2, -1): {"origin": Vector2i(8, -8)},
	Vector2i(3, -1): {"origin": Vector2i(16, -8)},
	# Bottom strip (y 16..23)
	Vector2i(0, 2): {"origin": Vector2i(-8, 16)},
	Vector2i(1, 2): {"origin": Vector2i(0, 16)},
	Vector2i(2, 2): {"origin": Vector2i(8, 16)},
	Vector2i(3, 2): {"origin": Vector2i(16, 16)},
	# Left column (x -8..-1, y 0..15)
	Vector2i(-1, 0): {"origin": Vector2i(-8, 0)},
	Vector2i(-1, 1): {"origin": Vector2i(-8, 8)},
	# Right column (x 16..23, y 0..15)
	Vector2i(4, 0): {"origin": Vector2i(16, 0)},
	Vector2i(4, 1): {"origin": Vector2i(16, 8)},
}

var _room_world: RoomWorld
var _player: Player

func _ready() -> void:
	var grid := load(GRID_PATH) as IsometricGrid
	_room_world = RoomWorld.new()
	_room_world.name = "RoomWorld"
	_room_world.grid = grid
	_room_world.room_dimensions = Vector2i(16, 16)
	_room_world.default_tile_id = &"floor_iso"
	_room_world.tile_catalog = load(TILE_CATALOG_PATH) as TileCatalog
	_room_world.block_catalog = load(BLOCK_CATALOG_PATH) as BlockCatalog
	_room_world.furniture_catalog = load(FURNITURE_CATALOG_PATH) as FurnitureCatalog
	_room_world.carpet_catalog = load(CARPET_CATALOG_PATH) as CarpetCatalog
	_room_world.block_scene = load(BLOCK_SCENE_PATH) as PackedScene
	_room_world.player_scene = load(PLAYER_SCENE_PATH) as PackedScene
	_room_world.hide_rooms_outside_neighborhood = false
	_room_world.show_room_labels = true
	_room_world.emphasis_transition_duration = 0.0
	_room_world.room_slide_duration = 0.0
	add_child(_room_world)

	var center := _room_world.create_room_at(CENTER_ID, CENTER_ORIGIN, CENTER_SIZE)
	if center == null:
		push_error("RoomLayoutTest failed to create center room.")
	else:
		_tint_room(center, Color(1.00, 0.96, 0.90))
		_populate_room(center)
	for room_id in LAYOUT:
		var entry: Dictionary = LAYOUT[room_id]
		var room := _room_world.create_room_at(room_id, entry["origin"], RING_SIZE)
		if room == null:
			push_error("RoomLayoutTest failed to create room %s." % room_id)
			continue
		_tint_room(room, _ring_tint(room_id))
		_populate_room(room)
	_register_demo_connections()
	_spawn_player()
	var camera := WorldCamera.new()
	camera.name = "WorldCamera"
	add_child(camera)

func _ring_tint(room_id: Vector2i) -> Color:
	var hue := posmod(room_id.x * 7 + room_id.y * 13, 12) / 12.0
	return Color.from_hsv(hue, 0.16, 0.98)

func _tint_room(room: Room, tint: Color) -> void:
	var tile_layer := room.get_node_or_null(^"TileLayer") as TileLayer
	if tile_layer != null:
		tile_layer.modulate = tint

func _populate_room(room: Room) -> void:
	var block_layer := room.block_layer
	if block_layer == null:
		return
	var standard := block_layer.get_definition(&"standard_block")
	var crate := block_layer.get_definition(&"crate")
	var size: Vector2i = room.size
	if standard != null:
		block_layer.place_block(standard, Vector2i(floori(size.x * 0.25), floori(size.y * 0.25)), 0.0)
	if crate != null:
		block_layer.place_block(crate, Vector2i(floori(size.x * 0.75), floori(size.y * 0.75)), 0.0)
	if _room_world.furniture_catalog != null:
		var chair := _room_world.furniture_catalog.get_definition(&"chair")
		if chair != null:
			block_layer.place_furniture(chair, Vector2i(floori(size.x * 0.5), floori(size.y * 0.5)), 0.0, 90)

func _register_demo_connections() -> void:
	# Every pair of rooms sharing a world-cell edge gets a bidirectional
	# door covering the whole shared edge: center<->ring (12 pairs) and
	# ring<->ring along the frame (12 pairs).
	_room_world.auto_connect_adjacent_rooms()
	# Portal inside a top-strip room that warps to a bottom-strip room;
	# the two rooms are not physically adjacent.
	var portal := RoomConnection.new()
	portal.connection_id = &"portal_top_bottom"
	portal.connection_type = RoomConnection.ConnectionType.PORTAL
	portal.source_room_id = Vector2i(2, -1)
	portal.destination_room_id = Vector2i(1, 2)
	var portal_source: Array[Vector2i] = [Vector2i(5, 5)]
	var portal_dest: Array[Vector2i] = [Vector2i(3, 5)]
	portal.source_cells = portal_source
	portal.destination_cells = portal_dest
	portal.interactive = true
	portal.bidirectional = false
	_room_world.register_connection(portal)
	# Mark the portal with the flower sprite via the connection marker
	# system so the trigger cell is visible without placing a carpet.
	var flower := _room_world.carpet_catalog.get_definition(&"flower_carpet") if _room_world.carpet_catalog != null else null
	if flower != null and flower.sprite_texture != null:
		portal.marker_texture = flower.sprite_texture
		_room_world.visuals.refresh_connection_markers()

func _spawn_player() -> void:
	var room_a := _room_world.get_room(Vector2i(0, 0))
	if room_a == null or _room_world.player_scene == null:
		return
	_player = _room_world.player_scene.instantiate() as Player
	_player.grid = _room_world.grid
	_player.block_layer = room_a.block_layer
	_player.room = room_a
	_player.room_size = room_a.size
	_player.grid_position = Vector2i(8, 8)
	_player.elevation = 0.0
	_room_world.entity_layer.add_child(_player)
