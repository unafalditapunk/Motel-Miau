class_name WorldBootstrap
extends Node2D

## Game world root. Owns the catalogs, scenes, and RoomDefinition, configures
## the RoomWorld child, builds the primary room, spawns the player, wires the
## placement UI, and is the single owner of the F5/F6 save/load shortcuts
## plus autosave on exit.

const DEBUG_HUD_SCRIPT := preload("res://Scripts/Debug/DebugHud.gd")
const FLOOR_PANEL_SCRIPT := preload("res://Scripts/UI/FloorPanel.gd")
const AVATAR_PANEL_SCRIPT := preload("res://Scripts/UI/AvatarPanel.gd")
const TRANSITION_OVERLAY_SCRIPT := preload("res://Scripts/UI/TransitionOverlay.gd")
const SAVE_KEY := KEY_F5
const LOAD_KEY := KEY_F6
const QUARANTINE_KEY := KEY_F10
const QUARANTINE_CONFIRM_WINDOW_MSEC := 5000

@export var room_definition: RoomDefinition
## When set (Main.gd sets &"motel"), the world boots directly into that
## Floor via FloorManager.load_floor instead of the legacy single-room
## registration. Empty keeps the legacy bootstrap-room behavior used by
## tests and ad-hoc worlds.
@export var startup_floor_id: StringName = &""
@export var furniture_catalog: FurnitureCatalog
@export var block_catalog: BlockCatalog
@export var tile_catalog: TileCatalog
@export var carpet_catalog: CarpetCatalog
@export var player_scene: PackedScene
@export var block_scene: PackedScene
@export var debug_coordinates := false

@onready var room_world: RoomWorld = $RoomWorld
@onready var placement_controller: BlockPlacementController = $BlockPlacementController
@onready var world_camera: WorldCamera = $WorldCamera

## Floor definitions + the active floor's runtime RoomWorld binding.
## Created in _ready; floors themselves are data until activated.
var floor_manager: FloorManager

## The primary room (the one defined by room_definition).
var room: Room
var player: Player
var block_layer: BlockLayer
var tile_layer: TileLayer
var carpet_layer: CarpetLayer
var _debug_hud: DebugHud
var _floor_panel: FloorPanel
var _avatar_panel: AvatarPanel
var _floor_editor: FloorEditor
var _net_manager: MultiplayerManager
var combat_manager: CombatManager
## Launch args parsed once in _ready; empty dict = single-player.
var _net_args := {}
var _quarantine_armed_msec := -1

func _ready() -> void:
	add_to_group(&"world")
	if room_definition == null:
		push_error("WorldBootstrap requires a RoomDefinition.")
		return
	if room_world == null or room_world.grid == null:
		push_error("WorldBootstrap requires a RoomWorld child with an IsometricGrid.")
		return
	if furniture_catalog == null or block_catalog == null or player_scene == null or block_scene == null:
		push_error("WorldBootstrap is missing required catalogs or scenes.")
		return

	# --saves=<dir> redirects floor saves (dev/test isolation); parsed
	# here because it applies to single-player too, not just net modes.
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--saves="):
			FloorSaveSystem.save_root = arg.get_slice("=", 1)

	floor_manager = FloorManager.new()
	floor_manager.name = "FloorManager"
	floor_manager.room_world = room_world
	floor_manager.floor_switched.connect(_on_floor_switched)
	add_child(floor_manager)

	_configure_room_world()
	_net_args = MultiplayerManager.parse_args(OS.get_cmdline_user_args())
	var net_client := int(_net_args.get("mode", -1)) == MultiplayerManager.Mode.CLIENT
	# Floor-first boot: when a startup floor is configured the world is
	# materialized entirely from Floor specs — no legacy room
	# registration runs. Falls back to the legacy room if the floor is
	# missing or fails to load. Multiplayer CLIENTS boot without local
	# saves/layout: the authoritative world arrives via WorldSnapshot.
	var floor_ready := false
	if startup_floor_id != &"" and floor_manager.has_floor(startup_floor_id):
		if net_client:
			floor_ready = floor_manager.load_floor_without_save(startup_floor_id)
		else:
			floor_ready = floor_manager.load_floor(startup_floor_id)
		if not floor_ready:
			push_warning("WorldBootstrap: startup floor '%s' failed to load; falling back to the legacy room." % startup_floor_id)
	if floor_ready:
		room = _floor_entry_room()
	else:
		room = room_world.create_room_from_definition(Vector2i.ZERO, Vector2i.ZERO, room_definition)
	if room == null:
		push_error("WorldBootstrap failed to create the primary room.")
		return
	_configure_room_layers()
	_spawn_player()
	_apply_saved_avatar()
	# load_floor ran before the player existed, so spawn placement was
	# skipped; place the player at a random spawn point now that the
	# node exists. Saved player_state no longer resumes a position —
	# spawn points are the only floor entries. Net clients skip this:
	# their position comes from the server spawn handshake, and local
	# player_state.json is stale replica data.
	if floor_ready:
		if not net_client and floor_manager != null:
			floor_manager.place_player_at_spawn()
		if player != null and player.room != null and player.room != room:
			room = player.room
			_configure_room_layers()
	_build_debug_hud()
	_build_floor_panel()
	_build_avatar_panel()
	_build_floor_editor()
	_build_transition_overlay()
	_wire_placement_controller()
	_build_combat_manager()
	_setup_multiplayer()

