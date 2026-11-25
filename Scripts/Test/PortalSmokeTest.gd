extends SceneTree

## Smoke test for Floor portals (Phase P1): FloorPortal resources on
## Floor.portals link a global world cell to another floor. Covers
## placement validation (room/cell/destination/duplicate/interactive-
## connection overlap), persistence through layout.json (including
## backward compatibility and malformed entries), floor/room deletion
## pruning, the player movement trigger (step onto cell -> deferred
## switch_floor -> random spawn), stale-destination safety, unchanged
## RoomConnection behavior, and the Creation Mode H tool (toggle,
## panel place/retarget/delete, invalid-cell feedback).

const SCRATCH_ROOT := "user://smoke_portal_saves"

var _world: WorldBootstrap
var _fm: FloorManager
var _room_world: RoomWorld
var _player: Player
var _editor: FloorEditor
var _controller: BlockPlacementController
var _frames := 0
var _stage := 0
var _wait := 0
var _failures: Array[String] = []

func _initialize() -> void:
	FloorSaveSystem.save_root = SCRATCH_ROOT
	_remove_dir_contents(SCRATCH_ROOT)
	_world = load("res://Scenes/World/WorldBootstrap.tscn").instantiate()
	root.add_child(_world)

func _process(_delta: float) -> bool:
	_frames += 1
	if _frames == 2:
		# The P3 slide transition defers the floor switch until the
		# slide-out finishes and locks input while it plays; zeroing
		# the slide duration keeps portal switches synchronous for
		# this frame-driven test.
		_world.room_world.room_slide_duration = 0.0
		_room_world = _world.room_world
		_fm = _world.floor_manager
		_player = _world.player
		_editor = _room_world.get_node_or_null("FloorEditor") as FloorEditor
		_controller = _world.get_node_or_null("BlockPlacementController") as BlockPlacementController
	if _frames < 8:
		return false
	match _stage:
		0:
			_setup_floors()
			_test_validation_and_lookup()
			_test_persistence()
			_test_room_delete_prune()
			_test_floor_delete_prune()
			_stage = 1
		1:
			_test_trigger_setup()
			_stage = 2
			_wait = 0
		2:
			# Wait for the deferred portal switch (floor_portal_delay
			# is 0, so the timer fires on the next process frame), then
			# for the transition fade to release the input lock.
			_wait += 1
			if _player._floor_portal_pending or _wait < 4:
				return false
			if TransitionOverlay.any_active(self) and _wait < 240:
				return false
			_test_trigger_result()
			_test_stale_portal()
			_stage = 3
		3:
			_test_connection_unchanged()
			_test_editor()
			_report()
			quit()
			return true
	return false

func _expect(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)

func _remove_dir_contents(path: String) -> void:
	var dir := DirAccess.open(path)
	if dir == null:
		return
	for file_name in dir.get_files():
		dir.remove(file_name)
	for sub in dir.get_directories():
		_remove_dir_contents(path.path_join(sub))
		DirAccess.remove_absolute(path.path_join(sub))

func _key(keycode: Key) -> InputEventKey:
	var event := InputEventKey.new()
	event.keycode = keycode
	event.physical_keycode = keycode
	event.pressed = true
	return event

func _mouse(button: MouseButton, pressed: bool) -> InputEventMouseButton:
	var event := InputEventMouseButton.new()
	event.button_index = button
	event.pressed = pressed
	return event

## Click (press+release on the same cell) via the cursor override —
## headless has no real mouse position.
func _click_cell(cell: Vector2i) -> void:
	_editor.cursor_override = cell
	_editor.cursor_override_valid = true
	_editor._process(0.0)
	_editor._unhandled_input(_mouse(MOUSE_BUTTON_LEFT, true))
	_editor._unhandled_input(_mouse(MOUSE_BUTTON_LEFT, false))
	_editor.cursor_override_valid = false

# ------------------------------------------------------------------
# Fixtures
# ------------------------------------------------------------------

func _spec(room_id: Vector2i, origin: Vector2i, size: Vector2i) -> FloorRoomSpec:
	var spec := FloorRoomSpec.new()
	spec.room_id = room_id
	spec.global_origin = origin
	spec.size = size
	return spec

