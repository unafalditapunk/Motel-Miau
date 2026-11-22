extends SceneTree

## Smoke test for the connection-graph room neighborhood: visible rooms are
## the primary room plus geometric neighbors and rooms reachable through
## the RoomConnection graph within connection_neighborhood_depth steps.

const GRID_PATH := "res://Resources/IsometricGrid/TestGrid.tres"
const TILE_CATALOG_PATH := "res://Resources/TileCatalog.tres"
const BLOCK_CATALOG_PATH := "res://Resources/BlockCatalog.tres"
const FURNITURE_CATALOG_PATH := "res://Resources/FurnitureCatalog.tres"
const CARPET_CATALOG_PATH := "res://Resources/CarpetCatalog.tres"
const BLOCK_SCENE_PATH := "res://Scenes/Objects/Block.tscn"

# A: center. B: geometric + connected neighbor. C: connected but far away
# (interactive portal target). F: two connection hops from A. D: isolated.
const LAYOUT := {
	Vector2i(0, 0): {"origin": Vector2i(0, 0), "size": Vector2i(16, 16)},     # A
	Vector2i(1, 0): {"origin": Vector2i(16, 0), "size": Vector2i(16, 16)},    # B
	Vector2i(5, 5): {"origin": Vector2i(40, 0), "size": Vector2i(8, 8)},      # C
	Vector2i(6, 5): {"origin": Vector2i(48, 0), "size": Vector2i(8, 8)},      # F
	Vector2i(9, 9): {"origin": Vector2i(40, 20), "size": Vector2i(8, 8)},     # D
}

var _room_world: RoomWorld
var _frames := 0
var _failures: Array[String] = []

func _initialize() -> void:
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
	_room_world.hide_rooms_outside_neighborhood = true
	_room_world.deemphasize_neighbors = true
	_room_world.emphasis_transition_duration = 0.0
	_room_world.room_slide_duration = 0.0
	_room_world.connection_neighborhood_depth = 1
	root.add_child(_room_world)
	for room_id in LAYOUT:
		var entry: Dictionary = LAYOUT[room_id]
		_room_world.create_room_at(room_id, entry["origin"], entry["size"])
	_register_connections()

func _register_connections() -> void:
	# Spatial door A <-> B along their shared edge.
	var door := RoomConnection.new()
	door.connection_id = &"door_a_b"
	door.source_room_id = Vector2i(0, 0)
	door.destination_room_id = Vector2i(1, 0)
	var a_cells: Array[Vector2i] = [Vector2i(15, 7), Vector2i(15, 8)]
	var b_cells: Array[Vector2i] = [Vector2i(0, 7), Vector2i(0, 8)]
	door.source_cells = a_cells
	door.destination_cells = b_cells
	door.interactive = false
	door.bidirectional = true
	_room_world.register_connection(door)
	# Interactive portal A -> C (non-adjacent rooms).
	var portal := RoomConnection.new()
	portal.connection_id = &"portal_a_c"
	portal.source_room_id = Vector2i(0, 0)
	portal.destination_room_id = Vector2i(5, 5)
	var p_src: Array[Vector2i] = [Vector2i(8, 8)]
	var p_dst: Array[Vector2i] = [Vector2i(2, 2)]
	portal.source_cells = p_src
	portal.destination_cells = p_dst
	portal.interactive = true
	portal.bidirectional = false
	_room_world.register_connection(portal)
	# Spatial door C <-> F (adjacent 8x8 rooms at (100,100) and (120,100)).
	var cf := RoomConnection.new()
	cf.connection_id = &"door_c_f"
	cf.source_room_id = Vector2i(5, 5)
	cf.destination_room_id = Vector2i(6, 5)
	var c_cells: Array[Vector2i] = [Vector2i(7, 3)]
	var f_cells: Array[Vector2i] = [Vector2i(0, 3)]
	cf.source_cells = c_cells
	cf.destination_cells = f_cells
	cf.interactive = false
	cf.bidirectional = true
	_room_world.register_connection(cf)

func _process(_delta: float) -> bool:
	_frames += 1
	if _frames < 6:
		return false
	_run_checks()
	_report()
	quit()
	return true

func _room_visible(room_id: Vector2i) -> bool:
	var room := _room_world.get_room(room_id)
	return room != null and room.visible

func _expect(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)

