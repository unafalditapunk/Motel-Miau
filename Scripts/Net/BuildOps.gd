class_name BuildOps
extends RefCounted

## Server-authoritative block placement/removal rules, shared by the
## network layer (MultiplayerManager) and tests. Everything here is
## pure world logic — no RPC, no nodes beyond the RoomWorld it is
## given — so the same code validates on the server, applies on every
## client, and runs headless in smoke tests.
##
## Scope (Phase B1): plain BlockDefinition placement and removal only.
## Furniture, carpets and tiles are rejected/unsupported until their
## own phase.

## validate_place result keys on success: ok, room, definition,
## elevation. On failure: ok=false, reason (StringName).
static func validate_place(room_world: RoomWorld, player_cells: Array,
		room_id: Vector2i, cell: Vector2i, object_id: StringName) -> Dictionary:
	var room := room_world.get_room(room_id) if room_world != null else null
	if room == null or room.block_layer == null:
		return _reject(&"unknown_room")
	var layer := room.block_layer
	var definition := layer.get_definition(object_id)
	if definition == null:
		return _reject(&"unknown_block")
	if not room.has_footprint_cell(cell):
		return _reject(&"outside_room")
	# The server recomputes elevation — client-supplied z is never
	# trusted — exactly like BlockPlacementController.place_at does.
	var elevation := layer.get_top_z_at(cell)
	if not layer.can_place(definition, cell, elevation):
		return _reject(&"cannot_place")
	for footprint_cell in layer.footprint_cells(definition, cell):
		var world_cell := room.world_cell_coordinates(footprint_cell)
		if player_cells.has(world_cell):
			return _reject(&"player_occupied")
	return {"ok": true, "room": room, "definition": definition,
		"elevation": elevation}

## validate_remove result keys on success: ok, room, block (the exact
## Block to remove). target_block_id/pos/elevation identify the block
## the requester saw; when provided they must still be the topmost
## removable block or the request is rejected as stale.
static func validate_remove(room_world: RoomWorld, player_cells: Array,
		room_id: Vector2i, cell: Vector2i, target_block_id: StringName,
		target_pos: Vector2i, target_elev: float) -> Dictionary:
	var room := room_world.get_room(room_id) if room_world != null else null
	if room == null or room.block_layer == null:
		return _reject(&"unknown_room")
	var layer := room.block_layer
	var top := topmost_block(layer, cell)
	if top == null:
		return _reject(&"empty_cell")
	if top.block_definition == null:
		# Furniture occupies the same layer but is a different
		# construction category — not removable in Phase B1.
		return _reject(&"unsupported")
	if target_block_id != &"":
		var expected := find_block(layer, cell, target_block_id,
			target_pos, target_elev)
		if expected == null or expected != top:
			return _reject(&"target_changed")
	for occupied in top.occupied_cells():
		if player_cells.has(room.world_cell_coordinates(occupied)):
			return _reject(&"player_occupied")
	return {"ok": true, "room": room, "block": top}

## Applies an accepted placement. Returns the new Block or null.
## elevation must come from validation (server-recomputed); flip is
## the same visual-only sprite flip BlockPlacementController applies.
static func apply_place(room: Room, cell: Vector2i, object_id: StringName,
		elevation: float, flip: bool) -> Block:
	if room == null or room.block_layer == null:
		return null
	var definition := room.block_layer.get_definition(object_id)
	if definition == null:
		push_warning("BuildOps.apply_place: unknown block '%s'." % object_id)
		return null
	var block := room.block_layer.place_block(definition, cell, elevation)
	if block == null:
		return null
	if flip:
		var sprite := block.get_node_or_null(^"Sprite") as Sprite2D
		if sprite != null:
			sprite.flip_h = true
	return block

## Applies an accepted removal: removes the exact block identified by
## (block_id, pos, elev) when it still exists at the cell, else falls
## back to the topmost plain block — the same rule the server used.
## Returns true when a block was removed.
static func apply_remove(room: Room, cell: Vector2i, block_id: StringName,
		block_pos: Vector2i, block_elev: float) -> bool:
	if room == null or room.block_layer == null:
		return false
	var layer := room.block_layer
	var block := find_block(layer, cell, block_id, block_pos, block_elev)
	if block == null:
		block = topmost_block(layer, cell)
		if block != null and block.block_definition == null:
			block = null
	if block == null:
		return false
	layer.remove_block(block)
	return true

