extends SceneTree

## Smoke test for Phase C1 structural-mutation protection (updated for
## C3): while the local peer is a multiplayer CLIENT, every
## FloorManager structural mutator (floor create/delete/switch/load/
## activate, room create/delete, registry add/remove) must refuse, the
## F7 FloorPanel must render read-only, and FloorEditor must route
## create/delete/visibility through server requests instead of local
## mutation — while WorldSnapshot.apply and normal server/single-
## player behavior keep working. A bare MultiplayerManager node with
## mode=CLIENT stands in for the real net role; no ENet peer is needed.

const GRID_PATH := "res://Resources/IsometricGrid/TestGrid.tres"
const TILE_CATALOG_PATH := "res://Resources/TileCatalog.tres"
const BLOCK_CATALOG_PATH := "res://Resources/BlockCatalog.tres"
const FURNITURE_CATALOG_PATH := "res://Resources/FurnitureCatalog.tres"
const CARPET_CATALOG_PATH := "res://Resources/CarpetCatalog.tres"
const BLOCK_SCENE_PATH := "res://Scenes/Objects/Block.tscn"
const PLAYER_SCENE_PATH := "res://Scenes/Player/Player.tscn"
const SCRATCH_ROOT := "user://smoke_struct_guard"

var _floor_manager: FloorManager
var _room_world: RoomWorld
var _player: Player
var _net: MultiplayerManager
var _panel: FloorPanel
var _editor: FloorEditor
var _frames := 0
var _failures: Array[String] = []

func _initialize() -> void:
	FloorSaveSystem.save_root = SCRATCH_ROOT
	_remove_dir_contents(SCRATCH_ROOT)
	_floor_manager = FloorManager.new()
	_floor_manager.name = "FloorManager"
	root.add_child(_floor_manager)
	_room_world = _make_room_world()
	_floor_manager.room_world = _room_world
	# _ready is deferred until the first frame in SceneTree scripts, so
	# the player spawn and checks happen in _process.

func _make_room_world() -> RoomWorld:
	var world := RoomWorld.new()
	world.name = "ScratchRoomWorld"
	world.grid = load(GRID_PATH) as IsometricGrid
	world.room_dimensions = Vector2i(16, 16)
	world.default_tile_id = &"floor_iso"
	world.tile_catalog = load(TILE_CATALOG_PATH) as TileCatalog
	world.block_catalog = load(BLOCK_CATALOG_PATH) as BlockCatalog
	world.furniture_catalog = load(FURNITURE_CATALOG_PATH) as FurnitureCatalog
	world.carpet_catalog = load(CARPET_CATALOG_PATH) as CarpetCatalog
	world.block_scene = load(BLOCK_SCENE_PATH) as PackedScene
	world.player_scene = load(PLAYER_SCENE_PATH) as PackedScene
	world.hide_rooms_outside_neighborhood = false
	world.deemphasize_neighbors = false
	world.emphasis_transition_duration = 0.0
	world.room_slide_duration = 0.0
	root.add_child(world)
	return world

func _spawn_player() -> void:
	var scene := load(PLAYER_SCENE_PATH) as PackedScene
	_player = scene.instantiate() as Player
	_player.grid = _room_world.grid
	_player.move_duration = 0.0
	_room_world.entity_layer.add_child(_player)

func _spec(room_id: Vector2i, origin: Vector2i, size: Vector2i) -> FloorRoomSpec:
	var spec := FloorRoomSpec.new()
	spec.room_id = room_id
	spec.global_origin = origin
	spec.size = size
	return spec

func _make_net_client() -> void:
	_net = MultiplayerManager.new()
	_net.name = "MultiplayerManager"
	_net.mode = MultiplayerManager.Mode.CLIENT
	_net.add_to_group(&"multiplayer_manager")
	root.add_child(_net)

func _remove_dir_contents(path: String) -> void:
	var dir := DirAccess.open(path)
	if dir == null:
		return
	for file_name in dir.get_files():
		dir.remove(file_name)
	for sub in dir.get_directories():
		_remove_dir_contents(path.path_join(sub))
		DirAccess.remove_absolute(path.path_join(sub))

func _expect(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)

func _process(_delta: float) -> bool:
	_frames += 1
	if _frames == 1:
		_setup()
	if _frames < 6:
		return false
	_report()
	quit()
	return true

