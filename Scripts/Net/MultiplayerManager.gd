class_name MultiplayerManager
extends Node

## Minimal ENet multiplayer prototype. Created by WorldBootstrap only
## when launch args request it — normal play never instantiates this.
##
## Launch modes (args after `--`):
##   --server                 dedicated server (headless-friendly)
##   --client[=ADDRESS]       connect to a server (default 127.0.0.1)
##   --port=NNNN              override the port (default 7777)
##   --autowalk               debug: pace the local player back and
##                            forth (for headless connectivity tests)
##
## Authority model: the server (peer 1) owns one hidden authoritative
## Player body per connected client. Clients send move REQUESTS
## (directions only — never positions); the server validates them with
## the real Player movement rules and broadcasts the resulting grid
## state. Clients predict locally and reconcile if the server disagrees.

enum Mode { OFF, SERVER, CLIENT }

const DEFAULT_ADDRESS := "127.0.0.1"
const DEFAULT_PORT := 7777
const MAX_PEERS := 8

var mode := Mode.OFF
## True on the dedicated server: WorldBootstrap skips save-on-exit so a
## headless server never writes to the local save directory.
var dedicated_server := false
var server_address := DEFAULT_ADDRESS
var server_port := DEFAULT_PORT
var my_peer_id := 1

var _world: WorldBootstrap
var _player_scene: PackedScene
## Server: peer_id -> authoritative Player body.
var _bodies := {}
## Client: peer_id -> visual replica Player.
var _avatars := {}
var _connected := false
var _autowalk := false
var _dump_world := false
var _world_dumped := false
var _autowalk_timer := 0.0
var _autowalk_dir := Vector2i(1, 0)
## Client: true only after the authoritative world snapshot applied
## successfully. Movement requests and avatar spawns are gated on it.
var world_synced := false
## Server: peers that connected but have not yet acknowledged their
## snapshot — peer_id -> connect timestamp (msec). Spawn waits for
## the ack so nobody interacts with a half-built world.
var _pending_peers := {}
var _snapshot_serial := 0
## Client: in-flight snapshot reassembly — snap_id ->
## {"total": int, "parts": {index: PackedByteArray}}.
var _rx_snapshots := {}
## Client: recently accepted local grid states, oldest -> newest.
## Server echoes lag local prediction by ~1 step while walking, so an
## echoed state that matches a recent prediction is a stale duplicate
## (the newer echo is already queued on the reliable channel) — only
## states absent from history are genuine divergence worth snapping to.
var _local_state_history: Array = []
const LOCAL_STATE_HISTORY := 12
## Build ops (Phase B1): client request serial + server-side dedup.
var _build_op_serial := 0
var _seen_build_ops := {}
const BUILD_OP_HISTORY := 32
## Debug: --build-place=x,y:id / --build-remove=x,y run once after
## sync for headless live tests; --dump-world=N delays the dump N sec.
var _debug_place := {}
var _debug_remove := {}
var _synced_msec := -1
var _dump_at_msec := 0
## Client UI feedback: emitted for every build result this peer
## receives (accepted or rejected).
signal build_result(op_id: int, accepted: bool, reason: StringName)
const SNAPSHOT_CHUNK_SIZE := 49152
const SNAPSHOT_TIMEOUT_MS := 15000

## Parses launch args into {mode, address, port}; empty dict = no net.
static func parse_args(args: PackedStringArray) -> Dictionary:
	var result := {}
	for arg in args:
		if arg == "--server":
			result["mode"] = Mode.SERVER
		elif arg == "--client" or arg.begins_with("--client="):
			result["mode"] = Mode.CLIENT
			if arg.contains("="):
				result["address"] = arg.get_slice("=", 1)
		elif arg.begins_with("--port="):
			result["port"] = arg.get_slice("=", 1).to_int()
		elif arg == "--autowalk":
			result["autowalk"] = true
		elif arg.begins_with("--dump-world"):
			result["dump_world"] = true
			if arg.contains("="):
				result["dump_delay"] = arg.get_slice("=", 1).to_float()
		elif arg.begins_with("--build-place="):
			result["build_place"] = arg.get_slice("=", 1)
		elif arg.begins_with("--build-remove="):
			result["build_remove"] = arg.get_slice("=", 1)
	if not result.has("mode"):
		return {}
	if not result.has("address"):
		result["address"] = DEFAULT_ADDRESS
	if not result.has("port"):
		result["port"] = DEFAULT_PORT
	return result

