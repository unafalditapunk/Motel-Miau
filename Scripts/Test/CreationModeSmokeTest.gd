extends SceneTree

## Smoke test for Creation Mode (FloorEditor): Q enters/exits from Build
## Mode, Escape returns to Build, player movement and building input are
## blocked while active, the global grid tracks the cursor at any zoom,
## camera pan/zoom/reset work in empty space, view toggling works, a
## floor switch exits the editor, and leaving restores normal input.

const SCRATCH_ROOT := "user://smoke_creation_saves"

var _frames := 0
var _failures: Array[String] = []
var _world: WorldBootstrap
var _editor: FloorEditor
var _camera: WorldCamera
var _controller: BlockPlacementController
var _player: Player
var _room_world: RoomWorld
var _grid: IsometricGrid

func _initialize() -> void:
	FloorSaveSystem.save_root = SCRATCH_ROOT
	_remove_dir_contents(SCRATCH_ROOT)
	_world = load("res://Scenes/World/WorldBootstrap.tscn").instantiate()
	root.add_child(_world)

func _process(_delta: float) -> bool:
	_frames += 1
	if _frames == 2:
		# P3 slide transitions defer the floor switch until the
		# slide-out finishes; zeroing the slide duration keeps
		# switches synchronous for this frame-driven test.
		_world.room_world.room_slide_duration = 0.0
		_room_world = _world.room_world
		_editor = _room_world.get_node_or_null("FloorEditor") as FloorEditor
		_camera = _world.world_camera
		_controller = _world.get_node_or_null("BlockPlacementController") as BlockPlacementController
		_player = _world.player
		_grid = _room_world.grid
	if _frames < 8:
		return false
	_run_checks()
	_report()
	quit()
	return true

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

## Detects the global cell under a world cell by round-tripping it
## through the camera's screen transform — the same chain the real
## mouse path uses (warp_mouse is a no-op under headless).
func _cell_at_screen_for(world_cell: Vector2) -> Vector2i:
	var screen_pos := _camera.world_to_screen(_grid.grid_to_screen_position(world_cell, 0.0))
	var world_pos := _camera.screen_to_world(screen_pos)
	return _editor.cursor_cell_for_world_position(world_pos)

func _mouse(button: MouseButton, pressed: bool) -> InputEventMouseButton:
	var event := InputEventMouseButton.new()
	event.button_index = button
	event.pressed = pressed
	return event

## Simulates an LMB drag between two world cells using the cursor
## override (headless has no real mouse position).
func _drag_cells(from_cell: Vector2i, to_cell: Vector2i) -> void:
	_editor.cursor_override = from_cell
	_editor.cursor_override_valid = true
	_editor._process(0.0)
	_editor._unhandled_input(_mouse(MOUSE_BUTTON_LEFT, true))
	_editor.cursor_override = to_cell
	_editor._process(0.0)
	_editor._unhandled_input(_mouse(MOUSE_BUTTON_LEFT, false))
	_editor.cursor_override_valid = false

## Simulates a click (press+release on the same cell).
func _click_cell(cell: Vector2i) -> void:
	_drag_cells(cell, cell)