func _setup() -> void:
	_spawn_player()
	_test_single_player_baseline()
	_make_net_client()
	_test_client_floor_manager_guards()
	_test_snapshot_apply_under_client()
	_test_floor_panel_readonly()
	_test_floor_editor_readonly()
	_test_server_mode_restored()

func _test_single_player_baseline() -> void:
	# No MultiplayerManager node exists yet: pure single-player.
	_expect(not MultiplayerManager.is_client(self), "is_client true without net mode")
	_expect(not _floor_manager.structural_edits_readonly(), "readonly without net mode")
	var specs: Array[FloorRoomSpec] = [
		_spec(Vector2i(0, 0), Vector2i(0, 0), Vector2i(8, 8)),
		_spec(Vector2i(1, 0), Vector2i(8, 0), Vector2i(8, 8)),
	]
	_expect(_floor_manager.create_floor(&"guard_a", "Guard A", specs) != null,
		"SP create_floor guard_a failed")
	_expect(_floor_manager.create_floor(&"guard_b", "", [_spec(Vector2i(5, 5), Vector2i(40, 40), Vector2i(6, 6))]) != null,
		"SP create_floor guard_b failed")
	_expect(_floor_manager.switch_floor(&"guard_a"), "SP switch to guard_a failed")
	_expect(_floor_manager.active_floor != null and _floor_manager.active_floor.floor_id == &"guard_a",
		"guard_a not active")

func _test_client_floor_manager_guards() -> void:
	_expect(MultiplayerManager.is_client(self), "is_client false with CLIENT manager")
	_expect(_floor_manager.structural_edits_readonly(), "readonly false on client")
	var active_before: Floor = _floor_manager.active_floor
	var room_count_before := _room_world.registry.get_rooms().size()

	# Floor-level mutations.
	_expect(_floor_manager.create_floor(&"guard_c", "Guard C") == null,
		"client create_floor succeeded")
	_expect(_floor_manager.delete_floor(&"guard_b") == false and _floor_manager.has_floor(&"guard_b"),
		"client delete_floor succeeded")
	_expect(_floor_manager.switch_floor(&"guard_b") == false
		and _floor_manager.active_floor == active_before,
		"client switch_floor succeeded")
	_expect(_floor_manager.load_floor(&"guard_b") == false, "client load_floor succeeded")
	_expect(_floor_manager.activate_floor(&"guard_b") == false, "client activate_floor succeeded")

	# Registry-level mutations.
	var stray := Floor.new()
	stray.floor_id = &"guard_stray"
	stray.display_name = "stray"
	stray.entry_room_id = Vector2i.ZERO
	var stray_spec := _spec(Vector2i.ZERO, Vector2i.ZERO, Vector2i(4, 4))
	stray.rooms.assign([stray_spec])
	_expect(_floor_manager.register_floor(stray) == false and not _floor_manager.has_floor(&"guard_stray"),
		"client register_floor succeeded")
	_expect(_floor_manager.unregister_floor(&"guard_b") == false and _floor_manager.has_floor(&"guard_b"),
		"client unregister_floor succeeded")

	# Room-level mutations on the active floor.
	var new_room := _spec(Vector2i(2, 0), Vector2i(16, 0), Vector2i(4, 4))
	_expect(_floor_manager.add_room_to_active_floor(new_room) == null,
		"client add_room_to_active_floor succeeded")
	_expect(_floor_manager.remove_room_from_active_floor(Vector2i(1, 0)) == false
		and _room_world.has_room(Vector2i(1, 0)),
		"client remove_room_from_active_floor succeeded")

	# World untouched.
	_expect(_floor_manager.active_floor == active_before, "active floor changed under client guards")
	_expect(_room_world.registry.get_rooms().size() == room_count_before,
		"room count changed under client guards")
	_expect(_floor_manager.floors.size() == 5, "floor count changed: %d" % _floor_manager.floors.size())