func setup(world: WorldBootstrap, args: Dictionary) -> void:
	_world = world
	_player_scene = world.player_scene
	add_to_group(&"multiplayer_manager")
	mode = args["mode"]
	server_address = args["address"]
	server_port = args["port"]
	dedicated_server = mode == Mode.SERVER
	match mode:
		Mode.SERVER:
			var peer := ENetMultiplayerPeer.new()
			var error := peer.create_server(server_port, MAX_PEERS)
			if error != OK:
				push_error("MultiplayerManager: server failed to bind port %d (error %d)." % [server_port, error])
				return
			multiplayer.multiplayer_peer = peer
			multiplayer.peer_connected.connect(_on_peer_connected)
			multiplayer.peer_disconnected.connect(_on_peer_disconnected)
			print("MultiplayerManager: server listening on port %d." % server_port)
		Mode.CLIENT:
			var peer := ENetMultiplayerPeer.new()
			var error := peer.create_client(server_address, server_port)
			if error != OK:
				push_error("MultiplayerManager: client failed to start (error %d)." % error)
				return
			multiplayer.multiplayer_peer = peer
			multiplayer.connected_to_server.connect(_on_connected_to_server)
			multiplayer.connection_failed.connect(_on_connection_failed)
			multiplayer.server_disconnected.connect(_on_server_disconnected)
			print("MultiplayerManager: connecting to %s:%d ..." % [server_address, server_port])
	if mode == Mode.CLIENT:
		# Input stays locked until the authoritative snapshot lands;
		# request_move() drops both local prediction and the RPC.
		if _world.player != null:
			_world.player.local_input_locked = true
			_world.player.move_requested.connect(request_move)
			_world.player.authoritative_state_changed.connect(_record_local_state)
		_autowalk = args.get("autowalk", false)
	_dump_world = args.get("dump_world", false)
	_dump_at_msec = Time.get_ticks_msec() \
		+ int(float(args.get("dump_delay", 0.0)) * 1000.0)
	_debug_place = _parse_build_arg(args.get("build_place", ""), true)
	_debug_remove = _parse_build_arg(args.get("build_remove", ""), false)

func _process(delta: float) -> void:
	if mode == Mode.CLIENT:
		_update_avatar_visibility()
	# --dump-world: print the live world once — on the server as soon
	# as it boots, on a client only after the snapshot applied, so the
	# two dumps can be diffed to verify replication.
	if _dump_world and not _world_dumped \
			and Time.get_ticks_msec() >= _dump_at_msec \
			and (mode == Mode.SERVER or world_synced):
		_world_dumped = true
		_dump_world_state("peer%d" % my_peer_id)
	_run_debug_build_ops()
	# Server: drop peers that never acknowledged their snapshot.
	if mode == Mode.SERVER and not _pending_peers.is_empty():
		var now := Time.get_ticks_msec()
		for peer_id in _pending_peers.keys():
			if now - int(_pending_peers[peer_id]) > SNAPSHOT_TIMEOUT_MS:
				push_warning("MultiplayerManager: peer %d never completed world sync; disconnecting." % peer_id)
				_pending_peers.erase(peer_id)
				multiplayer.multiplayer_peer.disconnect_peer(peer_id)
	if not _autowalk or not _connected or not world_synced:
		return
	_autowalk_timer += delta
	if _autowalk_timer < 0.6:
		return
	_autowalk_timer = 0.0
	var player := _local_player()
	if player == null or player.room == null:
		return
	# Walk a small loop inside the entry room; request_move applies the
	# same validation locally and forwards the intent to the server.
	# grid_position is room-local; has_footprint_cell takes local cells.
	var next := player.grid_position + _autowalk_dir
	if not player.room.has_footprint_cell(next):
		_autowalk_dir = Vector2i(_autowalk_dir.y, _autowalk_dir.x)
	player.request_move(_autowalk_dir)