## 2x2 block of 8x8 rooms; entry (0,0), spawn local (2,2) -> global
## (2,2). auto_connect=false keeps the connection graph empty.
func _quad_floor(id: StringName) -> Floor:
	var floor_def := Floor.new()
	floor_def.floor_id = id
	floor_def.display_name = String(id)
	floor_def.entry_room_id = Vector2i(0, 0)
	floor_def.spawn_position = Vector2i(2, 2)
	floor_def.auto_connect_adjacent = false
	floor_def.rooms.assign([
		_spec(Vector2i(0, 0), Vector2i(0, 0), Vector2i(8, 8)),
		_spec(Vector2i(1, 0), Vector2i(8, 0), Vector2i(8, 8)),
		_spec(Vector2i(0, 1), Vector2i(0, 8), Vector2i(8, 8)),
		_spec(Vector2i(1, 1), Vector2i(8, 8), Vector2i(8, 8)),
	])
	return floor_def

## Quad floor plus one authored INTERACTIVE connection: stepping onto
## local (5,5) of room (0,0) (global (5,5)) moves the player to local
## (0,0) of room (1,0) — same floor, no floor switch.
func _conn_floor(id: StringName) -> Floor:
	var floor_def := _quad_floor(id)
	var connection := RoomConnection.new()
	connection.connection_id = StringName("conn_%s" % id)
	connection.connection_type = RoomConnection.ConnectionType.PORTAL
	connection.source_room_id = Vector2i(0, 0)
	connection.destination_room_id = Vector2i(1, 0)
	connection.source_cells = [Vector2i(5, 5)]
	connection.destination_cells = [Vector2i(0, 0)]
	connection.interactive = true
	connection.bidirectional = false
	floor_def.connections.assign([connection])
	return floor_def

func _setup_floors() -> void:
	_fm.register_floor(_quad_floor(&"pt_a"))
	_fm.register_floor(_quad_floor(&"pt_b"))
	_fm.register_floor(_quad_floor(&"pt_c"))
	_fm.register_floor(_conn_floor(&"pt_conn"))
	_player.move_duration = 0.0
	_player.floor_portal_delay = 0.0
	_expect(_fm.switch_floor(&"pt_a"), "initial switch to pt_a failed")

# ------------------------------------------------------------------
# Stage 0: data, validation, persistence, pruning (pt_a active)
# ------------------------------------------------------------------

