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
## peer_id -> highest build op id seen. Client op ids are strictly
## increasing per session, so anything <= the max is a replay — this
## rejects replays forever, unlike a sliding window.
var _build_op_max := {}
## Server: peer_id -> floor_id the peer's body currently occupies.
## Each floor has its own RoomWorld instance, so players can stand on
## different floors simultaneously. The bound room_world always serves
## the FloorManager's active (boot) floor.
var _peer_floor := {}
## Client: floor_id of the locally replicated world — set from the
## join snapshot and every accepted transition. Avatar spawn/state and
## build-result payloads are filtered against it.
var _my_floor_id := &""
## Client: a transition request is in flight — input and build requests
## stay locked until the destination snapshot applies or a rejection
## arrives.
var _transition_pending := false
## Client: bumped per transition request so a stale timeout callback
## can never clear a newer pending transition.
var _transition_request_serial := 0
## Server: peer_id -> {"id": transition_id, "msec": stamp} for the
## peer's UNRESOLVED transition. Acquired at the commit point of
## _handle_floor_transition, released by the client's
## _rpc_transition_done ack (id-matched), by safety expiry
## (TRANSITION_INFLIGHT_TIMEOUT_MS — covers lost acks), or on
## disconnect. While held, any new transition request rejects "busy".
var _transition_inflight := {}
## Client: seconds a transition may stay pending before the client
## gives up, unlocks input and reports a timeout.
var transition_timeout := 12.0
## Debug: --travel=<floor_id> (repeatable) requests transitions in
## order once synced — live verification of floor transitions.
var _debug_travels: Array = []
## Debug: --build-op=place:x,y:category:id[:rot[:flip]] (repeatable)
## and --build-op=remove:x,y run once each after sync for headless
## live tests; --dump-world=N delays the dump N sec.
var _debug_ops: Array = []
## Debug: --struct-op=create:rx,ry:ox,oy:w,h | delete:rx,ry |
## vis:rx,ry:from,out (repeatable) — structural room requests fired
## once each after sync for headless live tests.
var _debug_struct_ops: Array = []
## Debug: --floor-op=create:id[:name] | delete:id (repeatable) —
## floor catalog requests fired once each after sync.
var _debug_floor_ops: Array = []
## Phase D persistence: dedicated-server autosave interval (seconds,
## --autosave=, default 60) and shutdown-save state.
var _autosave_interval := 60.0
var _autosave_elapsed := 0.0
var _shutting_down := false
## Debug: --shutdown-after=SEC quits the dedicated server after N
## seconds so the shutdown-save path can be exercised headless.
var _shutdown_after := 0.0
var _shutdown_elapsed := 0.0
var _synced_msec := -1
var _dump_at_msec := 0
## Client UI feedback: emitted for every build result this peer
## receives (accepted or rejected).
signal build_result(op_id: int, accepted: bool, reason: StringName)
## Client UI feedback: emitted when a floor-transition request is
## accepted (world rebuilt, player placed) or rejected (reason set).
signal transition_result(accepted: bool, reason: StringName)
## Client UI feedback: emitted when a transition request is sent —
## the local TransitionOverlay fades out and waits for
## transition_result. Local-only; never broadcast.
signal transition_requested
const SNAPSHOT_CHUNK_SIZE := 49152
const SNAPSHOT_TIMEOUT_MS := 15000
## Server-side in-flight transition safety expiry (ms): the guard is
## normally released by the client's transition-done ack; this bounds
## how long a lost ack can keep a peer blocked. Must exceed the
## client transition_timeout (12s) plus snapshot/ack latency.
const TRANSITION_INFLIGHT_TIMEOUT_MS := 20000

## True when the local peer is a multiplayer CLIENT. Structural world
## mutations (floor/room/layout management) are server-authoritative
## and must stay read-only on clients until their RPCs exist. The
## manager joins group "multiplayer_manager" in setup(); single-player
## has no node at all and dedicated servers report SERVER.
static func is_client(tree: SceneTree) -> bool:
	if tree == null:
		return false
	var mgr := tree.get_first_node_in_group(&"multiplayer_manager") as MultiplayerManager
	return mgr != null and mgr.mode == Mode.CLIENT

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
		elif arg.begins_with("--travel="):
			if not result.has("travels"):
				result["travels"] = []
			(result["travels"] as Array).append(arg.get_slice("=", 1))
		elif arg.begins_with("--floor-op="):
			if not result.has("floor_ops"):
				result["floor_ops"] = []
			(result["floor_ops"] as Array).append(arg.get_slice("=", 1))
		elif arg.begins_with("--build-op="):
			if not result.has("build_ops"):
				result["build_ops"] = []
			(result["build_ops"] as Array).append(arg.get_slice("=", 1))
		elif arg.begins_with("--struct-op="):
			if not result.has("struct_ops"):
				result["struct_ops"] = []
			(result["struct_ops"] as Array).append(arg.get_slice("=", 1))
		elif arg.begins_with("--autosave="):
			result["autosave"] = arg.get_slice("=", 1).to_float()
		elif arg.begins_with("--shutdown-after="):
			result["shutdown_after"] = arg.get_slice("=", 1).to_float()
		elif arg.begins_with("--build-place="):
			# Legacy single-op form: x,y:id -> block place.
			if not result.has("build_ops"):
				result["build_ops"] = []
			var spec := arg.get_slice("=", 1).split(":")
			(result["build_ops"] as Array).append(
				"place:%s:block:%s" % [spec[0], spec[1] if spec.size() > 1 else "standard_block"])
		elif arg.begins_with("--build-remove="):
			if not result.has("build_ops"):
				result["build_ops"] = []
			(result["build_ops"] as Array).append(
				"remove:%s" % arg.get_slice("=", 1))
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
	_debug_ops = _parse_build_ops(args.get("build_ops", []))
	_debug_struct_ops = _parse_struct_ops(args.get("struct_ops", []))
	_debug_floor_ops = _parse_floor_ops(args.get("floor_ops", []))
	for travel in args.get("travels", []):
		_debug_travels.append(StringName(str(travel)))
	_autosave_interval = float(args.get("autosave", 60.0))
	_shutdown_after = float(args.get("shutdown_after", 0.0))

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
	_run_debug_struct_ops()
	_run_debug_floor_ops()
	# --travel=<floor_id> (repeatable): request floor transitions in
	# order once the client is world-synced and not mid-transition.
	if mode == Mode.CLIENT and world_synced and not _transition_pending \
			and not _debug_travels.is_empty():
		var next_travel := StringName(str(_debug_travels[0]))
		_debug_travels.remove_at(0)
		var ok := request_floor_transition(next_travel)
		print("MultiplayerManager: --travel '%s' request -> %s" % [next_travel, ok])
	# Phase D: dedicated-server autosave + debug shutdown timer.
	# Synchronous saves run on the main thread — a floor mutated
	# mid-save simply re-marks dirty and is picked up next interval.
	if dedicated_server and not _shutting_down:
		if _shutdown_after > 0.0:
			_shutdown_elapsed += delta
			if _shutdown_elapsed >= _shutdown_after:
				_shutdown_elapsed = -1.0
				print("MultiplayerManager: --shutdown-after reached; quitting (shutdown save runs on exit).")
				get_tree().quit()
		if _autosave_interval > 0.0:
			_autosave_elapsed += delta
			if _autosave_elapsed >= _autosave_interval:
				_autosave_elapsed = 0.0
				_run_autosave()
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
## positions, furniture/carpet/tile counts) for --dump-world. On the
## server every materialized floor world is dumped (tagged by floor);
## clients only ever host their own floor's replica.
func _dump_world_state(tag: String) -> void:
	var fm := _world.floor_manager
	var worlds: Array = []
	var world_floors := {}
	if _world.room_world != null:
		worlds.append(_world.room_world)
		if fm != null and fm.active_floor != null:
			world_floors[_world.room_world] = fm.active_floor.floor_id
	if mode == Mode.SERVER and fm != null:
		for floor_id in fm.runtime_worlds:
			var w: RoomWorld = fm.runtime_worlds[floor_id]
			if w != null and not worlds.has(w):
				worlds.append(w)
				world_floors[w] = floor_id
	if mode == Mode.SERVER and not _peer_floor.is_empty():
		var floors := {}
		for peer_id in _peer_floor:
			floors[peer_id] = _peer_floor[peer_id]
		print("WORLD_DUMP %s peer_floors=%s" % [tag, floors])
	for world in worlds:
		_dump_world_rooms(tag, world, world_floors.get(world, &"?"))

func _dump_world_rooms(tag: String, world: RoomWorld, floor_id: StringName) -> void:
	for room in world.get_rooms():
		var counts: Dictionary = room.placed_content_counts()
		var blocks: Array[String] = []
		if room.block_layer != null:
			for block in room.block_layer.blocks:
				blocks.append("%s@%s(e=%.2f)" % [block.block_id,
					block.grid_position, block.elevation])
		# Anomalous tile overrides only (non-default id or nonzero
		# elevation) — matches placed_content_counts' "tiles" rule.
		var tiles: Array[String] = []
		var carpets: Array[String] = []
		var default_tile_id := StringName()
		if room.default_tile != null:
			default_tile_id = room.default_tile.object_id
		for local_cell in room.cells:
			var cell := room.get_cell(local_cell)
			if cell == null:
				continue
			if cell.tile != null \
					and (cell.tile.object_id != default_tile_id \
						or not is_equal_approx(cell.tile_elevation, 0.0)):
				tiles.append("%s@%s(e=%.2f)" % [
					cell.tile.object_id, local_cell, cell.tile_elevation])
			if cell.carpet != null and cell.carpet_anchor == local_cell:
				carpets.append("%s@%s" % [cell.carpet.object_id, local_cell])
		print("WORLD_DUMP %s floor=%s room=%s size=%s blocks=[%s] tiles=[%s] carpets=[%s] contents=%s" % [
			tag, floor_id,
			room.room_coordinates, room.size, ", ".join(blocks),
			", ".join(tiles), ", ".join(carpets), counts])
	var conns: Array = world.connections.serialize_all()
	print("WORLD_DUMP %s floor=%s connections=%d" % [tag, floor_id, conns.size()])

func _exit_tree() -> void:
	if multiplayer != null and multiplayer.multiplayer_peer != null:
		multiplayer.multiplayer_peer.close()

# ------------------------------------------------------------------
# Server persistence (Phase D)
# ------------------------------------------------------------------