## Prints every room's id, size, and placed contents (blocks with
## positions, furniture/carpet/tile counts) for --dump-world.
func _dump_world_state(tag: String) -> void:
	var world := _world.room_world
	for room in world.get_rooms():
		var counts: Dictionary = room.placed_content_counts()
		var blocks: Array[String] = []
		if room.block_layer != null:
			for block in room.block_layer.blocks:
				blocks.append("%s@%s" % [block.block_id, block.grid_position])
		print("WORLD_DUMP %s floor=%s room=%s size=%s blocks=[%s] contents=%s" % [
			tag, _world.floor_manager.active_floor.floor_id \
				if _world.floor_manager.active_floor != null else &"?",
			room.room_coordinates, room.size, ", ".join(blocks), counts])
	var conns: Array = world.connections.serialize_all()
	print("WORLD_DUMP %s connections=%d" % [tag, conns.size()])

func _exit_tree() -> void:
	if multiplayer != null and multiplayer.multiplayer_peer != null:
		multiplayer.multiplayer_peer.close()

# ------------------------------------------------------------------
# Server side
# ------------------------------------------------------------------

func _on_peer_connected(peer_id: int) -> void:
	if mode != Mode.SERVER:
		return
	# Snapshot first: the client must rebuild the authoritative world
	# before it gets a player body or sees anyone else.
	_pending_peers[peer_id] = Time.get_ticks_msec()
	_send_world_snapshot(peer_id)

## Builds the authoritative snapshot from the server's live world and
## streams it as reliable JSON chunks. Generated per join so a player
## connecting mid-session receives current state, not a stale copy.
func _send_world_snapshot(peer_id: int) -> void:
	var snapshot := WorldSnapshot.build(_world.floor_manager, _world.room_world)
	if snapshot.is_empty():
		push_error("MultiplayerManager: cannot snapshot world for peer %d." % peer_id)
		return
	var bytes := JSON.stringify(snapshot).to_utf8_buffer()
	var total := maxi(1, ceili(float(bytes.size()) / SNAPSHOT_CHUNK_SIZE))
	var snap_id := _snapshot_serial
	_snapshot_serial += 1
	_rpc_snapshot_begin.rpc_id(peer_id, snap_id, total)
	for index in range(total):
		var part := bytes.slice(index * SNAPSHOT_CHUNK_SIZE,
			mini((index + 1) * SNAPSHOT_CHUNK_SIZE, bytes.size()))
		_rpc_snapshot_chunk.rpc_id(peer_id, snap_id, index, part)
	_rpc_snapshot_end.rpc_id(peer_id, snap_id)
	print("MultiplayerManager: snapshot for peer %d sent (%d bytes, %d chunk(s))." % [
		peer_id, bytes.size(), total])

## Client acknowledged its snapshot: now the peer gets a body and the
## usual spawn broadcast.
func _complete_peer_join(peer_id: int) -> void:
	var body := _spawn_body(peer_id)
	if body == null:
		return
	# Tell the joiner where to stand and who else is already there.
	var states: Array = []
	for other_id in _bodies:
		if other_id == peer_id:
			continue
		var other: Player = _bodies[other_id]
		states.append([other_id, other.room.room_coordinates,
			other.grid_position, other.elevation, other.facing_direction])
	_rpc_welcome.rpc_id(peer_id, body.room.room_coordinates,
		body.grid_position, body.elevation, body.facing_direction, states)
	# Everyone else learns about the new player (the joiner ignores
	# its own id in _rpc_spawn_player).
	_rpc_spawn_player.rpc(peer_id, body.room.room_coordinates,
		body.grid_position, body.elevation, body.facing_direction)
	print("MultiplayerManager: peer %d joined (%d player(s) total)." % [peer_id, _bodies.size()])

