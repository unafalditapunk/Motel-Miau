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

static func _reject(reason: StringName) -> Dictionary:
	return {"ok": false, "reason": reason}