## Highest block-layer occupant at a local cell (any Block, including
## furniture), or null when the cell holds no blocks.
static func topmost_block(layer: BlockLayer, cell: Vector2i) -> Block:
	if layer == null:
		return null
	var top: Block = null
	var top_z := -INF
	for block in layer.get_blocks_at(cell):
		if block.top_z() > top_z:
			top_z = block.top_z()
			top = block
	return top

## Finds the block matching an identity broadcast by the server.
static func find_block(layer: BlockLayer, cell: Vector2i,
		block_id: StringName, block_pos: Vector2i, block_elev: float) -> Block:
	if layer == null:
		return null
	for block in layer.get_blocks_at(cell):
		if block.block_id == block_id and block.grid_position == block_pos \
				and absf(block.elevation - block_elev) <= 0.001:
			return block
	return null

## Placement categories synchronized in Phase B2. "block" rules live
## in validate_place/apply_place above; the _any variants dispatch on
## request["category"] so the network layer has one entry point.
const CATEGORIES := [&"block", &"furniture", &"carpet", &"tile"]

## Generic place validation. request keys: room_id, cell, category,
## object_id, rotation (furniture/carpet), flip (carpet/furniture).
## Returns the same shape as validate_place plus "category"/"rotation".
static func validate_place_any(room_world: RoomWorld, player_cells: Array,
		request: Dictionary) -> Dictionary:
	var room_id := _req_vec2i(request.get("room_id"))
	var cell := _req_vec2i(request.get("cell"))
	var object_id := StringName(str(request.get("object_id", "")))
	var rotation := req_int(request.get("rotation"))
	match StringName(str(request.get("category", ""))):
		&"block":
			return validate_place(room_world, player_cells, room_id, cell, object_id)
		&"furniture":
			return _validate_furniture_place(room_world, player_cells,
				room_id, cell, object_id, rotation)
		&"carpet":
			return _validate_carpet_place(room_world, room_id, cell,
				object_id, rotation)
		&"tile":
			return _validate_tile_place(room_world, room_id, cell, object_id)
	return _reject(&"unsupported_category")

static func _room_for(world: RoomWorld, room_id: Vector2i) -> Room:
	return world.get_room(room_id) if world != null else null

static func _validate_furniture_place(room_world: RoomWorld,
		player_cells: Array, room_id: Vector2i, cell: Vector2i,
		object_id: StringName, rotation: int) -> Dictionary:
	var room := _room_for(room_world, room_id)
	if room == null or room.block_layer == null:
		return _reject(&"unknown_room")
	var layer := room.block_layer
	var catalog: FurnitureCatalog = layer.furniture_catalog \
		if layer.furniture_catalog != null else room_world.furniture_catalog
	var definition := catalog.get_definition(object_id) if catalog != null else null
	if definition == null:
		return _reject(&"unknown_furniture")
	if not room.has_footprint_cell(cell):
		return _reject(&"outside_room")
	var elevation := layer.get_top_z_at(cell)
	if not layer.can_place_furniture(definition, cell, elevation, rotation):
		return _reject(&"cannot_place")
	var footprint := definition.rotated_footprint(rotation)
	for x in range(footprint.x):
		for y in range(footprint.y):
			var world_cell := room.world_cell_coordinates(cell + Vector2i(x, y))
			if player_cells.has(world_cell):
				return _reject(&"player_occupied")
	return {"ok": true, "room": room, "category": &"furniture",
		"definition": definition, "elevation": elevation, "rotation": rotation}

static func _validate_carpet_place(room_world: RoomWorld, room_id: Vector2i,
		cell: Vector2i, object_id: StringName, rotation: int) -> Dictionary:
	var room := _room_for(room_world, room_id)
	if room == null:
		return _reject(&"unknown_room")
	var catalog: CarpetCatalog = room_world.carpet_catalog if room_world != null else null
	var definition := catalog.get_definition(object_id) if catalog != null else null
	if definition == null:
		return _reject(&"unknown_carpet")
	if not room.can_place_carpet(definition, cell, rotation):
		return _reject(&"cannot_place")
	# Mirrors the single-player path: carpets carry no player check.
	var elevation := room.block_layer.get_top_z_at(cell) if room.block_layer != null else 0.0
	return {"ok": true, "room": room, "category": &"carpet",
		"definition": definition, "elevation": elevation, "rotation": rotation}

static func _validate_tile_place(room_world: RoomWorld, room_id: Vector2i,
		cell: Vector2i, object_id: StringName) -> Dictionary:
	var room := _room_for(room_world, room_id)
	if room == null:
		return _reject(&"unknown_room")
	var catalog: TileCatalog = room_world.tile_catalog if room_world != null else null
	var definition := catalog.get_definition(object_id) if catalog != null else null
	if definition == null:
		return _reject(&"unknown_tile")
	if room.get_cell(cell) == null:
		return _reject(&"outside_room")
	var elevation := room.block_layer.get_top_z_at(cell) if room.block_layer != null else 0.0
	return {"ok": true, "room": room, "category": &"tile",
		"definition": definition, "elevation": elevation, "rotation": 0}