func _on_peer_disconnected(peer_id: int) -> void:
	if mode != Mode.SERVER:
		return
	_pending_peers.erase(peer_id)
	_seen_build_ops.erase(peer_id)
	var body: Player = _bodies.get(peer_id)
	if body != null:
		body.queue_free()
	_bodies.erase(peer_id)
	_rpc_despawn_player.rpc(peer_id)
	print("MultiplayerManager: peer %d left." % peer_id)

## Authoritative body for one client: a real Player with input
## disabled, spawned at the same entry point as the local avatar.
func _spawn_body(peer_id: int) -> Player:
	var local := _world.player
	if local == null or _player_scene == null:
		return null
	var body := _player_scene.instantiate() as Player
	if body == null:
		return null
	body.network_remote = true
	body.name = "NetBody_%d" % peer_id
	body.grid = _world.room_world.grid
	body.block_layer = local.block_layer
	body.room = local.room
	body.room_size = local.room.size
	body.grid_position = local.grid_position
	body.elevation = local.elevation
	_world.room_world.entity_layer.add_child(body)
	body.authoritative_state_changed.connect(_on_body_state_changed.bind(peer_id))
	_bodies[peer_id] = body
	return body

func _on_body_state_changed(peer_id: int) -> void:
	var body: Player = _bodies.get(peer_id)
	if body == null or body.room == null:
		return
	_rpc_player_state.rpc(peer_id, body.room.room_coordinates,
		body.grid_position, body.elevation, body.facing_direction)

# ------------------------------------------------------------------
# Client side
# ------------------------------------------------------------------

func _on_connected_to_server() -> void:
	_connected = true
	my_peer_id = multiplayer.get_unique_id()
	print("MultiplayerManager: connected to server as peer %d." % my_peer_id)

func _on_connection_failed() -> void:
	push_error("MultiplayerManager: connection to %s:%d failed." % [server_address, server_port])

func _on_server_disconnected() -> void:
	_connected = false
	world_synced = false
	if _world != null and _world.player != null:
		_world.player.local_input_locked = true
	_pending_peers.clear()
	_rx_snapshots.clear()
	_local_state_history.clear()
	push_warning("MultiplayerManager: disconnected from server.")
	for peer_id in _avatars.keys():
		var avatar: Player = _avatars[peer_id]
		if is_instance_valid(avatar):
			avatar.queue_free()
	_avatars.clear()

func _local_player() -> Player:
	return _world.player if _world != null else null

## Records each locally accepted grid state (emitted by Player after
## every accepted move/transition/place_at) so _reconcile_local can
## tell stale echoes from real divergence.
func _record_local_state() -> void:
	var player := _local_player()
	if player == null or player.room == null:
		return
	_local_state_history.append([
		player.room.room_coordinates, player.grid_position, player.elevation])
	while _local_state_history.size() > LOCAL_STATE_HISTORY:
		_local_state_history.pop_front()

## True when (room_id, cell, elevation) is a state the local player
## already predicted — i.e. an echo catching up, not a correction.
func _is_predicted_state(room_id: Vector2i, cell: Vector2i, cell_elevation: float) -> bool:
	for entry in _local_state_history:
		if entry[0] == room_id and entry[1] == cell \
				and absf(float(entry[2]) - cell_elevation) < 0.01:
			return true
	return false

func _room_for_id(room_id: Vector2i) -> Room:
	return _world.room_world.get_room(room_id) if _world != null else null

## Reconcile the local avatar with authoritative state: the client
## predicts movement, so this only corrects real divergence (rejected
## moves, room transitions, spawn placement).
func _reconcile_local(room_id: Vector2i, cell: Vector2i, cell_elevation: float) -> void:
	var player := _local_player()
	if player == null:
		return
	var target_room := _room_for_id(room_id)
	if target_room == null:
		return
	if player.room == target_room and player.grid_position == cell \
			and absf(player.elevation - cell_elevation) < 0.01:
		return
	# Echo of a state we already predicted: the authoritative channel
	# is ordered, so the matching current state arrives next — snapping
	# back now would teleport the avatar ~1-2 cells on every step.
	if _is_predicted_state(room_id, cell, cell_elevation):
		return
	player.room = target_room
	player.block_layer = target_room.block_layer
	player.room_size = target_room.size
	player.place_at(cell, cell_elevation)