func _exit_tree() -> void:
	# A dedicated server IS the persistence owner (Phase D): on a
	# normal quit it saves every dirty floor through the net manager
	# instead of the single-floor SP path. An abrupt kill bypasses
	# this — autosave bounds the lost progress.
	if _net_manager != null and _net_manager.dedicated_server:
		_net_manager.shutdown_save()
		return
	save_game()

func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		if _net_manager != null and _net_manager.dedicated_server:
			_net_manager.shutdown_save()
			return
		save_game()

func _configure_room_world() -> void:
	_configure_room_world_instance(room_world)

## Applies this world's catalogs/scenes/grid settings to any RoomWorld
## instance — the primary room_world and runtime floor worlds alike.
func _configure_room_world_instance(world: RoomWorld) -> void:
	world.grid = room_world.grid
	world.room_dimensions = room_definition.size
	world.floor_texture = room_definition.floor_texture
	world.default_tile_id = room_definition.default_tile_id
	world.debug_coordinates = debug_coordinates
	world.tile_catalog = tile_catalog
	world.block_catalog = block_catalog
	world.furniture_catalog = furniture_catalog
	world.carpet_catalog = carpet_catalog
	world.block_scene = block_scene
	world.player_scene = player_scene

## Creates an empty, fully configured RoomWorld for a floor instance
## (multiplayer: each occupied floor gets its own world so players can
## stand on different floors simultaneously). The caller populates it
## via FloorManager.materialize_runtime_floor. Added as a child of
## this bootstrap; returns null when catalogs are missing.
func create_floor_world(floor_id: StringName) -> RoomWorld:
	if room_definition == null or tile_catalog == null:
		push_error("WorldBootstrap.create_floor_world requires room_definition and catalogs.")
		return null
	var world := RoomWorld.new()
	world.name = "FloorWorld_%s" % floor_id
	_configure_room_world_instance(world)
	add_child(world)
	return world

## The floor's entry room (falling back to the first materialized room).
func _floor_entry_room() -> Room:
	var floor_def := floor_manager.active_floor
	if floor_def == null:
		return null
	var entry := room_world.get_room(floor_def.entry_room_id)
	if entry != null:
		return entry
	var rooms := room_world.get_rooms()
	return rooms[0] if not rooms.is_empty() else null

func _configure_room_layers() -> void:
	block_layer = room.block_layer
	tile_layer = room.get_node_or_null(^"TileLayer") as TileLayer
	carpet_layer = room.get_node_or_null(^"CarpetLayer") as CarpetLayer

func _spawn_player() -> void:
	var spawned := player_scene.instantiate() as Player
	if spawned == null:
		push_error("Player scene must instantiate to a Player.")
		return
	player = spawned
	player.grid = room_world.grid
	player.room_world = room_world
	player.block_layer = block_layer
	player.room = room
	player.room_size = room.size
	# Floor worlds spawn at the floor's spawn_position (local to the
	# entry room); the legacy world uses the RoomDefinition's.
	var spawn := room_definition.spawn_position
	if floor_manager.active_floor != null:
		spawn = floor_manager.active_floor.spawn_position
	if spawn.x < 0 or spawn.y < 0 or spawn.x >= room.size.x or spawn.y >= room.size.y:
		spawn = Vector2i(room.size.x >> 1, room.size.y >> 1)
	player.grid_position = spawn
	player.elevation = 0.0
	room_world.entity_layer.add_child(player)