func _test_snapshot_apply_under_client() -> void:
	# Internal replica paths must keep working while mutators refuse:
	# place content, snapshot, rebuild through WorldSnapshot.apply.
	var room_a := _room_world.get_room(Vector2i(0, 0))
	_expect(room_a != null, "room (0,0) missing for snapshot test")
	if room_a == null or room_a.block_layer == null:
		return
	var def: BlockDefinition = _room_world.block_catalog.get_definition(&"standard_block")
	room_a.block_layer.place_block(def, Vector2i(2, 2), 0.0)
	var snapshot := WorldSnapshot.build(_floor_manager, _room_world)
	_expect(not snapshot.is_empty(), "WorldSnapshot.build empty on client")
	var json := JSON.stringify(snapshot)
	var parsed: Variant = JSON.parse_string(json)
	_expect(parsed is Dictionary, "snapshot JSON round-trip failed")
	if not (parsed is Dictionary):
		return
	var ok := WorldSnapshot.apply(_floor_manager, _room_world, _player, parsed)
	_expect(ok, "WorldSnapshot.apply refused under client readonly")
	var rebuilt := _room_world.get_room(Vector2i(0, 0))
	_expect(rebuilt != null and rebuilt.block_layer != null and rebuilt.block_layer.blocks.size() == 1,
		"snapshot contents not reconstructed under client readonly")
	_expect(_floor_manager.active_floor != null and _floor_manager.active_floor.floor_id == &"guard_a",
		"snapshot changed active floor")

func _test_floor_panel_readonly() -> void:
	_panel = FloorPanel.new()
	_panel.name = "FloorPanel"
	_panel.floor_manager = _floor_manager
	root.add_child(_panel)
	_panel.panel_open = true
	# Phase C4: create/delete controls stay ENABLED on clients — they
	# send server-authoritative floor-op requests the server validates.
	_expect(not _panel._new_floor_button.disabled, "New Floor button disabled on client")
	# Phase C2: Enter stays enabled on clients — it sends a
	# server-authoritative travel request, never a local switch.
	_expect(_panel._enter_buttons.get(&"guard_b", null) is Button
		and not (_panel._enter_buttons[&"guard_b"] as Button).disabled,
		"Enter (travel) button disabled on client")
	var row: Control = _panel._floor_rows.get(&"guard_b")
	var del := row.find_child("DeleteButton", true, false) as Button if row != null else null
	_expect(del != null and not del.disabled, "Delete button disabled on client")
	_expect(_panel._hint_label.text.contains("travel"), "panel hint lacks travel note")
	# Direct handler invocation must also refuse a LOCAL switch (the
	# bare test manager is not connected, so the travel request itself
	# fails too — either way the floor must not change).
	_panel._on_enter_pressed(&"guard_b")
	_expect(_floor_manager.active_floor != null and _floor_manager.active_floor.floor_id == &"guard_a",
		"panel enter handler switched floor on client")
	# Phase C4: the create handler sends a floor-op request; with no
	# connection it must fail cleanly and never touch the registry.
	_panel._id_edit.text = "panel_x"
	_panel._on_create_floor_pressed()
	_expect(not _floor_manager.has_floor(&"panel_x"), "panel create handler created floor on client")
	_expect(_panel._status_label.text.contains("Could not request"),
		"panel create lacked offline-request status")

func _test_floor_editor_readonly() -> void:
	_editor = FloorEditor.new()
	_editor.name = "FloorEditor"
	root.add_child(_editor)
	# Phase C3: clients may enter Creation Mode and draw selections —
	# confirming sends a server request instead of mutating locally.
	# This scratch manager is not connected, so requests must fail
	# cleanly without touching the replica.
	_editor._toggle_create_tool()
	_expect(_editor.tool == FloorEditor.Tool.CREATE_ROOM,
		"create tool refused on client")
	_expect(_editor._notice != "", "create tool gave no notice")
	# Room inspector: controls enabled, but requests can't reach a
	# server — handlers must leave the replica untouched.
	var room := _room_world.get_room(Vector2i(1, 0))
	_expect(room != null, "room (1,0) missing for editor test")
	if room == null:
		return
	_editor._open_room_panel(room)
	_expect(not _editor._room_panel_show_from_outside.disabled
		and not _editor._room_panel_show_outside.disabled,
		"visibility checkboxes disabled on client")
	_expect(_editor._room_panel_status.text.contains("server"),
		"room panel lacks server-authority status")
	_editor._room_panel_show_from_outside.set_pressed_no_signal(false)
	_editor._on_room_option_toggled()
	_expect(room.show_from_outside, "visibility flag mutated on client")
	# Delete still two-step; the confirm press sends a request that
	# fails (no connection) — the room must survive either way.
	_editor._on_room_delete()
	_expect(_editor._room_delete_armed, "room delete did not arm on client")
	_editor._on_room_delete()
	_expect(_room_world.has_room(Vector2i(1, 0)), "room deleted on client")
	_expect(_editor._struct_pending == 0, "phantom pending struct op")
	# Confirmation panel create path requests, fails offline, keeps sections.
	_editor._pending_sections = [Rect2i(Vector2i(20, 0), Vector2i(4, 4))]
	_editor._panel_id_edit.text = "9,9"
	_editor._on_panel_create()
	_expect(_editor._panel_status.text.contains("Not connected"),
		"panel create lacked offline-request status")
	_expect(_editor._pending_sections.size() == 1,
		"pending sections cleared on failed request")
	_expect(not _room_world.has_room(Vector2i(9, 9)), "room created on client")
	_editor._pending_sections.clear()