func _spawn_avatar(peer_id: int, room_id: Vector2i, cell: Vector2i,
		cell_elevation: float, face: Vector2i) -> void:
	if _avatars.has(peer_id):
		return
	var room := _room_for_id(room_id)
	if room == null or _player_scene == null:
		return
	var avatar := _player_scene.instantiate() as Player
	if avatar == null:
		return
	avatar.network_remote = true
	avatar.name = "NetAvatar_%d" % peer_id
	avatar.grid = _world.room_world.grid
	avatar.block_layer = room.block_layer
	avatar.room = room
	avatar.room_size = room.size
	avatar.grid_position = cell
	avatar.elevation = cell_elevation
	_world.room_world.entity_layer.add_child(avatar)
	avatar._set_facing(face)
	_avatars[peer_id] = avatar
	print("MultiplayerManager: avatar for peer %d spawned at %s cell %s." % [
		peer_id, room.room_coordinates, cell])

## Remote avatars follow room visibility: a player is only drawn
## where their room is revealed to the local player (current room or
## visible neighbors; hidden/concealed rooms hide their occupants).
func _update_avatar_visibility() -> void:
	if _world == null or _world.room_world == null:
		return
	# Creation Mode's blueprint pass owns avatar.visible while active.
	if FloorEditor.any_active(get_tree()):
		return
	var visuals := _world.room_world.visuals
	for avatar in _avatars.values():
		if not is_instance_valid(avatar):
			continue
		avatar.visible = visuals != null \
			and visuals.is_room_revealed(avatar.room)

func _remove_avatar(peer_id: int) -> void:
	var avatar: Player = _avatars.get(peer_id)
	if avatar != null and is_instance_valid(avatar):
		avatar.queue_free()
	_avatars.erase(peer_id)

# ------------------------------------------------------------------
# World snapshot sync (server -> joining client, chunked + reliable)
# ------------------------------------------------------------------

@rpc("authority", "call_remote", "reliable")
func _rpc_snapshot_begin(snap_id: int, total_chunks: int) -> void:
	if multiplayer.is_server():
		return
	_rx_snapshots[snap_id] = {"total": total_chunks, "parts": {}}

@rpc("authority", "call_remote", "reliable")
func _rpc_snapshot_chunk(snap_id: int, index: int, data: PackedByteArray) -> void:
	if multiplayer.is_server():
		return
	var rx: Dictionary = _rx_snapshots.get(snap_id, {})
	if rx.is_empty():
		return
	(rx["parts"] as Dictionary)[index] = data

@rpc("authority", "call_remote", "reliable")
func _rpc_snapshot_end(snap_id: int) -> void:
	if multiplayer.is_server():
		return
	var rx: Variant = _rx_snapshots.get(snap_id)
	_rx_snapshots.erase(snap_id)
	if not (rx is Dictionary):
		push_error("MultiplayerManager: snapshot %d ended without begin." % snap_id)
		return
	var parts: Dictionary = rx["parts"]
	var total := int(rx["total"])
	var bytes := PackedByteArray()
	for index in range(total):
		var part: Variant = parts.get(index)
		if part == null:
			push_error("MultiplayerManager: snapshot %d missing chunk %d; world NOT synced." % [snap_id, index])
			return
		bytes.append_array(part)
	var parsed: Variant = JSON.parse_string(bytes.get_string_from_utf8())
	if not (parsed is Dictionary):
		push_error("MultiplayerManager: snapshot %d is not valid JSON; world NOT synced." % snap_id)
		return
	if not WorldSnapshot.apply(_world.floor_manager, _world.room_world,
			_world.player, parsed):
		push_error("MultiplayerManager: world snapshot %d failed to apply; client stays unready." % snap_id)
		return
	world_synced = true
	_local_state_history.clear()
	_synced_msec = Time.get_ticks_msec()
	if _world.player != null:
		_world.player.local_input_locked = false
	print("MultiplayerManager: world snapshot applied; client ready.")
	_rpc_world_ready.rpc_id(1)