func _test_validation_and_lookup() -> void:
	# Cell/destination refusals.
	_expect(not bool(_fm.can_place_portal(Vector2i(100, 100), &"pt_b").get("allowed", false)),
		"portal outside rooms allowed")
	_expect(not bool(_fm.can_place_portal(Vector2i(4, 4), &"pt_a").get("allowed", false)),
		"same-floor portal allowed")
	_expect(not bool(_fm.can_place_portal(Vector2i(4, 4), &"pt_ghost").get("allowed", false)),
		"portal to unregistered floor allowed")
	_expect(not bool(_fm.can_place_portal(Vector2i(4, 4), &"").get("allowed", false)),
		"portal with empty destination allowed")
	_expect(not _fm.place_portal(Vector2i(4, 4), &"pt_ghost"), "place_portal accepted bad dest")

	# Placement: deterministic id, owning room resolved from the cell.
	_expect(_fm.place_portal(Vector2i(4, 4), &"pt_b"), "place_portal (4,4) failed")
	var portal := _fm.portal_at(Vector2i(4, 4))
	_expect(portal != null, "portal_at missed placed portal")
	if portal != null:
		_expect(portal.portal_id == &"portal_4_4", "portal id '%s' not deterministic" % portal.portal_id)
		_expect(portal.room_id == Vector2i(0, 0), "portal room_id %s wrong" % portal.room_id)
		_expect(portal.destination_floor_id == &"pt_b", "portal dest wrong")
	_expect(_fm.floor_portals(_fm.active_floor).size() == 1, "floor_portals size wrong")
	_expect(_fm.portal_at(Vector2i(4, 5)) == null, "portal_at false positive")
	_expect(_fm.portal_at_on_floor(&"pt_b", Vector2i(4, 4)) == null,
		"portal leaked onto another floor")

	# Duplicate cell refused; second portal elsewhere is fine.
	_expect(not bool(_fm.can_place_portal(Vector2i(4, 4), &"pt_c").get("allowed", false)),
		"duplicate portal cell allowed")
	_expect(not _fm.place_portal(Vector2i(4, 4), &"pt_c"), "duplicate place succeeded")
	_expect(_fm.place_portal(Vector2i(5, 5), &"pt_c"), "second portal place failed")
	_expect(_fm.floor_portals(_fm.active_floor).size() == 2, "expected 2 portals")

	# Retarget keeps id/cell, changes destination, persists.
	var before: FloorPortal = _fm.portal_at(Vector2i(4, 4))
	_expect(_fm.update_portal_destination(Vector2i(4, 4), &"pt_c"), "retarget failed")
	var after := _fm.portal_at(Vector2i(4, 4))
	_expect(after == before, "retarget replaced the portal object")
	_expect(after != null and after.destination_floor_id == &"pt_c", "retarget dest wrong")
	_expect(not _fm.update_portal_destination(Vector2i(4, 4), &"pt_a"),
		"retarget to own floor allowed")
	_expect(not _fm.update_portal_destination(Vector2i(9, 9), &"pt_b"),
		"retarget of missing portal succeeded")

	# Non-active floor APIs: place on pt_b while pt_a is active.
	_expect(_fm.place_portal_on_floor(&"pt_b", Vector2i(6, 6), &"pt_a"),
		"place_portal_on_floor failed")
	_expect(_fm.portal_at_on_floor(&"pt_b", Vector2i(6, 6)) != null,
		"portal missing on pt_b")
	var pt_b := _fm.get_floor(&"pt_b")
	_expect(pt_b != null and pt_b.portals.size() == 1, "pt_b portal count wrong")
	# Dirty attribution + persistence: the non-active floor's layout
	# was written and pt_b (not pt_a) is marked dirty.
	_expect(FileAccess.file_exists(FloorSaveSystem.layout_path(&"pt_b")),
		"place_portal_on_floor did not persist pt_b layout")
	_expect(_fm._dirty_floors.has(&"pt_b"), "pt_b not marked dirty")

	# Interactive-connection overlap is refused on a materialized floor.
	_expect(_fm.switch_floor(&"pt_conn"), "switch to pt_conn failed")
	var conn_status := _fm.portal_cell_status(Vector2i(5, 5))
	_expect(not bool(conn_status.get("free", false)),
		"portal allowed on interactive connection cell: %s" % conn_status)
	_expect(not bool(_fm.can_place_portal(Vector2i(5, 5), &"pt_a").get("allowed", false)),
		"can_place_portal allowed interactive connection cell")
	# A different cell on the same floor is still free.
	_expect(bool(_fm.portal_cell_status(Vector2i(4, 4)).get("free", false)),
		"unrelated cell refused: %s" % _fm.portal_cell_status(Vector2i(4, 4)))
	_expect(_fm.switch_floor(&"pt_a"), "switch back to pt_a failed")

func _test_persistence() -> void:
	# pt_a currently has portals at (4,4)->pt_c and (5,5)->pt_c.
	var layout := FloorSaveSystem.load_layout(&"pt_a")
	var saved_portals: Array = layout.get("portals", [])
	_expect(saved_portals.size() == 2, "layout.json portals size %d" % saved_portals.size())
	_expect(FileAccess.file_exists(FloorSaveSystem.layout_path(&"pt_a")), "layout.json missing")

	# Reload: portals must come back from disk.
	var pt_a := _fm.get_floor(&"pt_a")
	pt_a.portals.clear()  # simulate stale in-memory state
	_expect(_fm.load_floor(&"pt_a"), "reload pt_a failed")
	_expect(_fm.floor_portals(_fm.active_floor).size() == 2,
		"reloaded portal count wrong: %d" % _fm.floor_portals(_fm.active_floor).size())
	var reloaded := _fm.portal_at(Vector2i(4, 4))
	_expect(reloaded != null and reloaded.destination_floor_id == &"pt_c",
		"reloaded portal dest wrong")

	# Backward compatibility: a layout.json written before portals
	# existed (no "portals" key) must load normally.
	var pt_c := _fm.get_floor(&"pt_c")
	_expect(FloorSaveSystem.save_layout(pt_c) == OK, "save_layout pt_c failed")
	var path := FloorSaveSystem.layout_path(&"pt_c")
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	_expect(parsed is Dictionary, "pt_c layout not readable")
	if parsed is Dictionary:
		(parsed as Dictionary).erase("portals")
		var file := FileAccess.open(path, FileAccess.WRITE)
		file.store_string(JSON.stringify(parsed))
		file.close()
	_expect(_fm.load_floor(&"pt_c"), "load_floor without portals key failed")
	_expect(_fm.get_floor(&"pt_c").portals.is_empty(),
		"floor without portals key gained portals")

	# Malformed portal entries are skipped; valid ones survive; the
	# floor still loads.
	parsed = JSON.parse_string(FileAccess.get_file_as_string(path))
	if parsed is Dictionary:
		(parsed as Dictionary)["portals"] = [
			42, {"foo": "bar"}, {"id": "", "dest": "pt_a"},
			{"id": "ok1", "room_id": [0, 0], "cell": [3, 3], "dest": "pt_a"},
		]
		var file := FileAccess.open(path, FileAccess.WRITE)
		file.store_string(JSON.stringify(parsed))
		file.close()
	_expect(_fm.load_floor(&"pt_c"), "load_floor with malformed portals failed")
	var pt_c_def := _fm.get_floor(&"pt_c")
	_expect(pt_c_def.portals.size() == 1,
		"malformed portals not filtered: %d" % pt_c_def.portals.size())
	if pt_c_def.portals.size() == 1:
		_expect(pt_c_def.portals[0].portal_id == &"ok1",
			"wrong portal survived: %s" % pt_c_def.portals[0].portal_id)
	# Return to pt_a for the remaining stages.
	_expect(_fm.switch_floor(&"pt_a"), "switch back to pt_a after persistence failed")