func _run_checks() -> void:
	var A := Vector2i(0, 0)
	var B := Vector2i(1, 0)
	var C := Vector2i(5, 5)
	var F := Vector2i(6, 5)
	var D := Vector2i(9, 9)

	# --- Depth 1 neighborhood around A ---
	_room_world.set_primary_room(A)
	_expect(_room_visible(A), "primary room A hidden")
	_expect(_room_visible(B), "geometric+connected neighbor B hidden")
	_expect(_room_visible(C), "connected non-adjacent room C hidden at depth 1")
	_expect(not _room_visible(F), "two-hop room F visible at depth 1")
	_expect(not _room_visible(D), "isolated room D visible")
	var visible := _room_world.get_visible_room_coordinates()
	_expect(visible.has(A) and visible.has(B) and visible.has(C), "visible set missing A/B/C: %s" % str(visible))
	_expect(not visible.has(F) and not visible.has(D), "visible set contains F or D: %s" % str(visible))
	_expect(_room_world.connection_distance_from_primary(C) == 1, "distance A->C = %d, expected 1" % _room_world.connection_distance_from_primary(C))
	_expect(_room_world.connection_distance_from_primary(D) == -1, "distance A->D = %d, expected -1" % _room_world.connection_distance_from_primary(D))
	# Spatial neighborhood uses real global bounds: B touches A's edge,
	# C/F/D do not.
	_expect(_room_world.spatial_distance_from_primary(B) == 1, "spatial distance A->B = %d, expected 1" % _room_world.spatial_distance_from_primary(B))
	_expect(_room_world.spatial_distance_from_primary(C) == -1, "spatial distance A->C = %d, expected -1" % _room_world.spatial_distance_from_primary(C))
	_expect(_room_world.get_spatial_neighbors(A).has(B), "B missing from A's spatial neighbors")
	_expect(not _room_world.get_spatial_neighbors(A).has(C), "C wrongly spatially adjacent to A")

	# --- De-emphasis: primary clean, visible neighbors de-emphasized ---
	var room_a := _room_world.get_room(A)
	var room_b := _room_world.get_room(B)
	var room_c := _room_world.get_room(C)
	_expect(room_a != null and room_a.deemphasis_material == null, "primary room A has deemphasis material")
	_expect(room_b != null and room_b.deemphasis_material != null, "neighbor B lacks deemphasis material")
	_expect(room_c != null and room_c.deemphasis_material != null, "connected room C lacks deemphasis material")

	# --- Configurable depth: 2 brings in F, 0 drops C ---
	_room_world.refresh_room_emphasis()
	# depth still 1: F hidden
	_expect(not _room_visible(F), "F visible at depth 1 after refresh")
	_room_world.connection_neighborhood_depth = 2
	_room_world.refresh_room_emphasis()
	_expect(_room_visible(F), "F hidden at depth 2")
	_expect(_room_world.connection_distance_from_primary(F) == 2, "distance A->F = %d, expected 2" % _room_world.connection_distance_from_primary(F))
	_room_world.connection_neighborhood_depth = 0
	_room_world.refresh_room_emphasis()
	_expect(not _room_visible(C), "C visible at depth 0")
	_expect(_room_visible(B), "geometric neighbor B hidden at depth 0")
	_room_world.connection_neighborhood_depth = 1
	_room_world.refresh_room_emphasis()

	# --- Spatial padding: a large halo pulls in the isolated room D ---
	_room_world.neighborhood_padding = 30
	_room_world.refresh_room_emphasis()
	_expect(_room_visible(D), "isolated room D hidden despite huge spatial padding")
	_room_world.neighborhood_padding = 1
	_room_world.refresh_room_emphasis()
	_expect(not _room_visible(D), "room D still visible after padding reset")

	# --- Spatial depth 0 keeps only direct bounds neighbors + connections ---
	_room_world.spatial_neighborhood_depth = 0
	_room_world.refresh_room_emphasis()
	_expect(_room_visible(B), "direct neighbor B hidden at spatial depth 0")
	_expect(_room_visible(C), "connected room C hidden at spatial depth 0")
	_room_world.spatial_neighborhood_depth = 1
	_room_world.refresh_room_emphasis()

	# --- Transition to C: neighborhood follows the graph ---
	_room_world.set_primary_room(C)
	_expect(_room_visible(C), "room C hidden after becoming primary")
	_expect(_room_visible(A), "room A hidden while connected to primary C")
	_expect(_room_visible(F), "room F hidden while connected to primary C")
	_expect(not _room_visible(B), "room B visible though only connected to A, not C")
	_expect(not _room_visible(D), "isolated room D visible after transition to C")
	var room_c_primary := _room_world.get_room(C)
	_expect(room_c_primary != null and room_c_primary.deemphasis_material == null, "new primary C still de-emphasized")
	var room_a_after := _room_world.get_room(A)
	_expect(room_a_after != null and room_a_after.deemphasis_material != null, "room A not de-emphasized after C became primary")

	# --- Visible set contains only registered rooms ---
	var registered := {}
	for room in _room_world.registry.get_rooms():
		registered[room.room_coordinates] = true
	for id in _room_world.get_visible_room_coordinates():
		_expect(registered.has(id), "visible set contains unregistered room id %s" % id)

func _report() -> void:
	if _failures.is_empty():
		print("ROOM_NEIGHBORHOOD_SMOKE: OK")
	else:
		for failure in _failures:
			push_error("ROOM_NEIGHBORHOOD_SMOKE FAIL: " + failure)
		print("ROOM_NEIGHBORHOOD_SMOKE: FAILED (%d)" % _failures.size())