## Client -> server: snapshot applied successfully; safe to spawn.
@rpc("any_peer", "call_remote", "reliable")
func _rpc_world_ready() -> void:
	if not multiplayer.is_server():
		return
	var sender := multiplayer.get_remote_sender_id()
	if not _pending_peers.has(sender):
		return
	_pending_peers.erase(sender)
	_complete_peer_join(sender)

# ------------------------------------------------------------------
# Build ops (Phase B1): block place/remove request -> server
# validate -> apply -> broadcast. Clients never mutate the shared
# world directly for these operations.
# ------------------------------------------------------------------

## True when this peer may originate build requests.
func can_request_build() -> bool:
	return mode == Mode.CLIENT and _connected and world_synced

## Client -> server: place a plain block. room_id/cell are room-local;
## the server recomputes elevation and re-validates everything.
func request_build_place(room_id: Vector2i, cell: Vector2i,
		object_id: StringName, flip: bool) -> bool:
	if not can_request_build():
		return false
	_build_op_serial += 1
	_rpc_build_place.rpc_id(1, _build_op_serial, room_id, cell,
		object_id, flip)
	return true

## Client -> server: remove the block the requester saw at cell.
## target_* identify it so a changed topmost block rejects as stale.
func request_build_remove(room_id: Vector2i, cell: Vector2i,
		block_id: StringName, block_pos: Vector2i, block_elev: float) -> bool:
	if not can_request_build():
		return false
	_build_op_serial += 1
	_rpc_build_remove.rpc_id(1, _build_op_serial, room_id, cell,
		block_id, block_pos, block_elev)
	return true

## World cells occupied by every player body plus the server's own
## avatar — placement/removal must not target any of them.
func _player_world_cells() -> Array:
	var cells: Array = []
	var world := _world.room_world if _world != null else null
	for body in _bodies.values():
		if body != null and is_instance_valid(body) and body.room != null:
			cells.append(body.room.world_cell_coordinates(body.grid_position))
	var local := _local_player()
	if local != null and local.room != null:
		cells.append(local.room.world_cell_coordinates(local.grid_position))
	return cells

## Per-peer op-id dedup: reliable RPCs do not duplicate deliveries,
## but a resent/replayed request must never apply twice.
func _claim_build_op(peer_id: int, op_id: int) -> bool:
	var seen: Dictionary = _seen_build_ops.get(peer_id, {})
	if seen.has(op_id):
		return false
	seen[op_id] = true
	while seen.size() > BUILD_OP_HISTORY:
		seen.erase(seen.keys()[0])
	_seen_build_ops[peer_id] = seen
	return true

func _reject_build(peer_id: int, op_id: int, reason: StringName) -> void:
	_rpc_build_result.rpc_id(peer_id, op_id, false, reason, {})
	print("MultiplayerManager: build op %d from peer %d rejected: %s" % [
		op_id, peer_id, reason])

# ------------------------------------------------------------------
# Build op RPCs
# ------------------------------------------------------------------

@rpc("any_peer", "call_remote", "reliable")
func _rpc_build_place(op_id: int, room_id: Vector2i, cell: Vector2i,
		object_id: StringName, flip: bool) -> void:
	if mode != Mode.SERVER:
		return
	var sender := multiplayer.get_remote_sender_id()
	if not _claim_build_op(sender, op_id):
		_reject_build(sender, op_id, &"duplicate")
		return
	# A body exists only after the peer acknowledged its snapshot.
	if not _bodies.has(sender):
		_reject_build(sender, op_id, &"not_ready")
		return
	var result := BuildOps.validate_place(_world.room_world,
		_player_world_cells(), room_id, cell, object_id)
	if not bool(result.get("ok", false)):
		_reject_build(sender, op_id, result.get("reason", &"invalid"))
		return
	var block := BuildOps.apply_place(result["room"], cell, object_id,
		float(result["elevation"]), flip)
	if block == null:
		_reject_build(sender, op_id, &"apply_failed")
		return
	# Broadcast AFTER the authoritative apply; every synced client
	# reproduces it locally without generating another request.
	_rpc_build_result.rpc(op_id, true, &"", {
		"kind": "place", "room_id": room_id, "cell": cell,
		"object_id": object_id, "elevation": result["elevation"],
		"flip": flip})
	print("MultiplayerManager: build op %d place %s @%s room %s applied." % [
		op_id, object_id, cell, room_id])