func _test_room_delete_prune() -> void:
	# Portal inside room (1,0) of pt_a; deleting the room must prune it.
	_expect(_fm.place_portal(Vector2i(9, 1), &"pt_b"), "place portal in room (1,0) failed")
	_expect(_fm.portal_at(Vector2i(9, 1)) != null, "portal (9,1) missing")
	var verdict := _fm.can_delete_room(Vector2i(1, 0))
	_expect(bool(verdict.get("allowed", false)),
		"room (1,0) not deletable: %s" % verdict.get("reason"))
	if bool(verdict.get("allowed", false)):
		_expect(_fm.remove_room_from_active_floor(Vector2i(1, 0)), "room delete failed")
		_expect(_fm.portal_at(Vector2i(9, 1)) == null, "portal survived room delete")
		var layout := FloorSaveSystem.load_layout(&"pt_a")
		var cells: Array = []
		for raw in layout.get("portals", []):
			if raw is Dictionary:
				cells.append(raw.get("cell"))
		_expect(not cells.has([9, 1]), "layout.json kept deleted-room portal")

func _test_floor_delete_prune() -> void:
	# pt_a portals now all target pt_c; deleting pt_c must prune them.
	var pt_a := _fm.get_floor(&"pt_a")
	var targeted := 0
	for portal in pt_a.portals:
		if portal != null and portal.destination_floor_id == &"pt_c":
			targeted += 1
	_expect(targeted == pt_a.portals.size() and targeted > 0,
		"expected all pt_a portals to target pt_c: %s" % str(pt_a.portals.size()))
	_expect(_fm.delete_floor(&"pt_c"), "delete_floor pt_c failed")
	_expect(pt_a.portals.is_empty(),
		"portals to deleted floor not pruned: %d" % pt_a.portals.size())
	var layout := FloorSaveSystem.load_layout(&"pt_a")
	_expect((layout.get("portals", []) as Array).is_empty(),
		"layout.json kept portals to deleted floor")

# ------------------------------------------------------------------
# Stage 1-2: movement trigger
# ------------------------------------------------------------------

## Steps the player from spawn (2,2) onto the portal cells. move_duration
## is 0 so each request_move commits synchronously.
func _walk_to(cell: Vector2i) -> void:
	var guard := 0
	while _player.grid_position != cell and guard < 64:
		guard += 1
		var delta := cell - _player.grid_position
		var direction := Vector2i(signi(delta.x), 0) if absi(delta.x) >= absi(delta.y) \
			else Vector2i(0, signi(delta.y))
		if direction == Vector2i.ZERO:
			break
		var before := _player.grid_position
		_player.request_move(direction)
		if _player.grid_position == before:
			break  # step rejected — stop rather than spin
	_expect(_player.grid_position == cell,
		"walk to %s stalled at %s" % [cell, _player.grid_position])