func _build_debug_hud() -> void:
	_debug_hud = DEBUG_HUD_SCRIPT.new()
	_debug_hud.name = "DebugHud"
	_debug_hud.player = player
	_debug_hud.grid = room_world.grid
	add_child(_debug_hud)

func _build_floor_panel() -> void:
	_floor_panel = FLOOR_PANEL_SCRIPT.new()
	_floor_panel.name = "FloorPanel"
	add_child(_floor_panel)

func _build_avatar_panel() -> void:
	_avatar_panel = AVATAR_PANEL_SCRIPT.new()
	_avatar_panel.name = "AvatarPanel"
	add_child(_avatar_panel)

## Equips the persisted avatar selection
## (user://avatar_selection.json) on the local player. Missing or
## no-longer-valid ids keep the scene default — the catalog only
## lists folders that still exist on disk.
func _apply_saved_avatar() -> void:
	if player == null:
		return
	var saved := AvatarCatalog.load_selection()
	if saved.is_empty():
		return
	var entry: Variant = AvatarCatalog.find(saved)
	if not (entry is Dictionary) or not bool(entry.get("ready", false)):
		return
	player.set_character(String(entry["root"]))

## Screen-space transition fade: pure presentation, driven by
## play_transition (single-player) and the net manager's local
## transition_requested/transition_result signals (multiplayer
## client). Exists on every peer but only ever animates locally.
func _build_transition_overlay() -> void:
	var overlay := TRANSITION_OVERLAY_SCRIPT.new()
	overlay.name = "TransitionOverlay"
	add_child(overlay)

## Creation Mode editor: child of RoomWorld so its _draw() overlay shares
## the rooms' world-cell coordinate space.
func _build_floor_editor() -> void:
	_floor_editor = FloorEditor.new()
	_floor_editor.name = "FloorEditor"
	room_world.add_child(_floor_editor)

## Combat prototype: the manager exists on every peer but only
## single-player boots (no --server/--client args) get the prototype
## enemy in the entry room. Multiplayer peers stay inert — no spawn,
## and CombatManager refuses encounters while a net mode is active.
func _build_combat_manager() -> void:
	combat_manager = CombatManager.new()
	combat_manager.name = "CombatManager"
	add_child(combat_manager)
	combat_manager.bind_player(player)
	if _net_args.is_empty():
		combat_manager.spawn_prototype_enemy()

## Multiplayer prototype: only instantiated when launch args ask for
## it (--server / --client). No args = pure single-player, zero cost.
func _setup_multiplayer() -> void:
	if _net_args.is_empty():
		return
	_net_manager = MultiplayerManager.new()
	_net_manager.name = "MultiplayerManager"
	add_child(_net_manager)
	_net_manager.setup(self, _net_args)

func _wire_placement_controller() -> void:
	var selector := get_node_or_null(^"BuildingSelector") as BuildingSelector
	if placement_controller != null:
		placement_controller.block_layer = block_layer
		placement_controller.room = room
		placement_controller.building_selector = selector
	var catalog_panel := get_node_or_null(^"CatalogPanel") as CatalogPanel
	var toolbar := get_node_or_null(^"BuildingToolbar") as BuildingToolbar
	if catalog_panel != null:
		catalog_panel.set_building_selector(selector)
	if toolbar != null:
		toolbar.setup(placement_controller, selector, self, catalog_panel)

func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventKey):
		return
	var key_event := event as InputEventKey
	if not key_event.pressed or key_event.echo:
		return
	if key_event.keycode == SAVE_KEY:
		_on_save_requested()
		get_viewport().set_input_as_handled()
	elif key_event.keycode == LOAD_KEY:
		_on_load_requested()
		get_viewport().set_input_as_handled()
	elif key_event.keycode == QUARANTINE_KEY:
		_on_quarantine_requested()
		get_viewport().set_input_as_handled()