## Applies an accepted placement of any category. Returns the placed
## object (Block/Furniture) or true/false for carpet/tile.
static func apply_place_any(room_world: RoomWorld, room: Room,
		category: StringName, cell: Vector2i, object_id: StringName,
		elevation: float, rotation: int, flip: bool) -> Variant:
	match category:
		&"block":
			return apply_place(room, cell, object_id, elevation, flip)
		&"furniture":
			var catalog: FurnitureCatalog = room.block_layer.furniture_catalog \
				if room != null and room.block_layer != null \
					and room.block_layer.furniture_catalog != null \
				else (room_world.furniture_catalog if room_world != null else null)
			var definition := catalog.get_definition(object_id) if catalog != null else null
			if definition == null or room == null or room.block_layer == null:
				return null
			var furniture := room.block_layer.place_furniture(
				definition, cell, elevation, rotation)
			if furniture != null and flip:
				var sprite := furniture.get_node_or_null(^"Sprite") as Sprite2D
				if sprite != null:
					sprite.flip_h = true
			return furniture
		&"carpet":
			var catalog: CarpetCatalog = room_world.carpet_catalog if room_world != null else null
			var definition := catalog.get_definition(object_id) if catalog != null else null
			if definition == null or room == null:
				return false
			return room.place_carpet(definition, cell, rotation, flip, elevation)
		&"tile":
			var catalog: TileCatalog = room_world.tile_catalog if room_world != null else null
			var definition := catalog.get_definition(object_id) if catalog != null else null
			if definition == null or room == null:
				return false
			return room.set_cell_tile(cell, definition, elevation)
	return null

## The topmost removable thing at a room-local cell, mirroring
## BlockPlacementController.remove_at's pick: highest block-layer
## occupant (priority 0) vs tile (1) vs carpet (2), z first then
## priority. Returns {} when the cell holds nothing removable.
static func topmost_at(room: Room, cell: Vector2i) -> Dictionary:
	if room == null:
		return {}
	var result := {}
	var best_z := -INF
	var best_priority := -1
	var layer := room.block_layer
	var top_block := topmost_block(layer, cell) if layer != null else null
	if top_block != null:
		result = {"category": &"furniture" if top_block is Furniture else &"block",
			"block": top_block}
		best_z = top_block.top_z()
		best_priority = 0
	var room_cell := room.get_cell(cell)
	if room_cell != null and room_cell.tile != null \
			and _is_above(room_cell.tile_elevation, 1, best_z, best_priority):
		result = {"category": &"tile", "tile": room_cell.tile,
			"elevation": room_cell.tile_elevation}
		best_z = room_cell.tile_elevation
		best_priority = 1
	if room_cell != null and room_cell.carpet != null \
			and _is_above(room_cell.carpet_elevation, 2, best_z, best_priority):
		result = {"category": &"carpet", "carpet": room_cell.carpet,
			"anchor": room_cell.carpet_anchor,
			"rotation": room_cell.carpet_rotation_degrees,
			"flip": room_cell.carpet_flip,
			"elevation": room_cell.carpet_elevation}
	return result

static func _is_above(z: float, priority: int, best_z: float, best_priority: int) -> bool:
	if z > best_z + 0.001:
		return true
	return absf(z - best_z) <= 0.001 and priority > best_priority