@rpc("any_peer", "call_remote", "reliable")
func _rpc_build_remove(op_id: int, room_id: Vector2i, cell: Vector2i,
		block_id: StringName, block_pos: Vector2i, block_elev: float) -> void:
	if mode != Mode.SERVER:
		return
	var sender := multiplayer.get_remote_sender_id()
	if not _claim_build_op(sender, op_id):
		_reject_build(sender, op_id, &"duplicate")
		return
	if not _bodies.has(sender):
		_reject_build(sender, op_id, &"not_ready")
		return
	var result := BuildOps.validate_remove(_world.room_world,
		_player_world_cells(), room_id, cell, block_id, block_pos, block_elev)
	if not bool(result.get("ok", false)):
		_reject_build(sender, op_id, result.get("reason", &"invalid"))
		return
	var removed: Block = result["block"]
	var payload := {
		"kind": "remove", "room_id": room_id, "cell": cell,
		"block_id": removed.block_id, "block_pos": removed.grid_position,
		"block_elev": removed.elevation}
	if not BuildOps.apply_remove(result["room"], cell, removed.block_id,
			removed.grid_position, removed.elevation):
		_reject_build(sender, op_id, &"apply_failed")
		return
	_rpc_build_result.rpc(op_id, true, &"", payload)
	print("MultiplayerManager: build op %d remove %s @%s room %s applied." % [
		op_id, removed.block_id, cell, room_id])

## Server -> all clients: authoritative build outcome. accepted=true
## carries the payload needed to reproduce the op locally; false is
## sent only to the requester so its UI can react.
@rpc("authority", "call_remote", "reliable")
func _rpc_build_result(op_id: int, accepted: bool, reason: StringName,
		payload: Dictionary) -> void:
	if multiplayer.is_server():
		return
	if not accepted:
		build_result.emit(op_id, false, reason)
		return
	var room_id: Vector2i = payload.get("room_id", Vector2i.ZERO)
	var room := _room_for_id(room_id)
	if room == null:
		push_warning("MultiplayerManager: build result for unknown room %s ignored." % room_id)
		return
	match String(payload.get("kind", "")):
		"place":
			BuildOps.apply_place(room, payload.get("cell", Vector2i.ZERO),
				payload.get("object_id", &""),
				float(payload.get("elevation", 0.0)),
				bool(payload.get("flip", false)))
		"remove":
			BuildOps.apply_remove(room, payload.get("cell", Vector2i.ZERO),
				payload.get("block_id", &""),
				payload.get("block_pos", Vector2i.ZERO),
				float(payload.get("block_elev", 0.0)))
	build_result.emit(op_id, true, &"")
	print("MultiplayerManager: build op %d applied locally (%s)." % [
		op_id, payload.get("kind", "?")])

# ------------------------------------------------------------------
# Debug build ops for headless live tests (--build-place/--build-remove)
# ------------------------------------------------------------------

func _parse_build_arg(spec: String, is_place: bool) -> Dictionary:
	if spec.is_empty():
		return {}
	var parts := spec.split(":")
	var cell_parts := parts[0].split(",")
	if cell_parts.size() != 2:
		push_warning("MultiplayerManager: bad build arg '%s'." % spec)
		return {}
	var result := {"cell": Vector2i(cell_parts[0].to_int(), cell_parts[1].to_int()),
		"done": false}
	if is_place and parts.size() > 1:
		result["object_id"] = StringName(parts[1])
	return result if is_place or parts.size() == 1 else {}