func _run_checks() -> void:
	_expect(_editor != null, "FloorEditor missing from RoomWorld")
	_expect(_camera != null, "WorldCamera missing")
	_expect(_controller != null and _player != null and _grid != null, "world refs missing")
	if _editor == null or _camera == null or _controller == null or _player == null or _grid == null:
		return
	_player.move_duration = 0.0
	var gameplay_zoom_count := _camera.zoom_levels.size()

	# --- Initial state: inactive, gameplay camera ---
	_expect(not _editor.active, "editor active before entering creation mode")
	_expect(not FloorEditor.any_active(self), "any_active true before entering")
	_expect(not _camera.is_editor_active(), "camera in editor mode before entering")

	# --- F/Q in Play Mode do nothing ---
	_editor._unhandled_input(_key(KEY_F))
	_expect(not _editor.active, "F entered creation mode from play mode")
	_editor._unhandled_input(_key(KEY_Q))
	_expect(not _editor.active, "Q entered creation mode from play mode")

	# --- E enters Build, F enters Creation ---
	_controller._unhandled_input(_key(KEY_E))
	_expect(_controller.construction_mode, "E did not enable build mode")
	var cam_pos_before_enter := _camera.global_position
	_editor._unhandled_input(_key(KEY_F))
	_expect(_editor.active, "F did not enter creation mode from build mode")
	_expect(FloorEditor.any_active(self), "any_active false while editing")
	_expect(_camera.is_editor_active(), "camera did not enter editor mode")
	_expect(_controller.construction_mode, "creation mode should keep build mode flag")
	_expect(_editor.visible, "editor grid not visible in grid view")
	_expect(_room_world.hide_rooms_outside_neighborhood == false, "neighborhood hiding not suspended")
	_expect(_room_world.deemphasize_neighbors == false, "de-emphasis not suspended")

	# --- Player movement and building input blocked ---
	_expect(_player._world_ui_blocked(), "player not blocked while editing")
	var pos_before := _player.grid_position
	_player.request_move(Vector2i(1, 0))
	_expect(_player.grid_position == pos_before, "player moved while editing")
	_controller._unhandled_input(_key(KEY_E))
	_expect(_controller.construction_mode, "E toggled build mode off while editing (input should be blocked)")
	var catalog := _world.get_node_or_null("CatalogPanel") as CatalogPanel
	if catalog != null:
		catalog.open()
		catalog.toggle()
		_expect(not catalog.catalog_open, "catalog opened during creation mode")

	# --- Blueprint view: world contents hidden ---
	_editor._process(0.0)
	var sample_room := _room_world.get_rooms()[0]
	for node_name in [&"FloorRenderer", &"TileLayer", &"CarpetLayer", &"BlockLayer", &"HoverHighlight"]:
		var node := sample_room.get_node_or_null(NodePath(node_name)) as CanvasItem
		_expect(node != null and not node.visible, "room %s still visible in grid view" % node_name)
	_expect(not _player.visible, "player avatar still visible in grid view")
	var ghost := _world.get_node_or_null("PlacementGhost") as CanvasItem
	_expect(ghost != null and not ghost.visible, "placement ghost still visible in grid view")

	# --- Camera stays where the player was looking on entry ---
	_expect(_camera.global_position.distance_to(cam_pos_before_enter) < 0.5,
		"camera jumped on creation mode entry: %s -> %s" % [cam_pos_before_enter, _camera.global_position])
	var bounds := _room_world.get_world_cell_bounds()
	_expect(bounds.has_area(), "no room bounds for overview check")
	var mid := Vector2(bounds.position) + Vector2(bounds.size) * 0.5
	var expected_center := _grid.grid_to_screen_position(mid, 0.0)

	# Middle-mouse drag pans the camera.
	var drag_button := InputEventMouseButton.new()
	drag_button.button_index = MOUSE_BUTTON_MIDDLE
	drag_button.pressed = true
	_camera._unhandled_input(drag_button)
	var motion := InputEventMouseMotion.new()
	motion.relative = Vector2(200.0, -100.0)
	motion.position = Vector2(300.0, 200.0)
	var pos_before_pan := _camera.global_position
	_camera._unhandled_input(motion)
	var expected_delta := -Vector2(200.0, -100.0) / _camera.zoom.x
	_expect((_camera.global_position - pos_before_pan - expected_delta).length() < 0.5,
		"middle-drag pan wrong: delta %s expected %s" % [_camera.global_position - pos_before_pan, expected_delta])
	var release := InputEventMouseButton.new()
	release.button_index = MOUSE_BUTTON_MIDDLE
	release.pressed = false
	_camera._unhandled_input(release)

	# --- Cursor-to-global-cell, including negative coords ---
	var detected := _cell_at_screen_for(Vector2(-30.0, 40.0))
	_expect(detected == Vector2i(-30, 40), "cursor cell %s != (-30, 40) in empty space" % detected)
	detected = _cell_at_screen_for(Vector2(5.0, -7.0))
	_expect(detected == Vector2i(5, -7), "cursor cell %s != (5, -7)" % detected)

	# Occupied vs free detection on a real room cell (legacy room at origin).
	var occupied_room := _room_world.get_room_at_world_cell(Vector2i(1, 1))
	_expect(occupied_room != null, "expected a room covering world cell (1,1)")
	detected = _cell_at_screen_for(Vector2(1.0, 1.0))
	_expect(detected == Vector2i(1, 1), "cursor cell %s != (1, 1) on room" % detected)
	_expect(_room_world.get_room_at_world_cell(detected) != null, "occupied cell not detected as occupied")

	# --- Zoom does not break mouse->grid conversion ---
	for zoom_index in [0, 3]:
		_camera.set_zoom_level(zoom_index)
		detected = _cell_at_screen_for(Vector2(4.0, -3.0))
		_expect(detected == Vector2i(4, -3), "cursor cell %s wrong at zoom %.2f" % [detected, _camera.zoom.x])
		# Roundtrip through the camera transform at this zoom.
		var world_pos := _grid.grid_to_screen_position(Vector2(9.0, 2.0), 0.0)
		var screen_pos := _camera.world_to_screen(world_pos)
		var back := _grid.screen_to_grid(_camera.screen_to_world(screen_pos))
		_expect(back == Vector2i(9, 2), "zoom %.2f broke world<->screen roundtrip (got %s)" % [_camera.zoom.x, back])
	_camera.set_zoom_level(2)

	# --- View toggle: GRID <-> ROOMS ---
	_editor._unhandled_input(_key(KEY_V))
	_expect(_editor.view_mode == FloorEditor.ViewMode.ROOMS, "V did not switch to room view")
	_expect(not _editor.visible, "editor still visible in room view")
	_editor._process(0.0)
	var rooms_floor := sample_room.get_node_or_null("FloorRenderer") as CanvasItem
	_expect(rooms_floor != null and rooms_floor.visible, "room floor not restored in room view")
	_expect(_player.visible, "player not restored in room view")
	# Both views keep the normal gameplay zoom ladder.
	_expect(_camera.zoom_levels.size() == gameplay_zoom_count, "room view changed the zoom ladder")
	_editor._unhandled_input(_key(KEY_V))
	_expect(_editor.view_mode == FloorEditor.ViewMode.GRID, "V did not switch back to grid view")
	_expect(_editor.visible, "editor not visible back in grid view")
	_editor._process(0.0)
	_expect(not rooms_floor.visible, "room floor not hidden back in grid view")
	_expect(_camera.zoom_levels.size() == gameplay_zoom_count, "grid view changed the zoom ladder")

	# --- Home resets the camera to the floor overview ---
	_camera.focus_on(Vector2(9999.0, 9999.0), 5)
	_editor._unhandled_input(_key(KEY_B))
	_expect(_camera.global_position.distance_to(expected_center) < 1.0, "Home did not reset camera to overview")
	_expect(is_equal_approx(_camera.zoom.x, _camera.zoom_levels[_camera.zoom_levels.size() - 1]), "Home did not zoom out to overview")

	# --- Escape returns to Build Mode ---
	_editor._unhandled_input(_key(KEY_ESCAPE))
	_expect(not _editor.active, "Escape did not exit creation mode")
	_expect(not _camera.is_editor_active(), "camera still in editor mode after exit")
	_expect(not FloorEditor.any_active(self), "any_active true after exit")
	_expect(_controller.construction_mode, "build mode lost after escaping creation")
	_expect(_room_world.hide_rooms_outside_neighborhood, "neighborhood hiding not restored")
	_expect(_room_world.deemphasize_neighbors, "de-emphasis not restored")
	var restored_room := _room_world.get_rooms()[0]
	var restored_layer := restored_room.get_node_or_null("BlockLayer") as CanvasItem
	_expect(restored_layer != null and restored_layer.visible, "room contents not restored after exit")
	_expect(_player.visible, "player avatar not restored after exit")

	# --- Normal input restored ---
	pos_before = _player.grid_position
	_player.request_move(Vector2i(1, 0))
	_expect(_player.grid_position != pos_before, "player movement still blocked after exit")
	_controller._unhandled_input(_key(KEY_E))
	_expect(not _controller.construction_mode, "E did not leave build mode after creation exit")

	# --- Re-enter and switch floors: editor must exit cleanly ---
	_controller._unhandled_input(_key(KEY_E))
	_editor._unhandled_input(_key(KEY_F))
	_expect(_editor.active, "F did not re-enter creation mode")
	_expect(_world.switch_floor(&"forest"), "switch to forest failed")
	_expect(not _editor.active, "editor still active after floor switch")
	_expect(not _camera.is_editor_active(), "camera stuck in editor mode after floor switch")
	_expect(_world.floor_manager.active_floor != null and _world.floor_manager.active_floor.floor_id == &"forest",
		"active floor is not forest")
	_expect(_room_world.registry.get_rooms().size() == 9, "forest rooms = %d" % _room_world.registry.get_rooms().size())

	# --- Grid still works on the new floor; occupied cells detected ---
	# Build mode survived the floor switch, so F enters directly.
	_expect(_controller.construction_mode, "build mode lost across floor switch")
	_editor._unhandled_input(_key(KEY_F))
	_expect(_editor.active, "F did not enter creation mode on forest")
	# Forest room (1,1) sits at global origin (16,16) size 16x16, so
	# world cell (20,20) is inside it; (-20,-20) is empty floor space.
	detected = _cell_at_screen_for(Vector2(20.0, 20.0))
	_expect(detected == Vector2i(20, 20), "cursor cell %s wrong on forest" % detected)
	_expect(_room_world.get_room_at_world_cell(detected) != null, "forest room cell not detected as occupied")
	detected = _cell_at_screen_for(Vector2(-20.0, -20.0))
	_expect(detected == Vector2i(-20, -20), "cursor cell %s wrong in empty forest space" % detected)
	_expect(_room_world.get_room_at_world_cell(detected) == null, "empty forest cell detected as occupied")

	# --- Create Room tool: drag-select on the global grid ---
	# Forest occupies cells 0..48; (-16,0)..(0,16) shares the x=0 edge
	# with the (0,0) room — the only kind of placement allowed now.
	_editor._unhandled_input(_key(KEY_C))
	_expect(_editor.tool == FloorEditor.Tool.CREATE_ROOM, "C did not activate the create tool")
	_expect(_editor.view_mode == FloorEditor.ViewMode.GRID, "create tool did not ensure grid view")

	# Dragging works in every direction: reversed corners give the same rect.
	_expect(FloorEditor._rect_from_cells(Vector2i(-1, 15), Vector2i(-16, 0)) \
		== Rect2i(Vector2i(-16, 0), Vector2i(16, 16)), "reversed drag produced wrong rect")
	_expect(_editor._shape_validity([Rect2i(Vector2i(-16, 0), Vector2i(16, 16))]) \
		== FloorEditor.SelectionValidity.VALID, "edge-adjacent selection not valid")
	_expect(_editor._shape_validity([Rect2i(Vector2i(40, 40), Vector2i(8, 8))]) \
		== FloorEditor.SelectionValidity.OVERLAP, "overlapping selection not detected")
	_expect(_editor._shape_validity([Rect2i(Vector2i.ZERO, Vector2i(2000, 4))]) \
		== FloorEditor.SelectionValidity.INVALID, "oversized selection not invalid")
	_expect(_editor._shape_validity([Rect2i(Vector2i(60, 60), Vector2i(1, 5))]) \
		== FloorEditor.SelectionValidity.INVALID, "sub-2-cell axis not invalid")
	_expect(_editor._shape_validity([Rect2i(Vector2i(48, 0), Vector2i(2, 2))]) \
		== FloorEditor.SelectionValidity.VALID, "small edge-adjacent selection not valid")
	_expect(_editor._shape_validity([Rect2i(Vector2i(60, 60), Vector2i(8, 8))]) \
		== FloorEditor.SelectionValidity.ISOLATED, "detached selection not flagged")

	# Multi-section shapes: connected unions are valid, disconnected
	# or self-overlapping ones are not.
	_expect(_editor._shape_validity([
			Rect2i(Vector2i(-16, 0), Vector2i(16, 16)),
			Rect2i(Vector2i(-16, 16), Vector2i(8, 8))]) \
		== FloorEditor.SelectionValidity.VALID, "connected two-section shape not valid")
	_expect(_editor._shape_validity([
			Rect2i(Vector2i(-16, 0), Vector2i(16, 16)),
			Rect2i(Vector2i(40, 40), Vector2i(8, 8))]) \
		== FloorEditor.SelectionValidity.DISCONNECTED, "detached sections not flagged")
	_expect(_editor._shape_validity([
			Rect2i(Vector2i(-16, 0), Vector2i(16, 16)),
			Rect2i(Vector2i(-8, 8), Vector2i(8, 8))]) \
		== FloorEditor.SelectionValidity.OVERLAP, "self-overlapping sections not flagged")

	_drag_cells(Vector2i(-16, 0), Vector2i(-1, 15))
	_expect(not _editor._dragging, "mouse release did not end the drag")
	_expect(_editor._pending_sections == [Rect2i(Vector2i(-16, 0), Vector2i(16, 16))],
		"pending sections %s wrong" % _editor._pending_sections)
	# Releasing the mouse keeps the selection; X opens the panel.
	_expect(not _editor._panel_is_open(), "panel opened on mouse release")
	_editor._unhandled_input(_key(KEY_X))
	_expect(_editor._panel_is_open(), "X did not open the confirmation panel")
	_expect(not _editor._panel_create.disabled, "create button disabled for a valid free area")
	_expect(_editor._panel_info.text.contains("16x16"), "panel info missing bounds: %s" % _editor._panel_info.text)
	# Room id is auto-assigned and not user-editable.
	_expect(not _editor._panel_id_edit.editable, "room id field still editable")
	_expect(_editor._panel_id_edit.text == _editor._next_room_id_label(),
		"auto id '%s' != expected '%s'" % [_editor._panel_id_edit.text, _editor._next_room_id_label()])

	# Room id editing: duplicates and malformed ids are rejected.
	var room_count_before := _room_world.registry.get_rooms().size()
	_editor._panel_id_edit.text = "1,1"
	_editor._on_panel_create()
	_expect(_room_world.registry.get_rooms().size() == room_count_before, "duplicate room id created a room")
	_expect(_editor._panel_status.text.contains("already used"), "duplicate id error not shown")
	_editor._panel_id_edit.text = "not-an-id"
	_editor._on_panel_create()
	_expect(_room_world.registry.get_rooms().size() == room_count_before, "malformed id created a room")
	_expect(_editor._panel_status.text.contains("two integers"), "malformed id error not shown")
	_editor._cancel_pending()
	_expect(not _editor._panel_is_open(), "cancel did not close the panel")
	_expect(_editor._pending_sections.is_empty(), "cancel did not clear the pending sections")

	# A drag that lands on existing rooms is discarded outright: nothing
	# stays pending and X has no selection to confirm.
	_drag_cells(Vector2i(40, 40), Vector2i(47, 47))
	_expect(_editor._pending_sections.is_empty(), "overlapping drag left a pending section")
	_editor._unhandled_input(_key(KEY_X))
	_expect(not _editor._panel_is_open(), "panel opened for a discarded overlap drag")

	# Isolated selection (no shared edge) also disables Create.
	_drag_cells(Vector2i(60, 60), Vector2i(67, 67))
	_editor._unhandled_input(_key(KEY_X))
	_expect(_editor._panel_is_open(), "isolated selection did not open the panel")
	_expect(_editor._panel_create.disabled, "create enabled for isolated area")
	_expect(_editor._panel_status.text.contains("edge"), "isolated status not shown: '%s'" % _editor._panel_status.text)
	_editor._cancel_pending()

	# Confirm a valid room at negative coordinates, with both
	# visibility options turned off.
	_drag_cells(Vector2i(-16, 0), Vector2i(-1, 15))
	_editor._unhandled_input(_key(KEY_X))
	_editor._panel_show_from_outside.button_pressed = false
	_editor._panel_show_outside.button_pressed = false
	_editor._panel_id_edit.text = "9,9"
	_editor._on_panel_create()
	var created := _room_world.get_room(Vector2i(9, 9))
	_expect(created != null, "created room (9,9) not registered")
	if created != null:
		_expect(created.show_from_outside == false and created.show_outside == false,
			"visibility options not applied to created room")
	if created != null:
		_expect(created.global_bounds() == Rect2i(Vector2i(-16, 0), Vector2i(16, 16)),
			"created room bounds %s wrong" % created.global_bounds())
	_expect(_room_world.registry.get_rooms().size() == room_count_before + 1,
		"room count did not grow after creation")
	_expect(not _editor._panel_is_open(), "panel still open after creation")
	_expect(_editor._notice.contains("9,9"), "creation notice missing: '%s'" % _editor._notice)
	# Layout override was persisted under user:// for the active floor.
	var layout_path := FloorSaveSystem.layout_path(&"forest")
	_expect(FileAccess.file_exists(layout_path), "layout.json not written for forest")

	# --- Room inspector: click a room to inspect it ---
	# A click inside the created room (bounds x -16..0, y 0..16) opens
	# the info panel; the empty, adjacency-safe room is deletable.
	_click_cell(Vector2i(-8, 8))
	_expect(_editor._room_panel_is_open(), "room panel did not open on click")
	_expect(_editor._room_panel_info.text.contains("9,9"), "room panel missing id: '%s'" % _editor._room_panel_info.text)
	_expect(_editor._room_panel_contents.text.contains("empty"), "room panel contents wrong: '%s'" % _editor._room_panel_contents.text)
	_expect(not _editor._room_panel_delete.disabled, "delete disabled for empty safe room")
	# The inspector checkboxes reflect the room's options and toggling
	# one updates the live room (created with both options off).
	_expect(not _editor._room_panel_show_from_outside.button_pressed, "inspector checkbox not synced")
	# button_pressed= does not emit toggled headless; drive the handler.
	_editor._room_panel_show_from_outside.button_pressed = true
	_editor._on_room_option_toggled()
	_expect(created != null and created.show_from_outside, "option toggle not applied live")
	_editor._close_room_panel()

	# The room the player stands in refuses deletion.
	var player_bounds := _player.room.global_bounds()
	var player_cell := player_bounds.position + player_bounds.size / 2
	_click_cell(player_cell)
	_expect(_editor._room_panel_is_open(), "player room panel did not open")
	_expect(_editor._room_panel_delete.disabled, "delete enabled while player inside")
	_expect(_editor._room_panel_status.text.contains("inside"), "player-inside reason missing: '%s'" % _editor._room_panel_status.text)
	_editor._unhandled_input(_key(KEY_ESCAPE))
	_expect(not _editor._room_panel_is_open(), "Escape did not close the room panel")

	# Delete the created room: first press arms the confirm, second deletes.
	_click_cell(Vector2i(-8, 8))
	_expect(_editor._room_panel_is_open(), "room panel did not reopen")
	_editor._on_room_delete()
	_expect(_room_world.get_room(Vector2i(9, 9)) != null, "room (9,9) deleted without confirm")
	_expect(_editor._room_panel_status.text.contains("Confirm"), "confirm prompt missing: '%s'" % _editor._room_panel_status.text)
	_editor._on_room_delete()
	_expect(_room_world.get_room(Vector2i(9, 9)) == null, "room (9,9) not deleted")
	_expect(_room_world.registry.get_rooms().size() == room_count_before,
		"room count wrong after delete: %d" % _room_world.registry.get_rooms().size())
	_expect(not _editor._room_panel_is_open(), "room panel still open after delete")
	var layout_after := FloorSaveSystem.load_layout(&"forest")
	_expect((layout_after.get("rooms", []) as Array).size() == 9, "layout.json still lists deleted room")

	# Esc cancels an in-progress drag instead of exiting.
	_editor.cursor_override = Vector2i(-30, -30)
	_editor.cursor_override_valid = true
	_editor._process(0.0)
	_editor._unhandled_input(_mouse(MOUSE_BUTTON_LEFT, true))
	_expect(_editor._dragging, "second drag did not start")
	_editor._unhandled_input(_key(KEY_ESCAPE))
	_expect(not _editor._dragging, "Escape did not cancel the drag")
	_expect(_editor.active, "Escape exited creation mode while dragging")
	_editor.cursor_override_valid = false

	# Tool toggle off: LMB no longer starts a selection.
	_editor._unhandled_input(_key(KEY_C))
	_expect(_editor.tool == FloorEditor.Tool.NONE, "C did not toggle the tool off")
	_editor._unhandled_input(_mouse(MOUSE_BUTTON_LEFT, true))
	_expect(not _editor._dragging, "drag started with tool disabled")
	_editor._unhandled_input(_key(KEY_C))
	_expect(_editor.tool == FloorEditor.Tool.CREATE_ROOM, "C did not re-enable the tool")

	_editor._unhandled_input(_key(KEY_F))
	_expect(not _editor.active, "F did not exit creation mode on forest")

	# --- Empty floor: grid/editor still functions with zero rooms ---
	var empty := Floor.new()
	empty.floor_id = &"editor_empty"
	empty.display_name = "Editor Empty"
	empty.entry_room_id = Vector2i.ZERO
	empty.spawn_position = Vector2i.ZERO
	_world.floor_manager.register_floor(empty)
	_expect(_world.floor_manager.materialize_floor(empty), "empty floor materialization failed")
	_expect(_room_world.registry.get_rooms().is_empty(), "empty floor should have no rooms")
	_expect(_editor.enter(), "editor failed to enter on empty floor")
	_expect(_editor.active, "editor inactive on empty floor")
	_editor._update_cursor_cell()
	_expect(_cursor_cell_sane(), "cursor cell invalid on empty floor")
	_editor.exit()
	# Restore a real floor so shutdown save/load state stays sane.
	_expect(_world.floor_manager.load_floor(&"forest"), "forest reload after empty-floor test failed")

func _cursor_cell_sane() -> bool:
	return _editor.cursor_cell_valid

func _report() -> void:
	if _failures.is_empty():
		print("CREATION_MODE_SMOKE: OK")
	else:
		for failure in _failures:
			push_error("CREATION_MODE_SMOKE FAIL: " + failure)
		print("CREATION_MODE_SMOKE: FAILED (%d)" % _failures.size())