func _test_trigger_setup() -> void:
	# pt_a is active; player sits at spawn (2,2) in room (0,0).
	_expect(_fm.active_floor != null and _fm.active_floor.floor_id == &"pt_a",
		"pt_a not active for trigger test")
	_expect(_player.room != null and _player.room.room_coordinates == Vector2i(0, 0),
		"player not in entry room: %s" % str(_player.room))
	_expect(_player.grid_position == Vector2i(2, 2),
		"player not at spawn: %s" % _player.grid_position)
	# Two adjacent portal cells -> pt_b: stepping on the first arms the
	# pending switch; stepping on the second must NOT retrigger.
	_expect(_fm.place_portal(Vector2i(4, 4), &"pt_b"), "trigger portal (4,4) failed")
	_expect(_fm.place_portal(Vector2i(4, 5), &"pt_b"), "trigger portal (4,5) failed")
	# Path: (2,2) -> (4,2) -> (4,4) -> (4,5). Both portal cells are
	# stepped on while _floor_portal_pending is already true.
	_walk_to(Vector2i(4, 4))
	_expect(_player.grid_position == Vector2i(4, 4),
		"player did not reach portal cell: %s" % _player.grid_position)
	_expect(_player._floor_portal_pending, "portal did not arm the pending switch")
	_walk_to(Vector2i(4, 5))
	_expect(_player._floor_portal_pending, "second portal step cleared pending state")

func _test_trigger_result() -> void:
	_expect(_fm.active_floor != null and _fm.active_floor.floor_id == &"pt_b",
		"portal did not switch floor: %s" % str(_fm.active_floor.floor_id if _fm.active_floor != null else &"none"))
	_expect(not _player._floor_portal_pending, "portal pending never cleared")
	if _player.room != null:
		_expect(_player.room.room_coordinates == Vector2i(0, 0),
			"player not in destination entry room: %s" % _player.room.room_coordinates)
		_expect(_player.grid_position == Vector2i(2, 2),
			"player not at destination spawn: %s" % _player.grid_position)
	else:
		_failures.append("player has no room after portal transition")

func _test_stale_portal() -> void:
	# pt_b is active with the player at spawn (2,2). Plant a portal
	# whose destination was unregistered behind the API's back —
	# stepping on it must behave like ordinary floor.
	_expect(_fm.place_portal(Vector2i(4, 4), &"pt_a"), "stale-test portal place failed")
	var portal := _fm.portal_at(Vector2i(4, 4))
	if portal != null:
		portal.destination_floor_id = &"pt_ghost"
	_walk_to(Vector2i(4, 4))
	_expect(_player.grid_position == Vector2i(4, 4),
		"stale portal blocked movement: %s" % _player.grid_position)
	_expect(not _player._floor_portal_pending, "stale portal armed a transition")
	_expect(_fm.active_floor != null and _fm.active_floor.floor_id == &"pt_b",
		"stale portal switched floor")

# ------------------------------------------------------------------
# Stage 3: RoomConnection unchanged + Creation Mode editor
# ------------------------------------------------------------------

func _test_connection_unchanged() -> void:
	_expect(_fm.switch_floor(&"pt_conn"), "switch to pt_conn failed")
	_expect(_player.room != null and _player.room.room_coordinates == Vector2i(0, 0),
		"pt_conn player not in entry room")
	# The interactive connection at global (5,5) must still fire: the
	# player lands in room (1,0) on the SAME floor — no floor switch.
	_walk_to(Vector2i(5, 5))
	_expect(_player.room != null and _player.room.room_coordinates == Vector2i(1, 0),
		"interactive connection did not transition rooms: %s" % \
			str(_player.room.room_coordinates if _player.room != null else &"none"))
	_expect(_fm.active_floor != null and _fm.active_floor.floor_id == &"pt_conn",
		"connection step switched floors")
	_expect(not _player._floor_portal_pending, "connection step armed a portal")