## Runs the debug place/remove once, timed after world sync so the
## request travels the real client->server->broadcast path.
func _run_debug_build_ops() -> void:
	if mode != Mode.CLIENT or not world_synced or _synced_msec < 0:
		return
	var now := Time.get_ticks_msec() - _synced_msec
	var player := _local_player()
	if player == null or player.room == null:
		return
	if not _debug_place.is_empty() and not _debug_place["done"] and now >= 2000:
		_debug_place["done"] = true
		var ok := request_build_place(player.room.room_coordinates,
			_debug_place["cell"], _debug_place.get("object_id", &"standard_block"), false)
		print("MultiplayerManager: debug place -> %s" % ok)
	if not _debug_remove.is_empty() and not _debug_remove["done"] and now >= 5000:
		_debug_remove["done"] = true
		var cell: Vector2i = _debug_remove["cell"]
		var layer := player.room.block_layer
		var top := BuildOps.topmost_block(layer, cell) if layer != null else null
		if top == null or top.block_definition == null:
			print("MultiplayerManager: debug remove found no plain block at %s." % cell)
			return
		var ok := request_build_remove(player.room.room_coordinates, cell,
			StringName(top.block_id), top.grid_position, top.elevation)
		print("MultiplayerManager: debug remove -> %s" % ok)

# ------------------------------------------------------------------
# RPCs — path-stable: always /root/<Main>/WorldBootstrap/MultiplayerManager
# ------------------------------------------------------------------

## Client -> server: a move request is a DIRECTION, never a position.
## The server re-validates it against its authoritative body.
@rpc("any_peer", "call_remote", "reliable")
func _rpc_move_request(direction: Vector2i) -> void:
	if not multiplayer.is_server():
		return
	var sender := multiplayer.get_remote_sender_id()
	var body: Player = _bodies.get(sender)
	if body == null:
		return
	body.request_move(direction)

## Server -> joiner only: authoritative spawn plus everyone already here.
@rpc("authority", "call_remote", "reliable")
func _rpc_welcome(room_id: Vector2i, cell: Vector2i, cell_elevation: float,
		_face: Vector2i, states: Array) -> void:
	if multiplayer.is_server():
		return
	_reconcile_local(room_id, cell, cell_elevation)
	for entry in states:
		_spawn_avatar(int(entry[0]), entry[1], entry[2], entry[3], entry[4])

## Server -> all clients: a player entered the world.
@rpc("authority", "call_remote", "reliable")
func _rpc_spawn_player(peer_id: int, room_id: Vector2i, cell: Vector2i,
		cell_elevation: float, face: Vector2i) -> void:
	if multiplayer.is_server() or peer_id == my_peer_id:
		return
	_spawn_avatar(peer_id, room_id, cell, cell_elevation, face)

## Server -> all clients: authoritative grid state for a peer.
@rpc("authority", "call_remote", "reliable")
func _rpc_player_state(peer_id: int, room_id: Vector2i, cell: Vector2i,
		cell_elevation: float, face: Vector2i) -> void:
	if multiplayer.is_server():
		return
	if peer_id == my_peer_id:
		_reconcile_local(room_id, cell, cell_elevation)
		return
	var avatar: Player = _avatars.get(peer_id)
	if avatar == null:
		_spawn_avatar(peer_id, room_id, cell, cell_elevation, face)
		return
	avatar.network_apply_state(_room_for_id(room_id), cell, cell_elevation, face)

## Server -> all clients: a player left.
@rpc("authority", "call_remote", "reliable")
func _rpc_despawn_player(peer_id: int) -> void:
	if multiplayer.is_server():
		return
	_remove_avatar(peer_id)

# ------------------------------------------------------------------
# Client input hook: forward local movement to the server.
# ------------------------------------------------------------------

## Called by the local player when it accepts a move direction.
func request_move(direction: Vector2i) -> void:
	if mode != Mode.CLIENT or not _connected or not world_synced:
		return
	_rpc_move_request.rpc_id(1, direction)