## Periodic autosave: writes every dirty floor through
## FloorManager.save_all_dirty — unchanged floors are skipped, failed
## floors stay dirty for the next interval. Synchronous by design:
## saves are small JSON writes and concurrency would risk corruption.
func _run_autosave() -> void:
	var fm := _world.floor_manager if _world != null else null
	if fm == null:
		return
	var started := Time.get_ticks_msec()
	var result := fm.save_all_dirty()
	var elapsed := Time.get_ticks_msec() - started
	var saved := (result["saved"] as Array).size()
	var failed := (result["failed"] as Array).size()
	if saved > 0 or failed > 0:
		print("MultiplayerManager: autosave — %d floor(s) saved, %d failed in %d ms." % [
			saved, failed, elapsed])
	if failed > 0:
		push_warning("MultiplayerManager: autosave failed for floors %s; they stay dirty." % [
			result["failed"]])

## Reliable shutdown save for the dedicated server: stops accepting
## new world mutations, then persists every dirty floor (contents,
## connections, layout, manifest). The floor catalog itself is already
## durable — floor_def.json/floor deletes are written eagerly per op.
## Called from WorldBootstrap on quit/close-request; an abrupt kill
## (taskkill /F, power loss) bypasses it — autosave bounds the loss.
func shutdown_save() -> void:
	if mode != Mode.SERVER or _shutting_down:
		return
	_shutting_down = true
	var fm := _world.floor_manager if _world != null else null
	if fm == null:
		return
	var started := Time.get_ticks_msec()
	var result := fm.save_all_dirty()
	var elapsed := Time.get_ticks_msec() - started
	var saved := (result["saved"] as Array).size()
	var failed := (result["failed"] as Array).size()
	print("MultiplayerManager: shutdown save — %d floor(s) saved, %d failed in %d ms." % [
		saved, failed, elapsed])
	if failed > 0:
		push_warning("MultiplayerManager: shutdown save failed for floors %s." % [
			result["failed"]])

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

## Builds the authoritative snapshot for the peer's CURRENT floor and
## streams it as reliable JSON chunks. Generated per join/transition
## so a player always receives current state, not a stale copy.
## purpose is "join" (first sync — replies _rpc_world_ready) or
## "travel" (floor transition — applies + places, no world_ready).
func _send_world_snapshot(peer_id: int, snapshot: Dictionary = {},
		purpose := "join") -> void:
	if snapshot.is_empty():
		snapshot = WorldSnapshot.build(_world.floor_manager, _world.room_world)
	if snapshot.is_empty():
		push_error("MultiplayerManager: cannot snapshot world for peer %d." % peer_id)
		return
	var bytes := JSON.stringify(snapshot).to_utf8_buffer()
	var total := maxi(1, ceili(float(bytes.size()) / SNAPSHOT_CHUNK_SIZE))
	var snap_id := _snapshot_serial
	_snapshot_serial += 1
	_rpc_snapshot_begin.rpc_id(peer_id, snap_id, total, purpose)
	for index in range(total):
		var part := bytes.slice(index * SNAPSHOT_CHUNK_SIZE,
			mini((index + 1) * SNAPSHOT_CHUNK_SIZE, bytes.size()))
		_rpc_snapshot_chunk.rpc_id(peer_id, snap_id, index, part)
	_rpc_snapshot_end.rpc_id(peer_id, snap_id)
	print("MultiplayerManager: snapshot for peer %d sent (%d bytes, %d chunk(s))." % [
		peer_id, bytes.size(), total])

## The floor the bound room_world currently hosts (the boot/active
## floor — the only floor that never gets a runtime_worlds entry).
func _primary_floor_id() -> StringName:
	var fm := _world.floor_manager if _world != null else null
	if fm != null and fm.active_floor != null:
		return fm.active_floor.floor_id
	return &""

## RoomWorld hosting a floor: the bound world for the active floor,
## a runtime_worlds entry otherwise.
func _world_for_floor(floor_id: StringName) -> RoomWorld:
	if _world == null or _world.floor_manager == null:
		return null
	return _world.floor_manager.world_for_floor(floor_id)

## RoomWorld a peer's body lives in (its current floor).
func _world_for_peer(peer_id: int) -> RoomWorld:
	return _world_for_floor(_peer_floor.get(peer_id, _primary_floor_id()))

## floor_id a peer's body currently occupies.
func _floor_id_for_peer(peer_id: int) -> StringName:
	return _peer_floor.get(peer_id, _primary_floor_id())

## Client acknowledged its snapshot: now the peer gets a body and the
## usual spawn broadcast.
func _complete_peer_join(peer_id: int) -> void:
	var body := _spawn_body(peer_id)
	if body == null:
		return
	_peer_floor[peer_id] = _primary_floor_id()
	# Tell the joiner where to stand and who else is already there.
	# Each entry carries its floor_id so the client only spawns
	# avatars for players sharing its floor.
	var states: Array = []
	for other_id in _bodies:
		if other_id == peer_id:
			continue
		var other: Player = _bodies[other_id]
		# The joiner always lands on the primary floor — only peers
		# sharing it may appear in its welcome state, or a same-named
		# room id on another floor would spawn a phantom avatar.
		if _floor_id_for_peer(other_id) != _primary_floor_id():
			continue
		states.append([other_id, _floor_id_for_peer(other_id),
			other.room.room_coordinates,
			other.grid_position, other.elevation, other.facing_direction])
	_rpc_welcome.rpc_id(peer_id, body.room.room_coordinates,
		body.grid_position, body.elevation, body.facing_direction, states)
	# Everyone else learns about the new player (the joiner ignores
	# its own id in _rpc_spawn_player).
	_rpc_spawn_player.rpc(peer_id, _primary_floor_id(),
		body.room.room_coordinates,
		body.grid_position, body.elevation, body.facing_direction)
	print("MultiplayerManager: peer %d joined (%d player(s) total)." % [peer_id, _bodies.size()])

func _on_peer_disconnected(peer_id: int) -> void:
	if mode != Mode.SERVER:
		return
	_pending_peers.erase(peer_id)
	_build_op_max.erase(peer_id)
	_peer_floor.erase(peer_id)
	_transition_inflight.erase(peer_id)
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
	body.room_world = _world.room_world
	# Spawn at a random spawn point of the primary floor — the same
	# rule as single-player floor entries; the welcome RPC hands the
	# joiner this exact position. Falls back to cloning the server's
	# own avatar when no placement resolves.
	var fm := _world.floor_manager
	var placement := fm.spawn_placement_for(fm.active_floor, _world.room_world) \
		if fm != null and fm.active_floor != null else {}
	var spawn_room: Room = null
	var spawn_cell := Vector2i.ZERO
	var use_spawn := not placement.is_empty()
	if use_spawn:
		spawn_room = placement["room"]
		spawn_cell = placement["cell"]
	else:
		spawn_room = local.room
		spawn_cell = local.grid_position
	_world.room_world.entity_layer.add_child(body)
	body.block_layer = spawn_room.block_layer
	body.room = spawn_room
	body.room_size = spawn_room.size
	if use_spawn:
		body.place_at(spawn_cell, body.stand_elevation_at(spawn_cell))
	else:
		body.grid_position = spawn_cell
		body.elevation = local.elevation
	body.authoritative_state_changed.connect(_on_body_state_changed.bind(peer_id))
	_bodies[peer_id] = body
	return body