## F10 (debug mode only): quarantines incompatible/orphan room saves into
## user://saves/_quarantine/. Two-press confirmation: the first press arms
## for a few seconds, the second executes. Saves are moved, never deleted.
func _on_quarantine_requested() -> void:
	if _debug_hud == null or not _debug_hud.enabled:
		return
	if room_world == null:
		return
	var now := Time.get_ticks_msec()
	if _quarantine_armed_msec < 0 or now - _quarantine_armed_msec > QUARANTINE_CONFIRM_WINDOW_MSEC:
		_quarantine_armed_msec = now
		print("F10: press again within %d ms to quarantine incompatible room saves." % QUARANTINE_CONFIRM_WINDOW_MSEC)
		return
	_quarantine_armed_msec = -1
	var audit := room_world.audit_room_saves()
	var incompatible := 0
	for entry in audit:
		if entry["status"] == "incompatible" or entry["status"] == "orphan":
			incompatible += 1
	var moved := room_world.quarantine_incompatible_saves()
	var quarantine_dir := room_world.effective_save_directory().path_join("_quarantine")
	print("F10 quarantine: %d incompatible/orphan save(s) found, %d moved to '%s'. No files were deleted." % [
		incompatible, moved, quarantine_dir])

func _on_save_requested() -> void:
	save_game()

func _on_load_requested() -> void:
	load_game()

## Saves every registered room, the connection graph, and the player state.
## When a floor is active the save is floor-scoped (user://floors/<id>/);
## otherwise the legacy world saves to the shared RoomSaveSystem dir.
## True on a multiplayer client: the world is a server replica, so all
## local world persistence is disabled — clients must never write
## shared world state to their own user:// saves.
func _net_client_readonly() -> bool:
	return _net_manager != null \
		and _net_manager.mode == MultiplayerManager.Mode.CLIENT

func save_game() -> void:
	if _net_client_readonly():
		return
	# Dedicated server: F5-style saves cover EVERY dirty floor, not
	# just the bound world's active floor.
	if _net_manager != null and _net_manager.dedicated_server:
		if floor_manager != null:
			floor_manager.save_all_dirty()
		return
	if floor_manager != null and floor_manager.active_floor != null:
		floor_manager.save_active_floor()
	elif room_world != null:
		room_world.save_all_rooms()

func load_game() -> void:
	# F6 on a client would hydrate stale local saves over the replica.
	if _net_client_readonly():
		return
	if floor_manager != null and floor_manager.active_floor != null:
		floor_manager.load_floor(floor_manager.active_floor.floor_id)
	elif room_world != null:
		room_world.load_all_rooms()

## Public entry point for floor switching (future floor UI). Returns
## false without side effects when the switch could not complete.
func switch_floor(floor_id: StringName) -> bool:
	# Floor switching is not synchronized yet (Phase C); a client must
	# not rebuild its replica from local saves.
	if _net_client_readonly():
		return false
	if floor_manager == null:
		return false
	# At <1x overview zoom, bring the camera onto the avatar and zoom
	# to 1x BEFORE the overlay covers the screen — the floor teleport
	# then plays at normal zoom instead of cutting from room center.
	var camera := _world_camera()
	if camera != null and camera.defer_until_recentered(
			func() -> void: switch_floor(floor_id)):
		return true
	# Route through the transition overlay when present: the switch
	# is deferred until the slide-out clears the screen; true means
	# the transition started (the result arrives via
	# transition_completed). The slide plays at the entry zoom —
	# floor teleports never change the player's zoom.
	var overlay := get_tree().get_first_node_in_group(&"transition_overlay") as TransitionOverlay
	if overlay != null:
		return bool(overlay.play_transition(
			func() -> bool: return floor_manager.switch_floor(floor_id)))
	return floor_manager.switch_floor(floor_id)

## The active WorldCamera, when one is driving this viewport.
func _world_camera() -> WorldCamera:
	if not is_inside_tree():
		return null
	return get_viewport().get_camera_2d() as WorldCamera

## Rebinds every room-scoped reference after the active floor changed.
## The player node itself survives the switch (FloorManager re-places
## it); the camera follows the player group automatically.
func _on_floor_switched(_floor_def: Floor) -> void:
	# Room refs are about to be rebound; Creation Mode cannot survive a
	# floor switch.
	if _floor_editor != null and _floor_editor.active:
		_floor_editor.exit()
	if player == null:
		return
	room = player.room
	if room == null:
		return
	_configure_room_layers()
	if placement_controller != null:
		placement_controller.block_layer = block_layer
		placement_controller.room = room