func _test_editor() -> void:
	_expect(_editor != null, "FloorEditor missing")
	if _editor == null:
		return
	_expect(_fm.switch_floor(&"pt_a"), "editor stage switch to pt_a failed")

	# Enter Build then Creation Mode.
	_controller._unhandled_input(_key(KEY_E))
	_expect(_controller.construction_mode, "E did not enable build mode")
	_editor._unhandled_input(_key(KEY_F))
	_expect(_editor.active, "F did not enter creation mode")

	# H toggles the portal tool; another tool exits it.
	_editor._unhandled_input(_key(KEY_H))
	_expect(_editor.tool == FloorEditor.Tool.PORTAL, "H did not activate portal tool")
	_editor._unhandled_input(_key(KEY_H))
	_expect(_editor.tool == FloorEditor.Tool.NONE, "second H did not exit portal tool")
	_editor._unhandled_input(_key(KEY_H))
	_editor._unhandled_input(_key(KEY_C))
	_expect(_editor.tool == FloorEditor.Tool.CREATE_ROOM, "C did not switch to create tool")
	_editor._unhandled_input(_key(KEY_H))
	_expect(_editor.tool == FloorEditor.Tool.PORTAL, "H did not re-activate portal tool")

	# Place through the panel: click a free in-room cell, pick a
	# destination, apply.
	_click_cell(Vector2i(6, 6))
	_expect(_editor._portal_panel_is_open(), "portal panel did not open on click")
	_expect(_editor._portal_panel_existing == null, "panel thought (6,6) had a portal")
	var dest_index := _editor._portal_dest_ids.find(&"pt_b")
	_expect(dest_index >= 0, "pt_b missing from destination list")
	if dest_index >= 0:
		_editor._portal_panel_dest.select(dest_index)
	_editor._on_portal_apply()
	var placed := _fm.portal_at(Vector2i(6, 6))
	_expect(placed != null, "panel apply did not place portal")
	if placed != null:
		_expect(placed.destination_floor_id == &"pt_b", "panel portal dest wrong")
	_expect(not _editor._portal_panel_is_open(), "panel still open after place")

	# Retarget: click the portal cell -> edit mode -> new destination.
	# (pt_a also carries the two trigger portals from earlier stages —
	# retarget must not change the total count.)
	var portal_count := _fm.floor_portals(_fm.active_floor).size()
	_click_cell(Vector2i(6, 6))
	_expect(_editor._portal_panel_is_open(), "edit panel did not open")
	_expect(_editor._portal_panel_existing != null, "panel did not detect existing portal")
	var conn_index := _editor._portal_dest_ids.find(&"pt_conn")
	if conn_index >= 0:
		_editor._portal_panel_dest.select(conn_index)
	_editor._on_portal_apply()
	var retargeted := _fm.portal_at(Vector2i(6, 6))
	_expect(retargeted != null and retargeted.destination_floor_id == &"pt_conn",
		"retarget failed")
	_expect(_fm.floor_portals(_fm.active_floor).size() == portal_count,
		"retarget changed the portal count")

	# Delete through the panel.
	_click_cell(Vector2i(6, 6))
	_expect(_editor._portal_panel_delete.visible, "delete button hidden for existing portal")
	_editor._on_portal_delete()
	_expect(_fm.portal_at(Vector2i(6, 6)) == null, "panel delete did not remove portal")

	# Invalid cell: outside every room the panel opens but Place is
	# disabled with a reason.
	_click_cell(Vector2i(50, 50))
	_expect(_editor._portal_panel_is_open(), "panel did not open on invalid cell")
	_expect(_editor._portal_panel_apply.disabled, "Place enabled on invalid cell")
	_expect(_editor._portal_panel_status.text != "", "no invalid-cell feedback")
	_editor._unhandled_input(_key(KEY_ESCAPE))
	_expect(not _editor._portal_panel_is_open(), "Escape did not close portal panel")

	# Occupied cell: the spawn cell already hosts a spawn point but is
	# portal-free — placement must succeed there (portals and spawn
	# points coexist). (2,2) is spawn_points[0] AND free for portals.
	_click_cell(Vector2i(2, 2))
	_expect(_editor._portal_panel_is_open(), "panel did not open on spawn cell")
	_expect(not _editor._portal_panel_apply.disabled,
		"portal refused on spawn-point cell")
	_editor._unhandled_input(_key(KEY_ESCAPE))

	# Exit cleanly.
	_editor._unhandled_input(_key(KEY_ESCAPE))
	_expect(not _editor.active, "editor did not exit")

func _report() -> void:
	if _failures.is_empty():
		print("PORTAL_SMOKE: OK")
	else:
		for failure in _failures:
			printerr("PORTAL_SMOKE FAIL: " + failure)
		printerr("PORTAL_SMOKE: %d failure(s)" % _failures.size())