func _on_body_state_changed(peer_id: int) -> void:
	var body: Player = _bodies.get(peer_id)
	if body == null or body.room == null:
		return
	_rpc_player_state.rpc(peer_id, _floor_id_for_peer(peer_id),
		body.room.room_coordinates,
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
	_pending_struct_ops.clear()
	_pending_build_ops.clear()
	_transition_pending = false
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

## Places the local player at the server-authoritative transition
## spawn and clears every avatar — the client just changed floors, so
## only players the server re-spawns for the new floor may appear.
func _apply_transition_spawn(spawn: Variant) -> void:
	for peer_id in _avatars.keys():
		_remove_avatar(peer_id)
	var player := _local_player()
	if player == null or not (spawn is Dictionary):
		return
	var room_id := _vec2i_from_payload(spawn.get("room_id"))
	var room := _room_for_id(room_id)
	if room == null:
		push_warning("MultiplayerManager: transition spawn room %s missing; kept entry placement." % room_id)
		return
	player.room_world = _world.room_world
	player.room = room
	player.block_layer = room.block_layer
	player.room_size = room.size
	player.place_at(_vec2i_from_payload(spawn.get("cell")),
		float(spawn.get("elevation", 0.0)))

static func _vec2i_from_payload(value: Variant) -> Vector2i:
	if value is Vector2i:
		return value
	if value is Array and (value as Array).size() == 2:
		return Vector2i(int(value[0]), int(value[1]))
	return Vector2i.ZERO

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
	player.room_world = _world.room_world
	player.room = target_room
	player.block_layer = target_room.block_layer
	player.room_size = target_room.size
	player.place_at(cell, cell_elevation)

func _spawn_avatar(peer_id: int, floor_id: StringName, room_id: Vector2i,
		cell: Vector2i, cell_elevation: float, face: Vector2i) -> void:
	if _avatars.has(peer_id):
		return
	# Only players sharing this client's floor get an avatar — room
	# ids collide across floors, so the floor check is mandatory.
	if _my_floor_id != &"" and floor_id != _my_floor_id:
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
	avatar.room_world = _world.room_world
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
		print("MultiplayerManager: avatar for peer %d despawned." % peer_id)
	_avatars.erase(peer_id)

# ------------------------------------------------------------------
# World snapshot sync (server -> joining client, chunked + reliable)
# ------------------------------------------------------------------

@rpc("authority", "call_remote", "reliable")
func _rpc_snapshot_begin(snap_id: int, total_chunks: int, purpose := "join") -> void:
	if multiplayer.is_server():
		return
	_rx_snapshots[snap_id] = {"total": total_chunks, "parts": {}, "purpose": purpose}

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
	var purpose := String(rx.get("purpose", "join"))
	var parts: Dictionary = rx["parts"]
	var total := int(rx["total"])
	var bytes := PackedByteArray()
	for index in range(total):
		var part: Variant = parts.get(index)
		if part == null:
			push_error("MultiplayerManager: snapshot %d missing chunk %d; world NOT synced." % [snap_id, index])
			if purpose == "travel":
				_abort_pending_transition()
			return
		bytes.append_array(part)
	var parsed: Variant = JSON.parse_string(bytes.get_string_from_utf8())
	if not (parsed is Dictionary):
		push_error("MultiplayerManager: snapshot %d is not valid JSON; world NOT synced." % snap_id)
		if purpose == "travel":
			_abort_pending_transition()
		return
	if not WorldSnapshot.apply(_world.floor_manager, _world.room_world,
			_world.player, parsed):
		push_error("MultiplayerManager: world snapshot %d failed to apply; client stays unready." % snap_id)
		if purpose == "travel":
			_abort_pending_transition()
		return
	_my_floor_id = StringName(str(parsed.get("floor_id", "")))
	_local_state_history.clear()
	_synced_msec = Time.get_ticks_msec()
	if purpose == "travel":
		_complete_travel_snapshot(parsed)
		return
	world_synced = true
	if _world.player != null:
		_world.player.local_input_locked = false
	print("MultiplayerManager: world snapshot applied; client ready.")
	_rpc_world_ready.rpc_id(1)
	_flush_pending_struct_ops()
	_flush_pending_build_ops()

## Travel-snapshot epilogue, split out of _rpc_snapshot_end so tests
## can drive it without ENet. The world was already applied by
## WorldSnapshot.apply — this places the spawn and resolves the
## client-side transition request.
##
## transition_id decides whether the snapshot may COMPLETE the live
## request: the snapshot is always authoritative (world + spawn
## applied — the server already committed, dropping it would
## diverge), but a stale snapshot — an older request's, or one
## arriving after the timeout released the wait — must not clear a
## newer pending transition, unlock input early, or report success
## for the wrong request.
func _complete_travel_snapshot(parsed: Dictionary) -> void:
	var tid := int(parsed.get("transition_id", 0))
	var was_pending := _transition_pending
	var matches := was_pending and tid == _transition_request_serial
	# Floor transition: place the local player at the
	# server-authoritative spawn and drop every avatar — players
	# on the old floor are no longer visible; occupants of the new
	# floor arrive via rpc_id spawn states right after this.
	_apply_transition_spawn(parsed.get("spawn", {}))
	if not was_pending or matches:
		_transition_pending = false
		if _world.player != null:
			_world.player.local_input_locked = false
	print("MultiplayerManager: floor transition to '%s' applied." % _my_floor_id)
	if matches:
		transition_result.emit(true, &"")
	elif was_pending:
		print("MultiplayerManager: stale travel snapshot applied; newer transition still pending.")
	else:
		print("MultiplayerManager: late travel snapshot applied after transition wait expired.")
	# Ack every applied transition snapshot so the server releases
	# its in-flight guard — including late ones after a client
	# timeout, since the server already committed the transition.
	if tid > 0:
		_rpc_transition_done.rpc_id(1, tid)
	_flush_pending_struct_ops()
	_flush_pending_build_ops()

## Aborts a travel transition whose snapshot never applied cleanly
## (missing chunk, bad JSON, apply failure): the world was never
## replaced, so unlock input, report failure, and replay the struct/
## build ops queued while the transition was in flight.
func _abort_pending_transition() -> void:
	_transition_pending = false
	if _world != null and _world.player != null:
		_world.player.local_input_locked = false
	transition_result.emit(false, &"apply_failed")
	_flush_pending_struct_ops()
	_flush_pending_build_ops()

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
	return mode == Mode.CLIENT and _connected and world_synced \
		and not _transition_pending

## Client -> server: request to move the local player to another
## floor. The server validates, rebuilds only THIS peer's world, and
## replies with a per-player snapshot — other players are unaffected.
func request_floor_transition(floor_id: StringName) -> bool:
	if mode != Mode.CLIENT or not _connected or not world_synced \
			or _transition_pending or floor_id == &"" or floor_id == _my_floor_id:
		return false
	_begin_client_transition()
	_rpc_floor_transition_request.rpc_id(1, floor_id, _transition_request_serial)
	return true

## Client -> server: request a floor transition through the portal
## standing on world_cell. Only the CELL travels — the server resolves
## the portal on the peer's authoritative floor and derives the
## destination itself, so a forged request cannot pick an arbitrary
## floor.
func request_portal_transition(world_cell: Vector2i) -> bool:
	if mode != Mode.CLIENT or not _connected or not world_synced \
			or _transition_pending:
		return false
	_begin_client_transition()
	_rpc_portal_transition_request.rpc_id(1, world_cell, _transition_request_serial)
	return true

## Shared client-side transition preamble: lock input, arm the
## timeout watchdog and bump the request serial.
func _begin_client_transition() -> void:
	_transition_pending = true
	_transition_request_serial += 1
	if _world != null and _world.player != null:
		_world.player.local_input_locked = true
	transition_requested.emit()
	var serial := _transition_request_serial
	get_tree().create_timer(transition_timeout).timeout.connect(
		_on_transition_timeout.bind(serial))

## Transition watchdog: if no destination snapshot (or rejection)
## arrived within transition_timeout, release the client instead of
## leaving it locked forever. A late snapshot still applies (the
## server already committed) but no longer reports success — see
## _rpc_snapshot_end's was_pending gate.
func _on_transition_timeout(serial: int) -> void:
	if serial != _transition_request_serial or not _transition_pending:
		return
	_transition_pending = false
	if _world != null and _world.player != null:
		_world.player.local_input_locked = false
	push_warning("MultiplayerManager: floor transition timed out after %.1fs; releasing client." % transition_timeout)
	transition_result.emit(false, &"timeout")
	# The world never changed — replay ops queued while pending.
	_flush_pending_struct_ops()
	_flush_pending_build_ops()

## Client -> server: place any synchronized category. category is one
## of BuildOps.CATEGORIES; rotation/flip apply to furniture/carpet.
func request_build_place(room_id: Vector2i, cell: Vector2i,
		category: StringName, object_id: StringName,
		rotation: int = 0, flip: bool = false) -> bool:
	if not can_request_build():
		return false
	_build_op_serial += 1
	_rpc_build_place.rpc_id(1, _build_op_serial, {
		"room_id": room_id, "cell": cell, "category": category,
		"object_id": object_id, "rotation": rotation, "flip": flip})
	return true

## Client -> server: remove the occupant the requester saw at cell.
## The identity fields must match what topmost_at() reported so a
## changed topmost target rejects as stale.
func request_build_remove(room_id: Vector2i, cell: Vector2i,
		category: StringName, object_id: StringName,
		pos: Vector2i = Vector2i.ZERO, elev: float = 0.0,
		anchor: Vector2i = Vector2i.ZERO, rotation: int = 0,
		flip: bool = false) -> bool:
	if not can_request_build():
		return false
	_build_op_serial += 1
	_rpc_build_remove.rpc_id(1, _build_op_serial, {
		"room_id": room_id, "cell": cell, "category": category,
		"object_id": object_id, "pos": pos, "elev": elev,
		"anchor": anchor, "rotation": rotation, "flip": flip})
	return true

## World cells occupied by every player body IN THE GIVEN WORLD plus
## the server's own avatar when it lives there — placement/removal
## must not target any of them. Bodies on other floors share the same
## global cell space but must not block each other.
func _player_world_cells(world: RoomWorld) -> Array:
	var cells: Array = []
	for peer_id in _bodies:
		var body: Player = _bodies[peer_id]
		if body == null or not is_instance_valid(body) or body.room == null:
			continue
		if _world_for_peer(peer_id) != world:
			continue
		cells.append(body.room.world_cell_coordinates(body.grid_position))
	var local := _local_player()
	if local != null and local.room != null and _world.room_world == world:
		cells.append(local.room.world_cell_coordinates(local.grid_position))
	return cells

## Per-peer op-id dedup: reliable RPCs do not duplicate deliveries,
## but a resent/replayed request must never apply twice. Op ids are
## monotonic per client session, so rejecting anything at or below the
## highest id seen closes the replay window permanently.
func _claim_build_op(peer_id: int, op_id: int) -> bool:
	if op_id <= 0:
		return false
	var max_seen := int(_build_op_max.get(peer_id, 0))
	if op_id <= max_seen:
		return false
	_build_op_max[peer_id] = op_id
	return true

func _reject_build(peer_id: int, op_id: int, reason: StringName) -> void:
	_rpc_build_result.rpc_id(peer_id, op_id, false, reason, {})
	print("MultiplayerManager: build op %d from peer %d rejected: %s" % [
		op_id, peer_id, reason])

# ------------------------------------------------------------------
# Floor transitions (Phase C2): per-player, server-authoritative.
# The server keeps one RoomWorld per occupied floor; a transition
# rebinds only the requesting peer's body and sends that peer a
# private snapshot. Nobody else's world or position changes.
# ------------------------------------------------------------------

## Client -> server: move my body to floor_id. transition_id is the
## client's request serial — echoed back inside the travel snapshot
## so stale snapshots can be told apart from the live request.
@rpc("any_peer", "call_remote", "reliable")
func _rpc_floor_transition_request(floor_id: StringName, transition_id: int) -> void:
	if mode != Mode.SERVER:
		return
	_handle_floor_transition(multiplayer.get_remote_sender_id(), floor_id, transition_id)

## Client -> server: step onto the floor portal at world_cell. The
## server validates the portal against the peer's authoritative floor
## and body position, then derives the destination itself.
@rpc("any_peer", "call_remote", "reliable")
func _rpc_portal_transition_request(world_cell: Vector2i, transition_id: int) -> void:
	if mode != Mode.SERVER:
		return
	_handle_portal_transition(multiplayer.get_remote_sender_id(), world_cell, transition_id)

## Client -> server: the travel snapshot carrying transition_id was
## applied locally — the transition is resolved and the server-side
## in-flight guard may be released. Id-matched so an ack for an old
## transition cannot clear a newer one.
@rpc("any_peer", "call_remote", "reliable")
func _rpc_transition_done(transition_id: int) -> void:
	if mode != Mode.SERVER:
		return
	var peer_id := multiplayer.get_remote_sender_id()
	_release_transition_guard(peer_id, transition_id)

## Releases a peer's in-flight transition guard, but only when the
## ack's transition_id matches the unresolved request — an ack for
## an older transition must not clear a newer one.
func _release_transition_guard(peer_id: int, transition_id: int) -> void:
	var inflight: Variant = _transition_inflight.get(peer_id)
	if inflight is Dictionary and int(inflight.get("id", 0)) == transition_id:
		_transition_inflight.erase(peer_id)

## Server -> requester only: transition refused; local input unlocks.
@rpc("authority", "call_remote", "reliable")
func _rpc_floor_transition_rejected(reason: StringName) -> void:
	if multiplayer.is_server():
		return
	_transition_pending = false
	if _world != null and _world.player != null:
		_world.player.local_input_locked = false
	transition_result.emit(false, reason)
	# The world never changed — replay any structural broadcasts that
	# arrived while the transition was in flight.
	_flush_pending_struct_ops()
	_flush_pending_build_ops()

func _reject_transition(peer_id: int, reason: StringName) -> void:
	_rpc_floor_transition_rejected.rpc_id(peer_id, reason)
	print("MultiplayerManager: floor transition for peer %d rejected: %s" % [
		peer_id, reason])

## Server-side portal transition validation. The client sends only
## the cell it believes hosts a portal; everything else is checked
## against authoritative state:
##   - the peer's floor comes from _peer_floor, never the request;
##   - the portal must exist on THAT floor at the claimed cell;
##   - the destination comes from the portal definition, never the
##     request — a forged packet cannot pick an arbitrary floor;
##   - the peer's body must actually stand on the portal's world cell
##     (movement is server-validated via _rpc_move_request ->
##     body.request_move, so body.room/grid_position are current).
## On success the request delegates to the shared C2 handler.
func _handle_portal_transition(peer_id: int, world_cell: Vector2i,
		transition_id := 0) -> void:
	if _shutting_down:
		_reject_transition(peer_id, &"shutting_down")
		return
	var body: Player = _bodies.get(peer_id)
	if body == null:
		_reject_transition(peer_id, &"not_ready")
		return
	var fm := _world.floor_manager if _world != null else null
	if fm == null:
		_reject_transition(peer_id, &"no_floor_manager")
		return
	var peer_floor := _floor_id_for_peer(peer_id)
	var floor_def := fm.get_floor(peer_floor)
	if floor_def == null:
		_reject_transition(peer_id, &"unknown_floor")
		return
	var portal := fm.portal_at_on_floor(peer_floor, world_cell)
	if portal == null:
		_reject_transition(peer_id, &"no_portal")
		return
	if body.room == null:
		_reject_transition(peer_id, &"no_body_room")
		return
	if body.room.world_cell_coordinates(body.grid_position) != portal.world_cell:
		_reject_transition(peer_id, &"not_at_portal")
		return
	var destination := portal.destination_floor_id
	if destination == peer_floor:
		_reject_transition(peer_id, &"already_there")
		return
	if fm.get_floor(destination) == null:
		_reject_transition(peer_id, &"unknown_floor")
		return
	_handle_floor_transition(peer_id, destination, transition_id)

## Validates and applies a floor transition for one peer. Every
## failure rejects without touching the peer's body or any world.
func _handle_floor_transition(peer_id: int, floor_id: StringName,
		transition_id := 0) -> void:
	if _shutting_down:
		_reject_transition(peer_id, &"shutting_down")
		return
	# In-flight guard: while a peer's previous transition is
	# unresolved (committed but not yet acked by the client via
	# _rpc_transition_done), every new request rejects "busy".
	# Validation rejections below never acquire the guard, and the
	# TRANSITION_INFLIGHT_TIMEOUT_MS safety window keeps a lost ack
	# from blocking the peer forever. Other peers are unaffected.
	var now := Time.get_ticks_msec()
	var inflight: Variant = _transition_inflight.get(peer_id)
	if inflight is Dictionary:
		if now - int(inflight.get("msec", 0)) < TRANSITION_INFLIGHT_TIMEOUT_MS:
			_reject_transition(peer_id, &"busy")
			return
		_transition_inflight.erase(peer_id)
	var body: Player = _bodies.get(peer_id)
	if body == null:
		_reject_transition(peer_id, &"not_ready")
		return
	var fm := _world.floor_manager
	if fm == null:
		_reject_transition(peer_id, &"no_floor_manager")
		return
	var dest_def := fm.get_floor(floor_id)
	if dest_def == null:
		_reject_transition(peer_id, &"unknown_floor")
		return
	var current_id := _floor_id_for_peer(peer_id)
	if current_id == floor_id:
		_reject_transition(peer_id, &"already_there")
		return
	# Destination world: reuse the live instance or materialize the
	# floor into a fresh configured RoomWorld (first visit pays the
	# build+hydrate cost once; later visits reuse it).
	var dest_world := fm.world_for_floor(floor_id)
	if dest_world == null:
		dest_world = _world.create_floor_world(floor_id)
		if dest_world == null or not fm.materialize_runtime_floor(floor_id, dest_world):
			if dest_world != null:
				dest_world.queue_free()
			_reject_transition(peer_id, &"load_failed")
			return
	# Persist the floor being left (rooms + connections only — player
	# positions are not world state and bodies have no save format).
	var out_world := _world_for_floor(current_id)
	if out_world != null and out_world != dest_world:
		out_world.save_room_states()
	# Rebind the body into the destination world at a random spawn
	# point (spawn_placement_for — same rule as single-player floor
	# entries; the pick is per-player and shipped in the snapshot).
	var placement := fm.spawn_placement_for(dest_def, dest_world)
	if placement.is_empty():
		_reject_transition(peer_id, &"no_entry_room")
		return
	var entry: Room = placement["room"]
	var spawn: Vector2i = placement["cell"]
	# Build the destination snapshot BEFORE mutating anything: a
	# preparation failure must reject cleanly with no guard held,
	# no reparent and no floor change.
	var snapshot := WorldSnapshot.build(fm, dest_world, dest_def)
	if snapshot.is_empty():
		_reject_transition(peer_id, &"snapshot_failed")
		return
	# Set the peer's floor BEFORE place_at: it emits
	# authoritative_state_changed, and _on_body_state_changed resolves
	# the broadcast floor through _floor_id_for_peer. The in-flight
	# guard is acquired at this commit point — the transition is now
	# unresolved until the client acks the snapshot or the safety
	# window expires.
	_transition_inflight[peer_id] = {"id": transition_id, "msec": now}
	_peer_floor[peer_id] = floor_id
	if body.get_parent() != null:
		body.get_parent().remove_child(body)
	dest_world.entity_layer.add_child(body)
	body.grid = dest_world.grid
	body.room_world = dest_world
	body.room = entry
	body.block_layer = entry.block_layer
	body.room_size = entry.size
	# Despawn BEFORE place_at: place_at emits authoritative_state_changed,
	# whose broadcast makes floor-mates spawn this player's avatar on the
	# new floor. A despawn sent after it would wipe that fresh avatar and
	# the player would stay invisible until their next move.
	_rpc_despawn_player.rpc(peer_id)
	body.place_at(spawn, body.stand_elevation_at(spawn))
	# Hand the requester a private snapshot of the destination world
	# plus spawn info and the definitions of players already there.
	# transition_id ties the snapshot back to the client's request
	# serial so stale snapshots cannot complete a newer pending
	# transition.
	snapshot["spawn"] = {
		"room_id": [entry.room_coordinates.x, entry.room_coordinates.y],
		"cell": [spawn.x, spawn.y],
		"elevation": body.elevation}
	snapshot["transition_id"] = transition_id
	_send_world_snapshot(peer_id, snapshot, "travel")
	for other_id in _bodies:
		if other_id == peer_id or _floor_id_for_peer(other_id) != floor_id:
			continue
		var other: Player = _bodies[other_id]
		if other == null or other.room == null:
			continue
		_rpc_spawn_player.rpc_id(peer_id, other_id, floor_id,
			other.room.room_coordinates, other.grid_position,
			other.elevation, other.facing_direction)
	print("MultiplayerManager: peer %d transitioned %s -> %s." % [
		peer_id, current_id, floor_id])

# ------------------------------------------------------------------
# Build op RPCs
# ------------------------------------------------------------------

@rpc("any_peer", "call_remote", "reliable")
func _rpc_build_place(op_id: int, request: Dictionary) -> void:
	if mode != Mode.SERVER or _shutting_down:
		return
	var sender := multiplayer.get_remote_sender_id()
	if not _claim_build_op(sender, op_id):
		_reject_build(sender, op_id, &"duplicate")
		return
	# A body exists only after the peer acknowledged its snapshot.
	if not _bodies.has(sender):
		_reject_build(sender, op_id, &"not_ready")
		return
	# The op applies in the world hosting the SENDER's floor — room
	# ids are only unique per floor.
	var world := _world_for_peer(sender)
	if world == null:
		_reject_build(sender, op_id, &"unknown_floor")
		return
	var result := BuildOps.validate_place_any(world,
		_player_world_cells(world), request)
	if not bool(result.get("ok", false)):
		_reject_build(sender, op_id, result.get("reason", &"invalid"))
		return
	var room: Room = result["room"]
	var cell: Vector2i = request.get("cell", Vector2i.ZERO)
	var category := StringName(str(request.get("category", "block")))
	var object_id := StringName(str(request.get("object_id", "")))
	var rotation := BuildOps.req_int(request.get("rotation"))
	var flip := BuildOps.req_bool(request.get("flip"))
	var applied: Variant = BuildOps.apply_place_any(world, room,
		category, cell, object_id, float(result["elevation"]), rotation, flip)
	# Blocks/furniture return the placed node (or null); carpet/tile
	# return bool — comparing an Object to false is a runtime error.
	if applied == null or (applied is bool and applied == false):
		_reject_build(sender, op_id, &"apply_failed")
		return
	# Broadcast AFTER the authoritative apply; every synced client
	# reproduces it locally without generating another request.
	_rpc_build_result.rpc(op_id, true, &"", {
		"kind": "place", "room_id": request.get("room_id", Vector2i.ZERO),
		"floor_id": _floor_id_for_peer(sender),
		"cell": cell, "category": category,
		"object_id": object_id,
		"elevation": result["elevation"], "rotation": rotation, "flip": flip})
	print("MultiplayerManager: build op %d place %s %s @%s room %s applied." % [
		op_id, category, object_id, cell, request.get("room_id")])

@rpc("any_peer", "call_remote", "reliable")
func _rpc_build_remove(op_id: int, request: Dictionary) -> void:
	if mode != Mode.SERVER or _shutting_down:
		return
	var sender := multiplayer.get_remote_sender_id()
	if not _claim_build_op(sender, op_id):
		_reject_build(sender, op_id, &"duplicate")
		return
	if not _bodies.has(sender):
		_reject_build(sender, op_id, &"not_ready")
		return
	var world := _world_for_peer(sender)
	if world == null:
		_reject_build(sender, op_id, &"unknown_floor")
		return
	var result := BuildOps.validate_remove_any(world,
		_player_world_cells(world), request)
	if not bool(result.get("ok", false)):
		_reject_build(sender, op_id, result.get("reason", &"invalid"))
		return
	var room: Room = result["room"]
	var top: Dictionary = result["target"]
	var category := StringName(str(request.get("category", "")))
	var cell: Vector2i = request.get("cell", Vector2i.ZERO)
	# The broadcast carries the AUTHORITATIVE target identity, not
	# whatever the requester claimed.
	var payload := {
		"kind": "remove", "room_id": request.get("room_id", Vector2i.ZERO),
		"floor_id": _floor_id_for_peer(sender),
		"cell": cell, "category": category,
		"object_id": StringName(str(request.get("object_id", ""))),
		"pos": request.get("pos", Vector2i.ZERO),
		"elev": BuildOps.req_float(request.get("elev")),
		"anchor": request.get("anchor", Vector2i.ZERO),
		"rotation": BuildOps.req_int(request.get("rotation")),
		"flip": BuildOps.req_bool(request.get("flip"))}
	match category:
		&"block", &"furniture":
			var block: Block = top["block"]
			payload["object_id"] = block.block_id
			payload["pos"] = block.grid_position
			payload["elev"] = block.elevation
			payload["rotation"] = block.furniture_rotation_degrees \
				if block is Furniture else 0
		&"carpet":
			payload["object_id"] = (top["carpet"] as CarpetDefinition).object_id
			payload["anchor"] = top["anchor"]
			payload["rotation"] = int(top["rotation"])
			payload["flip"] = bool(top["flip"])
			payload["elev"] = float(top["elevation"])
		&"tile":
			payload["object_id"] = (top["tile"] as TileDefinition).object_id
			payload["elev"] = float(top["elevation"])
	if not BuildOps.apply_remove_any(world, room, category, cell,
			payload["object_id"], payload["pos"], payload["elev"],
			payload["anchor"], payload["rotation"], payload["flip"]):
		_reject_build(sender, op_id, &"apply_failed")
		return
	_rpc_build_result.rpc(op_id, true, &"", payload)
	print("MultiplayerManager: build op %d remove %s @%s room %s applied." % [
		op_id, category, cell, request.get("room_id")])

## Server -> all clients: authoritative build outcome. accepted=true
## carries the payload needed to reproduce the op locally; false is
## sent only to the requester so its UI can react.
@rpc("authority", "call_remote", "reliable")
func _rpc_build_result(op_id: int, accepted: bool, reason: StringName,
		payload: Dictionary) -> void:
	if multiplayer.is_server():
		return
	_handle_build_result(op_id, accepted, reason, payload)

## Client-side build-result handling, split from the RPC so tests can
## drive it without an ENet peer (same pattern as _handle_struct_result).
func _handle_build_result(op_id: int, accepted: bool, reason: StringName,
		payload: Dictionary) -> void:
	if not accepted:
		build_result.emit(op_id, false, reason)
		return
	# Not ready yet (join snapshot in flight) or mid-transition: queue
	# and let _flush_pending_build_ops apply once _my_floor_id is
	# final. Without this, ops for the DESTINATION floor that arrive
	# while the client still shows the old floor are dropped by the
	# floor filter below and lost forever — the replica then diverges
	# (missing supports -> later placements fail can_place). Reliable
	# ordering puts the snapshot ahead of this op.
	if not world_synced or _transition_pending:
		_pending_build_ops.append({"op_id": op_id, "payload": payload})
		return
	_apply_build_result(op_id, payload)

## Applies one accepted build-result payload to the local replica.
## Shared by _rpc_build_result and _flush_pending_build_ops; the floor
## filter runs here so queued ops re-check against the FINAL floor.
func _apply_build_result(op_id: int, payload: Dictionary) -> void:
	# Ops on floors this client is not visiting are irrelevant — room
	# ids are only unique per floor, so applying them blindly could
	# mutate the wrong replica.
	var payload_floor := StringName(str(payload.get("floor_id", "")))
	if payload_floor != &"" and _my_floor_id != &"" \
			and payload_floor != _my_floor_id:
		return
	var room_id: Vector2i = payload.get("room_id", Vector2i.ZERO)
	var room := _room_for_id(room_id)
	if room == null:
		push_warning("MultiplayerManager: build result for unknown room %s ignored." % room_id)
		return
	var cell: Vector2i = payload.get("cell", Vector2i.ZERO)
	var category := StringName(str(payload.get("category", "block")))
	var object_id := StringName(str(payload.get("object_id", "")))
	var applied: Variant = null
	match String(payload.get("kind", "")):
		"place":
			applied = BuildOps.apply_place_any(_world.room_world, room, category,
				cell, object_id, float(payload.get("elevation", 0.0)),
				int(payload.get("rotation", 0)), bool(payload.get("flip", false)))
		"remove":
			applied = BuildOps.apply_remove_any(_world.room_world, room, category,
				cell, object_id, payload.get("pos", Vector2i.ZERO),
				float(payload.get("elev", 0.0)),
				payload.get("anchor", Vector2i.ZERO),
				int(payload.get("rotation", 0)), bool(payload.get("flip", false)))
	# A failed local apply means this replica diverged from the
	# authoritative world — surface it instead of silently drifting.
	# The op itself WAS accepted server-side, so build_result still
	# reports success; only the local reproduction failed.
	if applied == null or (applied is bool and applied == false):
		push_warning(("MultiplayerManager: build op %d %s failed to apply locally "
			+ "(world may diverge until next snapshot).") % [op_id, payload.get("kind")])
		build_result.emit(op_id, true, &"")
		return
	print("MultiplayerManager: build op %d %s %s @%s applied on peer %d." % [
		op_id, payload.get("kind"), category, cell, my_peer_id])
	build_result.emit(op_id, true, &"")
	print("MultiplayerManager: build op %d applied locally (%s)." % [
		op_id, payload.get("kind", "?")])

## Accepted build broadcasts received before the world snapshot
## finished applying (or while a floor transition is in flight), same
## pattern as _pending_struct_ops. Flushed once _my_floor_id is final.
var _pending_build_ops: Array = []

## Replays queued build results after a snapshot/travel apply. Ops for
## floors the client does not occupy are dropped by the floor filter in
## _apply_build_result — it will get them in a later snapshot if it
## ever travels there.
func _flush_pending_build_ops() -> void:
	if _pending_build_ops.is_empty():
		return
	var queued := _pending_build_ops
	_pending_build_ops = []
	for item in queued:
		_apply_build_result(int(item.get("op_id", 0)), item.get("payload", {}))

# ------------------------------------------------------------------
# Structural room ops (Phase C3): create/delete/visibility requests
# -> server validate against the SENDER's floor world -> apply ->
# broadcast to every peer. Clients only ever mutate replicas through
# FloorManager.replica_* — never disk, never a re-request.
# ------------------------------------------------------------------

## Client UI feedback: emitted for every structural op result this
## peer receives (accepted or rejected). op_id matches the request;
## accepted payloads carry the authoritative op details (op, floor_id,
## room_id/spec/flags) so the editor can refresh precisely.
signal struct_result(op_id: int, accepted: bool, reason: StringName, payload: Dictionary)

## Client: accepted structural broadcasts received before the world
## snapshot finished applying (or while a transition is in flight).
## Flushed by _flush_pending_struct_ops once _my_floor_id is final —
## reliable ordering guarantees the snapshot itself is already applied
## by then, so ids/specs the snapshot already carried are skipped.
var _pending_struct_ops: Array = []

## True when this peer may originate structural requests.
func can_request_struct() -> bool:
	return can_request_build()

## Client -> server: create a room on the floor this peer occupies.
## spec is a FloorRoomSpec serialized via FloorSaveSystem.
## spec_to_layout_entry (the layout.json entry shape).
func request_struct_create(spec_entry: Dictionary) -> bool:
	if not can_request_struct() or not (spec_entry is Dictionary):
		return false
	_build_op_serial += 1
	_rpc_struct_op.rpc_id(1, _build_op_serial, {
		"op": "create", "floor_id": _my_floor_id, "spec": spec_entry})
	return true

## Client -> server: delete a room on this peer's floor.
func request_struct_delete(room_id: Vector2i) -> bool:
	if not can_request_struct():
		return false
	_build_op_serial += 1
	_rpc_struct_op.rpc_id(1, _build_op_serial, {
		"op": "delete", "floor_id": _my_floor_id, "room_id": room_id})
	return true

## Client -> server: set both visibility flags on a room.
func request_struct_visibility(room_id: Vector2i,
		show_from_outside: bool, show_outside: bool) -> bool:
	if not can_request_struct():
		return false
	_build_op_serial += 1
	_rpc_struct_op.rpc_id(1, _build_op_serial, {
		"op": "visibility", "floor_id": _my_floor_id,
		"room_id": room_id,
		"show_from_outside": show_from_outside,
		"show_outside": show_outside})
	return true

## Client -> server: place (place=true) or remove a spawn point at a
## global world cell on this peer's floor.
func request_struct_spawn(world_cell: Vector2i, place: bool) -> bool:
	if not can_request_struct():
		return false
	_build_op_serial += 1
	_rpc_struct_op.rpc_id(1, _build_op_serial, {
		"op": "spawn", "floor_id": _my_floor_id,
		"cell": world_cell, "place": place})
	return true

## room_id -> true for every authoritative body standing in that room
## within the given world (plus the server's own avatar when bound
## there). Delete validation must see ALL occupants — the local
## "player" group only contains the server's own avatar.
func _occupied_room_ids(world: RoomWorld) -> Dictionary:
	var occupied := {}
	for peer_id in _bodies:
		var body: Player = _bodies[peer_id]
		if body == null or not is_instance_valid(body) or body.room == null:
			continue
		if _world_for_peer(peer_id) != world:
			continue
		occupied[body.room.room_coordinates] = true
	var local := _local_player()
	if local != null and local.room != null and _world.room_world == world:
		occupied[local.room.room_coordinates] = true
	return occupied

func _reject_struct(peer_id: int, op_id: int, reason: StringName) -> void:
	_rpc_struct_result.rpc_id(peer_id, op_id, false, reason, {})
	print("MultiplayerManager: struct op %d from peer %d rejected: %s" % [
		op_id, peer_id, reason])

## Client -> server: one structural room operation. floor_id is
## validated against _peer_floor — the client never declares its own
## location authoritatively.
@rpc("any_peer", "call_remote", "reliable")
func _rpc_struct_op(op_id: int, op: Dictionary) -> void:
	if mode != Mode.SERVER:
		return
	_handle_struct_op(multiplayer.get_remote_sender_id(), op_id, op)

## Server: validate + apply + broadcast one structural op. Reuses the
## build-op dedup (_build_op_max) so op ids stay monotonic across both
## protocols — the client shares one serial for all requests.
func _handle_struct_op(peer_id: int, op_id: int, op: Dictionary) -> void:
	if _shutting_down:
		return
	if not _claim_build_op(peer_id, op_id):
		_reject_struct(peer_id, op_id, &"duplicate")
		return
	if not _bodies.has(peer_id):
		_reject_struct(peer_id, op_id, &"not_ready")
		return
	var fm := _world.floor_manager
	if fm == null:
		_reject_struct(peer_id, op_id, &"no_floor_manager")
		return
	var floor_id := StringName(str(op.get("floor_id", "")))
	# The authoritative floor is the peer's tracked floor — a request
	# naming any other floor is rejected outright.
	if floor_id == &"" or floor_id != _floor_id_for_peer(peer_id):
		_reject_struct(peer_id, op_id, &"wrong_floor")
		return
	var floor_def := fm.get_floor(floor_id)
	var world := _world_for_peer(peer_id)
	if floor_def == null or world == null:
		_reject_struct(peer_id, op_id, &"unknown_floor")
		return
	var kind := StringName(str(op.get("op", "")))
	match kind:
		&"create":
			_handle_struct_create(peer_id, op_id, fm, floor_def, world, op)
		&"delete":
			_handle_struct_delete(peer_id, op_id, fm, floor_def, world, op)
		&"visibility":
			_handle_struct_visibility(peer_id, op_id, fm, floor_def, op)
		&"spawn":
			_handle_struct_spawn(peer_id, op_id, fm, floor_def, op)
		_:
			_reject_struct(peer_id, op_id, &"unknown_op")

func _handle_struct_create(peer_id: int, op_id: int, fm: FloorManager,
		floor_def: Floor, world: RoomWorld, op: Dictionary) -> void:
	var entry: Variant = op.get("spec")
	if not (entry is Dictionary):
		_reject_struct(peer_id, op_id, &"invalid_spec")
		return
	var spec := FloorManager.spec_from_layout_entry(entry)
	if spec == null:
		_reject_struct(peer_id, op_id, &"invalid_spec")
		return
	var result := fm._add_room_to_floor(floor_def, world, spec)
	if not bool(result.get("ok", false)):
		_reject_struct(peer_id, op_id,
			StringName(str(result.get("reason", "invalid"))))
		return
	fm._persist_room_layout(floor_def)
	# Broadcast the NORMALIZED spec — origin/size were rewritten to the
	# footprint bbox, so replicas register exactly what the server did.
	var applied_spec: FloorRoomSpec = result["spec"]
	_rpc_struct_result.rpc(op_id, true, &"", {
		"op": "create", "floor_id": floor_def.floor_id,
		"requester": peer_id,
		"spec": FloorSaveSystem.spec_to_layout_entry(applied_spec)})
	print("MultiplayerManager: struct op %d create room %s on '%s' applied." % [
		op_id, applied_spec.room_id, floor_def.floor_id])

func _handle_struct_delete(peer_id: int, op_id: int, fm: FloorManager,
		floor_def: Floor, world: RoomWorld, op: Dictionary) -> void:
	var room_id := _vec2i_from_payload(op.get("room_id"))
	var occupied := _occupied_room_ids(world)
	var verdict := fm.can_delete_room_on_floor(floor_def.floor_id, room_id, occupied)
	if not bool(verdict.get("allowed", false)):
		_reject_struct(peer_id, op_id,
			StringName(str(verdict.get("reason", "invalid"))))
		return
	if not fm.remove_room_from_floor(floor_def.floor_id, room_id, occupied):
		_reject_struct(peer_id, op_id, &"apply_failed")
		return
	_rpc_struct_result.rpc(op_id, true, &"", {
		"op": "delete", "floor_id": floor_def.floor_id,
		"requester": peer_id, "room_id": room_id})
	print("MultiplayerManager: struct op %d delete room %s on '%s' applied." % [
		op_id, room_id, floor_def.floor_id])

func _handle_struct_visibility(peer_id: int, op_id: int, fm: FloorManager,
		floor_def: Floor, op: Dictionary) -> void:
	var room_id := _vec2i_from_payload(op.get("room_id"))
	var from_outside := bool(op.get("show_from_outside", true))
	var show_outside := bool(op.get("show_outside", true))
	if not fm.set_room_visibility_on_floor(floor_def.floor_id, room_id,
			from_outside, show_outside):
		_reject_struct(peer_id, op_id, &"unknown_room")
		return
	_rpc_struct_result.rpc(op_id, true, &"", {
		"op": "visibility", "floor_id": floor_def.floor_id,
		"requester": peer_id, "room_id": room_id,
		"show_from_outside": from_outside, "show_outside": show_outside})
	print("MultiplayerManager: struct op %d visibility %s on '%s' applied." % [
		op_id, room_id, floor_def.floor_id])

func _handle_struct_spawn(peer_id: int, op_id: int, fm: FloorManager,
		floor_def: Floor, op: Dictionary) -> void:
	var cell := _vec2i_from_payload(op.get("cell"))
	var place := bool(op.get("place", true))
	var ok := false
	var reason := &""
	if place:
		var verdict := fm.can_place_spawn_point_on_floor(floor_def.floor_id, cell)
		if bool(verdict.get("allowed", false)):
			ok = fm.place_spawn_point_on_floor(floor_def.floor_id, cell)
		else:
			reason = StringName(str(verdict.get("reason", "invalid")))
	else:
		var verdict := fm.can_remove_spawn_point_on_floor(floor_def.floor_id, cell)
		if bool(verdict.get("allowed", false)):
			ok = fm.remove_spawn_point_on_floor(floor_def.floor_id, cell)
		else:
			reason = StringName(str(verdict.get("reason", "invalid")))
	if not ok:
		_reject_struct(peer_id, op_id, reason if reason != &"" else &"apply_failed")
		return
	_rpc_struct_result.rpc(op_id, true, &"", {
		"op": "spawn", "floor_id": floor_def.floor_id,
		"requester": peer_id, "cell": cell, "place": place})
	print("MultiplayerManager: struct op %d spawn %s %s on '%s' applied." % [
		op_id, "place" if place else "remove", cell, floor_def.floor_id])

## Server -> all clients: authoritative structural outcome. accepted
## payloads carry floor_id; clients on other floors drop them.
@rpc("authority", "call_remote", "reliable")
func _rpc_struct_result(op_id: int, accepted: bool, reason: StringName,
		payload: Dictionary) -> void:
	if multiplayer.is_server():
		return
	_handle_struct_result(op_id, accepted, reason, payload)

## Client-side struct result handling, split from the RPC so tests can
## drive it without an ENet peer.
func _handle_struct_result(op_id: int, accepted: bool, reason: StringName,
		payload: Dictionary) -> void:
	if not accepted:
		struct_result.emit(op_id, false, reason, {})
		return
	# Not ready yet (join snapshot in flight) or mid-transition: queue
	# and let _flush_pending_struct_ops apply once _my_floor_id is
	# final. Reliable ordering puts the snapshot ahead of this op.
	if not world_synced or _transition_pending:
		_pending_struct_ops.append({"op_id": op_id, "payload": payload})
		return
	var payload_floor := StringName(str(payload.get("floor_id", "")))
	if payload_floor != &"" and _my_floor_id != &"" \
			and payload_floor != _my_floor_id:
		return
	if _apply_struct_payload(payload):
		struct_result.emit(op_id, true, &"", payload)
	else:
		push_warning(("MultiplayerManager: struct op %d %s failed to apply locally "
			+ "(world may diverge until next snapshot).") % [
				op_id, str(payload.get("op", "?"))])
		struct_result.emit(op_id, true, &"diverged", payload)

## Applies one accepted structural payload to the local replica via the
## unguarded FloorManager.replica_* ops. Idempotent against snapshots:
## a room the snapshot already carried counts as consistent, not an
## error. Returns false only on genuine divergence.
func _apply_struct_payload(payload: Dictionary) -> bool:
	if _world == null or _world.floor_manager == null or _world.room_world == null:
		return false
	var fm: FloorManager = _world.floor_manager
	var floor_id := StringName(str(payload.get("floor_id", _my_floor_id)))
	var floor_def := fm.get_floor(floor_id)
	if floor_def == null:
		push_warning("MultiplayerManager: struct op for unknown floor '%s'." % floor_id)
		return false
	var world := _world.room_world
	var room_id := _vec2i_from_payload(payload.get("room_id"))
	match StringName(str(payload.get("op", ""))):
		&"create":
			var entry: Variant = payload.get("spec")
			if not (entry is Dictionary):
				return false
			var spec := FloorManager.spec_from_layout_entry(entry)
			if spec == null:
				return false
			# Already present (snapshot carried it): consistent.
			if world.get_room(spec.room_id) != null \
					and floor_def.find_room_spec(spec.room_id) != null:
				return true
			return fm.replica_add_room(floor_id, entry) != null
		&"delete":
			# Already gone (snapshot post-dates the delete): consistent.
			if world.get_room(room_id) == null \
					and floor_def.find_room_spec(room_id) == null:
				return true
			return fm.replica_remove_room(floor_id, room_id)
		&"visibility":
			var spec := floor_def.find_room_spec(room_id)
			if spec == null:
				return false
			var from_outside := bool(payload.get("show_from_outside", true))
			var show_outside := bool(payload.get("show_outside", true))
			if spec.show_from_outside == from_outside \
					and spec.show_outside == show_outside:
				return true
			return fm.replica_set_room_visibility(floor_id, room_id,
				from_outside, show_outside)
		&"spawn":
			# Already in the target state (snapshot post-dates the op):
			# consistent, not an error.
			var cell := _vec2i_from_payload(payload.get("cell"))
			var place := bool(payload.get("place", true))
			var has_cell := fm.floor_spawn_points(floor_def).has(cell)
			if place == has_cell:
				return true
			return fm.replica_apply_spawn(floor_id, cell, place)
	return false

## Replays queued structural broadcasts after a snapshot applied —
## called from both the join path and the travel path. Ops for floors
## the client does not occupy are dropped (it will get them in a later
## snapshot if it ever travels there).
func _flush_pending_struct_ops() -> void:
	if _pending_struct_ops.is_empty():
		return
	var queued := _pending_struct_ops
	_pending_struct_ops = []
	for item in queued:
		var payload: Dictionary = item.get("payload", {})
		var payload_floor := StringName(str(payload.get("floor_id", "")))
		if payload_floor != &"" and _my_floor_id != &"" \
				and payload_floor != _my_floor_id:
			continue
		var op_id := int(item.get("op_id", 0))
		if _apply_struct_payload(payload):
			struct_result.emit(op_id, true, &"", payload)
		else:
			push_warning(("MultiplayerManager: queued struct op %d failed to apply "
				+ "after snapshot (world may diverge).") % op_id)
			struct_result.emit(op_id, true, &"diverged", payload)

# ------------------------------------------------------------------
# Floor ops (Phase C4): catalog-global create/delete requests ->
# server validate -> apply -> broadcast to EVERY peer (the floor
# catalog is not floor-scoped, so these bypass the wrong_floor check
# that room structural ops use). Clients reconcile replicas through
# register/unregister_floor_replica and the snapshot floor catalog —
# never disk, never a re-request.
# ------------------------------------------------------------------

## Client UI feedback: emitted for every floor-op result this peer
## receives. payload carries op ("floor_create"/"floor_delete"),
## floor_id, and for creates the canonical floor_def data.
signal floor_result(op_id: int, accepted: bool, reason: StringName, payload: Dictionary)

## Client -> server: create a floor. Only the id and display name are
## sent — the server derives the canonical definition (default room
## layout) via FloorManager.create_floor, so clients can never inject
## arbitrary specs.
func request_floor_create(floor_id: StringName, display_name := "") -> bool:
	if not can_request_struct() or floor_id == &"":
		return false
	_build_op_serial += 1
	_rpc_floor_op.rpc_id(1, _build_op_serial, {
		"op": "floor_create", "floor_id": floor_id,
		"display_name": display_name.left(80)})
	return true

## Client -> server: delete a floor. The server rejects while any
## peer body occupies it; there is no evacuation flow this phase.
func request_floor_delete(floor_id: StringName) -> bool:
	if not can_request_struct() or floor_id == &"":
		return false
	_build_op_serial += 1
	_rpc_floor_op.rpc_id(1, _build_op_serial, {
		"op": "floor_delete", "floor_id": floor_id})
	return true

func _reject_floor(peer_id: int, op_id: int, reason: StringName) -> void:
	_rpc_floor_result.rpc_id(peer_id, op_id, false, reason, {})
	print("MultiplayerManager: floor op %d from peer %d rejected: %s" % [
		op_id, peer_id, reason])

## Client -> server: one floor catalog operation. Unlike room struct
## ops there is no floor scoping — the catalog is global — but the
## same monotonic op-id dedup applies.
@rpc("any_peer", "call_remote", "reliable")
func _rpc_floor_op(op_id: int, op: Dictionary) -> void:
	if mode != Mode.SERVER:
		return
	_handle_floor_op(multiplayer.get_remote_sender_id(), op_id, op)

func _handle_floor_op(peer_id: int, op_id: int, op: Dictionary) -> void:
	if _shutting_down:
		return
	if not _claim_build_op(peer_id, op_id):
		_reject_floor(peer_id, op_id, &"duplicate")
		return
	if not _bodies.has(peer_id):
		_reject_floor(peer_id, op_id, &"not_ready")
		return
	var fm := _world.floor_manager
	if fm == null:
		_reject_floor(peer_id, op_id, &"no_floor_manager")
		return
	match StringName(str(op.get("op", ""))):
		&"floor_create":
			_handle_floor_create(peer_id, op_id, fm, op)
		&"floor_delete":
			_handle_floor_delete(peer_id, op_id, fm, op)
		_:
			_reject_floor(peer_id, op_id, &"unknown_op")

func _handle_floor_create(peer_id: int, op_id: int, fm: FloorManager,
		op: Dictionary) -> void:
	var floor_id := StringName(str(op.get("floor_id", "")))
	# Same id rules as FloorSaveSystem.floor_dir: empty, dot-relative,
	# or path-hostile ids can never name a save directory.
	if floor_id == &"" or FloorSaveSystem.floor_dir(floor_id).is_empty() \
			or String(floor_id).length() > 64:
		_reject_floor(peer_id, op_id, &"invalid_id")
		return
	if fm.has_floor(floor_id):
		_reject_floor(peer_id, op_id, &"duplicate_floor")
		return
	var display_name := str(op.get("display_name", "")).strip_edges()
	var floor_def := fm.create_floor(floor_id, display_name)
	if floor_def == null:
		_reject_floor(peer_id, op_id, &"invalid_floor")
		return
	# Broadcast the canonical definition (floor_def.json format) so
	# every client registers the same replica — including peers that
	# never visit the floor.
	_rpc_floor_result.rpc(op_id, true, &"", {
		"op": "floor_create", "floor_id": floor_id,
		"requester": peer_id,
		"floor_def": FloorSaveSystem.floor_definition_data(floor_def)})
	print("MultiplayerManager: floor op %d create '%s' applied." % [op_id, floor_id])

func _handle_floor_delete(peer_id: int, op_id: int, fm: FloorManager,
		op: Dictionary) -> void:
	var floor_id := StringName(str(op.get("floor_id", "")))
	var floor_def := fm.get_floor(floor_id)
	if floor_def == null:
		_reject_floor(peer_id, op_id, &"unknown_floor")
		return
	var verdict := fm.can_delete_floor(floor_id)
	if not bool(verdict.get("allowed", false)):
		_reject_floor(peer_id, op_id,
			StringName(str(verdict.get("reason", "invalid"))))
		return
	# Occupancy: any authoritative body whose tracked floor is the
	# target rejects the delete — there is no evacuation flow.
	for other_id in _bodies:
		if _floor_id_for_peer(other_id) == floor_id:
			_reject_floor(peer_id, op_id, &"occupied")
			return
	# Active-floor delete: switch the bound world to a fallback first
	# (same discipline as FloorManager.delete_floor), then migrate any
	# bodies parked in the fallback's runtime world into the bound
	# world so no floor ever has two live RoomWorlds.
	if fm.active_floor == floor_def:
		var fallback: Floor = null
		for other in fm.floors:
			if other != floor_def:
				fallback = other
				break
		if fallback == null or not fm.switch_floor(fallback.floor_id):
			_reject_floor(peer_id, op_id, &"switch_failed")
			return
		_migrate_runtime_bodies_to_bound(fallback.floor_id)
	# Non-active floors may still hold an unused runtime world —
	# occupancy above guarantees it is empty, so teardown is safe.
	fm.release_runtime_world(floor_id)
	if not fm.unregister_floor(floor_id):
		_reject_floor(peer_id, op_id, &"apply_failed")
		return
	var error := FloorSaveSystem.delete_floor_save(floor_id)
	if error != OK:
		push_warning("MultiplayerManager: floor '%s' unregistered but save removal failed (error %d)." % [
			floor_id, error])
	_rpc_floor_result.rpc(op_id, true, &"", {
		"op": "floor_delete", "floor_id": floor_id,
		"requester": peer_id})
	print("MultiplayerManager: floor op %d delete '%s' applied." % [op_id, floor_id])

## After switch_floor makes floor_id active, a runtime_worlds entry
## for it (bodies visited earlier) is shadowed by the bound world —
## rebind each of its bodies to the bound world's Room instances, then
## release the orphaned world. Positions/floor are unchanged, so no
## client notification is needed; place_at only re-broadcasts state.
func _migrate_runtime_bodies_to_bound(floor_id: StringName) -> void:
	var fm := _world.floor_manager
	var runtime_world: RoomWorld = fm.runtime_worlds.get(floor_id)
	if runtime_world == null:
		return
	var bound := _world.room_world
	for peer_id in _bodies:
		var body: Player = _bodies[peer_id]
		if body == null or not is_instance_valid(body) or body.room == null:
			continue
		if _floor_id_for_peer(peer_id) != floor_id or body.room_world != runtime_world:
			continue
		var new_room := bound.get_room(body.room.room_coordinates)
		if new_room == null:
			push_warning("MultiplayerManager: cannot migrate peer %d body — room %s missing in bound world." % [
				peer_id, body.room.room_coordinates])
			continue
		if body.get_parent() != null:
			body.get_parent().remove_child(body)
		bound.entity_layer.add_child(body)
		body.grid = bound.grid
		body.room_world = bound
		body.room = new_room
		body.block_layer = new_room.block_layer
		body.room_size = new_room.size
		body.place_at(body.grid_position, body.stand_elevation_at(body.grid_position))
	fm.release_runtime_world(floor_id)

## Server -> all clients: authoritative floor-op outcome. Catalog
## ops are global — clients must NOT floor-filter these.
@rpc("authority", "call_remote", "reliable")
func _rpc_floor_result(op_id: int, accepted: bool, reason: StringName,
		payload: Dictionary) -> void:
	if multiplayer.is_server():
		return
	_handle_floor_result(op_id, accepted, reason, payload)

## Client-side floor result handling. Applies immediately — catalog
## state is global and idempotent, and the next snapshot's floor
## catalog reconcile converges any residual drift.
func _handle_floor_result(op_id: int, accepted: bool, reason: StringName,
		payload: Dictionary) -> void:
	if not accepted:
		floor_result.emit(op_id, false, reason, {})
		return
	var applied := false
	if _world != null and _world.floor_manager != null:
		var fm: FloorManager = _world.floor_manager
		match StringName(str(payload.get("op", ""))):
			&"floor_create":
				var floor_id := StringName(str(payload.get("floor_id", "")))
				var def_data: Variant = payload.get("floor_def")
				# Already registered (duplicate broadcast or the join
				# snapshot's catalog beat it here): consistent.
				if fm.has_floor(floor_id):
					applied = true
				elif def_data is Dictionary:
					var rebuilt := fm._floor_from_saved_data(def_data)
					applied = rebuilt != null \
						and rebuilt.floor_id == floor_id \
						and fm.register_floor_replica(rebuilt)
			&"floor_delete":
				var floor_id := StringName(str(payload.get("floor_id", "")))
				# Already gone: consistent. unregister_floor_replica
				# refuses the active floor — a divergence the snapshot
				# catalog will keep flagging until resolved.
				applied = not fm.has_floor(floor_id) \
					or fm.unregister_floor_replica(floor_id)
	if applied:
		floor_result.emit(op_id, true, &"", payload)
	else:
		push_warning(("MultiplayerManager: floor op %d failed to apply locally "
			+ "(catalog may diverge until next snapshot).") % op_id)
		floor_result.emit(op_id, true, &"diverged", payload)

# ------------------------------------------------------------------
# Debug build ops for headless live tests (--build-op / legacy flags)
# ------------------------------------------------------------------

## Parses --build-op specs into _debug_ops entries:
## "place:x,y:category:object_id[:rotation[:flip]]" or "remove:x,y".
func _parse_build_ops(specs: Variant) -> Array:
	var ops: Array = []
	for spec in specs if specs is Array else []:
		var parts := String(spec).split(":")
		if parts.size() < 2:
			push_warning("MultiplayerManager: ignoring malformed --build-op '%s'." % spec)
			continue
		var kind := parts[0]
		var cell := Vector2i.ZERO
		var coords := parts[1].split(",")
		if coords.size() == 2 and coords[0].is_valid_int() \
				and coords[1].is_valid_int():
			cell = Vector2i(int(coords[0]), int(coords[1]))
		else:
			push_warning("MultiplayerManager: ignoring --build-op '%s' (bad cell)." % spec)
			continue
		if kind == "place":
			var category := StringName(parts[2])
			if category not in BuildOps.CATEGORIES:
				push_warning("MultiplayerManager: ignoring --build-op '%s' (bad category)." % spec)
				continue
			ops.append({"kind": "place", "cell": cell, "category": category,
				"object_id": StringName(parts[3]) if parts.size() > 3 else &"standard_block",
				"rotation": int(parts[4]) if parts.size() > 4 and parts[4].is_valid_int() else 0,
				"flip": parts.size() > 5 and parts[5] == "1",
				"done": false})
		elif kind == "remove":
			ops.append({"kind": "remove", "cell": cell, "done": false})
		else:
			push_warning("MultiplayerManager: ignoring --build-op '%s' (bad kind)." % spec)
	return ops

## Runs the queued debug build ops once each, timed after world sync
## so requests travel the real client->server->broadcast path.
## Specs: {"kind": "place"|"remove", "cell": Vector2i, "category",
## "object_id", "done": bool} — remove auto-detects the topmost
## occupant via BuildOps.topmost_at, like a real click would.
func _run_debug_build_ops() -> void:
	if mode != Mode.CLIENT or not world_synced or _synced_msec < 0:
		return
	var now := Time.get_ticks_msec() - _synced_msec
	var player := _local_player()
	if player == null or player.room == null:
		return
	for i in range(_debug_ops.size()):
		var op: Dictionary = _debug_ops[i]
		# A pending transition rebuilds the world; ops fired mid-flight
		# would target rooms that no longer exist. Wait it out.
		if op.get("done", false) or _transition_pending \
				or now < 2000 + i * 1500:
			continue
		op["done"] = true
		if String(op.get("kind")) == "place":
			var ok := request_build_place(player.room.room_coordinates,
				op["cell"], op.get("category", &"block"),
				op.get("object_id", &"standard_block"),
				int(op.get("rotation", 0)), bool(op.get("flip", false)))
			print("MultiplayerManager: debug place %s -> %s" % [op, ok])
		else:
			var cell: Vector2i = op["cell"]
			var top := BuildOps.topmost_at(player.room, cell)
			if top.is_empty():
				print("MultiplayerManager: debug remove found nothing at %s." % cell)
				continue
			var category := StringName(str(top.get("category")))
			var ok := _debug_remove_request(player.room, cell, category, top)
			print("MultiplayerManager: debug remove %s -> %s" % [op, ok])

func _debug_remove_request(room: Room, cell: Vector2i, category: StringName,
		top: Dictionary) -> bool:
	match category:
		&"block", &"furniture":
			var block: Block = top["block"]
			return request_build_remove(room.room_coordinates, cell, category,
				StringName(block.block_id), block.grid_position, block.elevation,
				Vector2i.ZERO,
				block.furniture_rotation_degrees if block is Furniture else 0, false)
		&"carpet":
			return request_build_remove(room.room_coordinates, cell, category,
				(top["carpet"] as CarpetDefinition).object_id,
				Vector2i.ZERO, float(top["elevation"]), top["anchor"],
				int(top["rotation"]), bool(top["flip"]))
		&"tile":
			return request_build_remove(room.room_coordinates, cell, category,
				(top["tile"] as TileDefinition).object_id,
				Vector2i.ZERO, float(top["elevation"]))
	return false

## Parses --struct-op specs:
## "create:rx,ry:ox,oy:w,h" | "delete:rx,ry" | "vis:rx,ry:from,out".
func _parse_struct_ops(specs: Variant) -> Array:
	var ops: Array = []
	for spec in specs if specs is Array else []:
		var text := String(spec)
		var parts := text.split(":")
		var kind := String(parts[0]) if parts.size() > 0 else ""
		if parts.size() < 2:
			push_warning("MultiplayerManager: ignoring malformed --struct-op '%s'." % spec)
			continue
		var coords := parts[1].split(",")
		if coords.size() != 2 or not coords[0].is_valid_int() \
				or not coords[1].is_valid_int():
			push_warning("MultiplayerManager: ignoring malformed --struct-op '%s'." % spec)
			continue
		var room_id := Vector2i(int(coords[0]), int(coords[1]))
		match kind:
			"create":
				var rect := parts[2].split(",") if parts.size() > 2 else PackedStringArray()
				var wh := parts[3].split(",") if parts.size() > 3 else PackedStringArray()
				if rect.size() != 2 or wh.size() != 2 \
						or not rect[0].is_valid_int() or not rect[1].is_valid_int() \
						or not wh[0].is_valid_int() or not wh[1].is_valid_int():
					push_warning("MultiplayerManager: ignoring --struct-op '%s' (bad rect)." % spec)
					continue
				var room_spec := FloorRoomSpec.new()
				room_spec.room_id = room_id
				room_spec.global_origin = Vector2i(int(rect[0]), int(rect[1]))
				room_spec.size = Vector2i(int(wh[0]), int(wh[1]))
				ops.append({"kind": "create", "spec": room_spec, "done": false})
			"delete":
				ops.append({"kind": "delete", "room_id": room_id, "done": false})
			"vis":
				var flags := parts[2].split(",") if parts.size() > 2 else PackedStringArray()
				if flags.size() != 2:
					push_warning("MultiplayerManager: ignoring --struct-op '%s' (bad flags)." % spec)
					continue
				ops.append({"kind": "vis", "room_id": room_id,
					"from": flags[0] == "1", "out": flags[1] == "1", "done": false})
			"spawn":
				# spawn:x,y:0|1 — x,y is a world CELL, not a room id.
				var place_flag := parts[2] if parts.size() > 2 else "1"
				ops.append({"kind": "spawn", "cell": room_id,
					"place": place_flag != "0", "done": false})
			_:
				push_warning("MultiplayerManager: ignoring --struct-op '%s' (bad kind)." % spec)
	return ops

## Fires queued --struct-op requests once each after world sync,
## staggered like the build ops and paused during transitions.
func _run_debug_struct_ops() -> void:
	if mode != Mode.CLIENT or not world_synced or _synced_msec < 0:
		return
	var now := Time.get_ticks_msec() - _synced_msec
	for i in range(_debug_struct_ops.size()):
		var op: Dictionary = _debug_struct_ops[i]
		if op.get("done", false) or _transition_pending \
				or now < 2000 + i * 1500:
			continue
		op["done"] = true
		var ok := false
		match String(op.get("kind")):
			"create":
				ok = request_struct_create(
					FloorSaveSystem.spec_to_layout_entry(op["spec"]))
			"delete":
				ok = request_struct_delete(op["room_id"])
			"vis":
				ok = request_struct_visibility(op["room_id"],
					bool(op.get("from", true)), bool(op.get("out", true)))
			"spawn":
				ok = request_struct_spawn(op["cell"], bool(op.get("place", true)))
		print("MultiplayerManager: debug struct op %s -> %s" % [op.get("kind"), ok])

## Parses --floor-op specs:
## "create:floor_id[:display name]" | "delete:floor_id".
func _parse_floor_ops(specs: Variant) -> Array:
	var ops: Array = []
	for spec in specs if specs is Array else []:
		var parts := String(spec).split(":")
		var kind := String(parts[0]) if parts.size() > 0 else ""
		if parts.size() < 2 or parts[1].is_empty():
			push_warning("MultiplayerManager: ignoring malformed --floor-op '%s'." % spec)
			continue
		match kind:
			"create":
				ops.append({"kind": "create", "floor_id": StringName(parts[1]),
					"display_name": ":".join(parts.slice(2)), "done": false})
			"delete":
				ops.append({"kind": "delete", "floor_id": StringName(parts[1]),
					"done": false})
			_:
				push_warning("MultiplayerManager: ignoring --floor-op '%s' (bad kind)." % spec)
	return ops

## Fires queued --floor-op requests once each after world sync,
## staggered like the other debug ops and paused during transitions.
func _run_debug_floor_ops() -> void:
	if mode != Mode.CLIENT or not world_synced or _synced_msec < 0:
		return
	var now := Time.get_ticks_msec() - _synced_msec
	for i in range(_debug_floor_ops.size()):
		var op: Dictionary = _debug_floor_ops[i]
		if op.get("done", false) or _transition_pending \
				or now < 2000 + i * 1500:
			continue
		op["done"] = true
		var ok := false
		match String(op.get("kind")):
			"create":
				ok = request_floor_create(op["floor_id"],
					String(op.get("display_name", "")))
			"delete":
				ok = request_floor_delete(op["floor_id"])
		print("MultiplayerManager: debug floor op %s -> %s" % [op.get("kind"), ok])

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
		# entries: [peer_id, floor_id, room_id, cell, elev, face]
		if entry is Array and entry.size() >= 6:
			_spawn_avatar(int(entry[0]), StringName(str(entry[1])), entry[2],
				entry[3], entry[4], entry[5])

## Server -> all clients: a player entered the world (or a floor the
## recipient just transitioned to — sent rpc_id in that case).
@rpc("authority", "call_remote", "reliable")
func _rpc_spawn_player(peer_id: int, floor_id: StringName, room_id: Vector2i,
		cell: Vector2i, cell_elevation: float, face: Vector2i) -> void:
	if multiplayer.is_server() or peer_id == my_peer_id:
		return
	_spawn_avatar(peer_id, floor_id, room_id, cell, cell_elevation, face)

## Server -> all clients: authoritative grid state for a peer.
@rpc("authority", "call_remote", "reliable")
func _rpc_player_state(peer_id: int, floor_id: StringName, room_id: Vector2i,
		cell: Vector2i, cell_elevation: float, face: Vector2i) -> void:
	if multiplayer.is_server():
		return
	# Stale echoes from a floor this client already left must not move
	# the local avatar or mutate same-named rooms on the new floor.
	if _my_floor_id != &"" and floor_id != _my_floor_id:
		return
	if peer_id == my_peer_id:
		_reconcile_local(room_id, cell, cell_elevation)
		return
	var avatar: Player = _avatars.get(peer_id)
	if avatar == null:
		_spawn_avatar(peer_id, floor_id, room_id, cell, cell_elevation, face)
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