func _test_server_mode_restored() -> void:
	# Same node, server role: every guard must lift.
	_net.mode = MultiplayerManager.Mode.SERVER
	_expect(not MultiplayerManager.is_client(self), "is_client true on server")
	_expect(not _floor_manager.structural_edits_readonly(), "readonly true on server")

	# FloorManager mutators work again.
	_expect(_floor_manager.create_floor(&"guard_d", "Guard D") != null,
		"server create_floor failed")
	_expect(_floor_manager.switch_floor(&"guard_b"), "server switch_floor failed")
	_expect(_floor_manager.active_floor != null and _floor_manager.active_floor.floor_id == &"guard_b",
		"guard_b not active on server")
	_expect(_floor_manager.switch_floor(&"guard_a"), "server switch back failed")

	# FloorPanel rebuilds writable.
	_panel._rebuild_list()
	_expect(not _panel._new_floor_button.disabled, "New Floor still disabled on server")
	_expect(_panel._enter_buttons.get(&"guard_b", null) is Button
		and not (_panel._enter_buttons[&"guard_b"] as Button).disabled,
		"Enter still disabled on server")
	var row: Control = _panel._floor_rows.get(&"guard_b")
	var del := row.find_child("DeleteButton", true, false) as Button if row != null else null
	_expect(del != null and not del.disabled, "Delete still disabled on server")
	_expect(not _panel._hint_label.text.contains("read-only"), "panel hint still read-only on server")

	# FloorEditor mutations work again. The client section left the
	# create tool active — reset it so the toggle assertions are clean.
	_editor.tool = FloorEditor.Tool.NONE
	_editor._toggle_create_tool()
	_expect(_editor.tool == FloorEditor.Tool.CREATE_ROOM, "create tool refused on server")
	_editor._toggle_create_tool()
	_expect(_editor.tool == FloorEditor.Tool.NONE, "create tool did not toggle off")
	var room := _room_world.get_room(Vector2i(1, 0))
	_editor._open_room_panel(room)
	_expect(not _editor._room_panel_delete.disabled
		or _editor._room_panel_status.text.contains("Cannot delete"),
		"room panel stuck read-only on server")
	_expect(not _editor._room_panel_show_from_outside.disabled, "visibility checkbox still disabled")
	_editor._room_panel_show_from_outside.set_pressed_no_signal(false)
	_editor._on_room_option_toggled()
	_expect(not room.show_from_outside, "visibility flag did not mutate on server")
	# No WorldBootstrap in this scratch tree, so _floor_manager() is
	# null and the confirm press closes the panel — proof it got past
	# the readonly guard (the client path sends a request instead).
	# Delete is two-step: first press arms, second press confirms.
	_editor._open_room_panel(room)
	_editor._on_room_delete()
	_editor._on_room_delete()
	_expect(not _editor._room_panel_is_open(), "room delete refused on server")

func _report() -> void:
	if _failures.is_empty():
		print("STRUCTURAL_GUARD_SMOKE: OK")
	else:
		print("STRUCTURAL_GUARD_SMOKE: FAILED (%d)" % _failures.size())
		for failure in _failures:
			print("  FAIL: %s" % failure)