## Generic remove validation. request keys: room_id, cell, category,
## plus identity fields (object_id, pos, elev for blocks/furniture;
## object_id+anchor+rotation+flip for carpet; object_id+elev for tile).
static func validate_remove_any(room_world: RoomWorld, player_cells: Array,
		request: Dictionary) -> Dictionary:
	var room_id := _req_vec2i(request.get("room_id"))
	var cell := _req_vec2i(request.get("cell"))
	var category := StringName(str(request.get("category", "")))
	var room := _room_for(room_world, room_id)
	if room == null:
		return _reject(&"unknown_room")
	var top := topmost_at(room, cell)
	if top.is_empty():
		return _reject(&"empty_cell")
	if top.get("category") != category:
		return _reject(&"target_changed")
	match category:
		&"block", &"furniture":
			var block: Block = top["block"]
			var is_furniture := block is Furniture
			if is_furniture != (category == &"furniture"):
				return _reject(&"target_changed")
			var expected_pos := _req_vec2i(request.get("pos"))
			var expected_elev := req_float(request.get("elev"), -1.0)
			if StringName(str(request.get("object_id", ""))) != block.block_id \
					or expected_pos != block.grid_position \
					or absf(expected_elev - block.elevation) > 0.001:
				return _reject(&"target_changed")
			if is_furniture and req_int(request.get("rotation"), -1) \
					!= block.furniture_rotation_degrees:
				return _reject(&"target_changed")
			for occupied in block.occupied_cells():
				if player_cells.has(room.world_cell_coordinates(occupied)):
					return _reject(&"player_occupied")
		&"carpet":
			var carpet: CarpetDefinition = top["carpet"]
			if StringName(str(request.get("object_id", ""))) != carpet.object_id \
					or _req_vec2i(request.get("anchor")) != top["anchor"] \
					or req_int(request.get("rotation"), -1) != int(top["rotation"]) \
					or req_bool(request.get("flip")) != bool(top["flip"]):
				return _reject(&"target_changed")
			if player_cells.has(room.world_cell_coordinates(cell)):
				return _reject(&"player_occupied")
		&"tile":
			var tile: TileDefinition = top["tile"]
			if StringName(str(request.get("object_id", ""))) != tile.object_id \
					or absf(req_float(request.get("elev"), -1.0) - float(top["elevation"])) > 0.001:
				return _reject(&"target_changed")
			if player_cells.has(room.world_cell_coordinates(cell)):
				return _reject(&"player_occupied")
		_:
			return _reject(&"unsupported_category")
	return {"ok": true, "room": room, "category": category, "target": top}

## Applies an accepted removal of any category using the identity the
## server broadcast. Falls back to the current topmost pick of the
## same category when the exact target is gone.
static func apply_remove_any(_room_world: RoomWorld, room: Room,
		category: StringName, cell: Vector2i, object_id: StringName,
		pos: Vector2i, elev: float, anchor: Vector2i, rotation: int,
		flip: bool) -> bool:
	if room == null:
		return false
	match category:
		&"block", &"furniture":
			var layer := room.block_layer
			if layer == null:
				return false
			var block := _find_typed_block(layer, cell, object_id, pos, elev,
				rotation if category == &"furniture" else -1)
			if block == null:
				block = topmost_block(layer, cell)
				if block != null and (block is Furniture) != (category == &"furniture"):
					block = null
			if block == null:
				return false
			layer.remove_block(block)
			return true
		&"carpet":
			var room_cell := room.get_cell(cell)
			if room_cell == null or room_cell.carpet == null:
				return false
			if room_cell.carpet.object_id != object_id \
					or room_cell.carpet_anchor != anchor \
					or room_cell.carpet_rotation_degrees != rotation \
					or room_cell.carpet_flip != flip:
				return false
			return room.clear_cell_carpet(cell)
		&"tile":
			var room_cell := room.get_cell(cell)
			if room_cell == null or room_cell.tile == null \
					or room_cell.tile.object_id != object_id:
				return false
			return room.clear_cell_tile(cell)
	return false

## Finds a block/furniture by identity; rotation >= 0 additionally
## requires a matching furniture_rotation_degrees.
static func _find_typed_block(layer: BlockLayer, cell: Vector2i,
		block_id: StringName, block_pos: Vector2i, block_elev: float,
		rotation: int) -> Block:
	for block in layer.get_blocks_at(cell):
		if block.block_id != block_id or block.grid_position != block_pos \
				or absf(block.elevation - block_elev) > 0.001:
			continue
		if rotation >= 0 and block is Furniture \
				and block.furniture_rotation_degrees != rotation:
			continue
		return block
	return null

## Safe Variant coercions for untrusted request/payload fields:
## int()/float()/bool() raise runtime errors on Arrays/Dictionaries,
## which would abort an RPC handler mid-validation.
static func req_int(value: Variant, fallback: int = 0) -> int:
	return int(value) if value is int or value is float else fallback

static func req_float(value: Variant, fallback: float = 0.0) -> float:
	return float(value) if value is int or value is float else fallback

static func req_bool(value: Variant, fallback: bool = false) -> bool:
	return value if value is bool else fallback

static func _req_vec2i(value: Variant) -> Vector2i:
	if value is Vector2i:
		return value
	if value is Array and (value as Array).size() == 2:
		return Vector2i(int(value[0]), int(value[1]))
	return Vector2i.ZERO

static func _reject(reason: StringName) -> Dictionary:
	return {"ok": false, "reason": reason}
