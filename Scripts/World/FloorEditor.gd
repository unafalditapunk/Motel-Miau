class_name FloorEditor
extends Node2D

## Creation Mode: a global floor-layout editor. While active it draws an
## isometric grid over the ENTIRE floor's world-cell space — including
## empty areas with no rooms — shades registered room bounds as occupied,
## highlights the cell under the cursor, and detaches the camera from
## the player for free pan/zoom navigation.
##
## The grid is a lightweight _draw() overlay; no Room or RoomCell nodes
## are created for empty space. Two views: GRID (grid + occupancy) and
## ROOMS (editor hidden, rooms shown normally with neighborhood
## emphasis suspended so every room is visible).
##
## Mode flow: E toggles Build Mode (BlockPlacementController); F enters
## Creation Mode from Build Mode and returns to it; Q (catalog) and
## Escape also return to Build Mode. Leaving Build Mode exits Creation
## Mode entirely. Player movement and object placement are blocked via
## FloorEditor.any_active() checks in Player and
## BlockPlacementController.

enum ViewMode { GRID, ROOMS }
## Editing tool: NONE = camera/navigation only, CREATE_ROOM = drag a
## rectangle on the global grid to define a new room's bounds.
enum Tool { NONE, CREATE_ROOM }
enum SelectionValidity { VALID, OVERLAP, ISOLATED, INVALID }

const GROUP := &"floor_editor"
const HUD_LAYER := 67
const PANEL_LAYER := 68
const VIEW_TOGGLE_KEY := KEY_V
const RESET_VIEW_KEY := KEY_B
const CREATE_TOOL_KEY := KEY_C
const CONFIRM_KEY := KEY_X
## Sanity cap per axis; the coordinate space itself stays unbounded.
const MAX_ROOM_DIMENSION := 1024
## Min cells per axis — shared rule lives on Floor.
const MIN_ROOM_DIMENSION := Floor.MIN_ROOM_DIMENSION
## Max cells drawn per axis; guards against pathological zoom-outs.
const MAX_DRAW_AXIS := 1024
## Room child nodes hidden in GRID view: the blueprint shows only room
## bounds + grid lines. ROOMS view restores everything for inspection.
const HIDDEN_ROOM_CHILDREN := [&"FloorRenderer", &"TileLayer", &"CarpetLayer",
	&"BlockLayer", &"HoverHighlight", &"ConnectionMarkers", &"RoomLabel"]

## True while Creation Mode is active. Player/placement input checks
## this static helper, mirroring FloorPanel.any_open().
static func any_active(tree: SceneTree) -> bool:
	if tree == null:
		return false
	var editor := tree.get_first_node_in_group(GROUP) as FloorEditor
	return editor != null and editor.active

var active := false
var view_mode := ViewMode.GRID
var tool := Tool.NONE
## Global world-cell under the cursor (valid only while active).
var cursor_cell := Vector2i.ZERO
var cursor_cell_valid := false
## Test hook: when set, _update_cursor_cell reports this cell instead
## of reading the OS mouse position (headless has no real cursor).
var cursor_override := Vector2i.ZERO
var cursor_override_valid := false

# Create Room tool state. _drag_anchor/_drag_current are inclusive cell
# corners; _pending_rect is the finished selection awaiting the
# confirmation panel (kept drawn until resolved or cancelled).
var _dragging := false
var _drag_anchor := Vector2i.ZERO
var _drag_current := Vector2i.ZERO
## LMB press tracking for room clicks — independent of the create
## tool so rooms can be inspected with Tool.NONE active.
var _pressing := false
var _press_cell := Vector2i.ZERO
var _pending_rect := Rect2i()
var _panel_layer: CanvasLayer
var _panel: PanelContainer
var _panel_id_edit: LineEdit
var _panel_info: Label
var _panel_status: Label
var _panel_create: Button
var _panel_show_from_outside: CheckBox
var _panel_show_outside: CheckBox
var _notice := ""
var _notice_until_ms := 0
# Room inspector panel (click a room in GRID view).
var _room_panel_layer: CanvasLayer
var _room_panel: PanelContainer
var _room_panel_info: Label
var _room_panel_contents: Label
var _room_panel_status: Label
var _room_panel_delete: Button
var _room_panel_show_from_outside: CheckBox
var _room_panel_show_outside: CheckBox
var _room_panel_room: Room = null

var _room_world: RoomWorld
var _grid: IsometricGrid
var _camera: WorldCamera
var _saved_hide_outside := true
var _saved_deemphasize := true
var _controller_hooked := false
var _hud_layer: CanvasLayer
var _hud_label: Label
## [CanvasItem, was_visible] pairs hidden for the blueprint view.
var _hidden_items: Array = []

func _ready() -> void:
	add_to_group(GROUP)
	# Draw above room contents and entities; hidden unless a view needs it.
	z_as_relative = false
	z_index = 4095
	visible = false
	_build_hud()
	_build_panel()
	_build_room_panel()

func _build_hud() -> void:
	_hud_layer = CanvasLayer.new()
	_hud_layer.name = "CreationHud"
	_hud_layer.layer = HUD_LAYER
	add_child(_hud_layer)
	var margin := MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_TOP_LEFT)
	for side in [&"margin_left", &"margin_top"]:
		margin.add_theme_constant_override(side, 8)
	margin.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_hud_layer.add_child(margin)
	_hud_label = Label.new()
	_hud_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_hud_label.add_theme_font_size_override(&"font_size", 10)
	_hud_label.add_theme_color_override(&"font_color", Color(0.85, 0.95, 1.0, 0.9))
	margin.add_child(_hud_label)
	_hud_layer.visible = false

## Compact confirmation dialog shown after a drag selection: editable
## room id ("x,y"), live size/origin info, validity status, and
## Create/Cancel buttons. Styled with PixelUi like the other panels.
func _build_panel() -> void:
	_panel_layer = CanvasLayer.new()
	_panel_layer.name = "CreationPanel"
	_panel_layer.layer = PANEL_LAYER
	add_child(_panel_layer)
	_panel = PanelContainer.new()
	PixelUi.style_panel(_panel)
	_panel.set_anchors_preset(Control.PRESET_CENTER)
	_panel.position = Vector2(-140.0, -90.0)
	_panel.custom_minimum_size = Vector2(280.0, 0.0)
	_panel_layer.add_child(_panel)
	var box := VBoxContainer.new()
	box.add_theme_constant_override(&"separation", 6)
	_panel.add_child(box)
	var title := Label.new()
	title.text = "Create Room"
	PixelUi.style_label(title, PixelUi.TEXT_COLOR, 12)
	box.add_child(title)
	_panel_info = Label.new()
	PixelUi.style_label(_panel_info, PixelUi.TEXT_COLOR, 10)
	box.add_child(_panel_info)
	var id_row := HBoxContainer.new()
	id_row.add_theme_constant_override(&"separation", 6)
	box.add_child(id_row)
	var id_caption := Label.new()
	id_caption.text = "ID (auto):"
	PixelUi.style_label(id_caption, PixelUi.TEXT_COLOR, 10)
	id_row.add_child(id_caption)
	_panel_id_edit = LineEdit.new()
	_panel_id_edit.custom_minimum_size = Vector2(120.0, 0.0)
	_panel_id_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	id_row.add_child(_panel_id_edit)
	var options := VBoxContainer.new()
	options.add_theme_constant_override(&"separation", 2)
	box.add_child(options)
	_panel_show_from_outside = CheckBox.new()
	_panel_show_from_outside.text = "Show from outside"
	_panel_show_from_outside.button_pressed = true
	options.add_child(_panel_show_from_outside)
	_panel_show_outside = CheckBox.new()
	_panel_show_outside.text = "Show outside"
	_panel_show_outside.button_pressed = true
	options.add_child(_panel_show_outside)
	_panel_status = Label.new()
	PixelUi.style_label(_panel_status, Color(1.0, 0.6, 0.4), 10)
	_panel_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(_panel_status)
	var buttons := HBoxContainer.new()
	buttons.alignment = BoxContainer.ALIGNMENT_END
	buttons.add_theme_constant_override(&"separation", 8)
	box.add_child(buttons)
	_panel_create = Button.new()
	_panel_create.text = "Create"
	PixelUi.style_button(_panel_create, true)
	_panel_create.pressed.connect(_on_panel_create)
	buttons.add_child(_panel_create)
	var cancel := Button.new()
	cancel.text = "Cancel"
	PixelUi.style_button(cancel, true)
	cancel.pressed.connect(_close_panel)
	buttons.add_child(cancel)
	_panel_layer.visible = false

func _build_room_panel() -> void:
	_room_panel_layer = CanvasLayer.new()
	_room_panel_layer.name = "RoomPanel"
	_room_panel_layer.layer = PANEL_LAYER
	add_child(_room_panel_layer)
	_room_panel = PanelContainer.new()
	PixelUi.style_panel(_room_panel)
	_room_panel.set_anchors_preset(Control.PRESET_CENTER)
	_room_panel.position = Vector2(-140.0, -80.0)
	_room_panel.custom_minimum_size = Vector2(280.0, 0.0)
	_room_panel_layer.add_child(_room_panel)
	var box := VBoxContainer.new()
	box.add_theme_constant_override(&"separation", 6)
	_room_panel.add_child(box)
	var title := Label.new()
	title.text = "Room"
	PixelUi.style_label(title, PixelUi.TEXT_COLOR, 12)
	box.add_child(title)
	_room_panel_info = Label.new()
	PixelUi.style_label(_room_panel_info, PixelUi.TEXT_COLOR, 10)
	_room_panel_info.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(_room_panel_info)
	_room_panel_contents = Label.new()
	PixelUi.style_label(_room_panel_contents, PixelUi.TEXT_COLOR, 10)
	box.add_child(_room_panel_contents)
	_room_panel_status = Label.new()
	PixelUi.style_label(_room_panel_status, Color(1.0, 0.6, 0.4), 10)
	_room_panel_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(_room_panel_status)
	var options := VBoxContainer.new()
	options.add_theme_constant_override(&"separation", 2)
	box.add_child(options)
	_room_panel_show_from_outside = CheckBox.new()
	_room_panel_show_from_outside.text = "Show from outside"
	_room_panel_show_from_outside.toggled.connect(_on_room_option_toggled)
	options.add_child(_room_panel_show_from_outside)
	_room_panel_show_outside = CheckBox.new()
	_room_panel_show_outside.text = "Show outside"
	_room_panel_show_outside.toggled.connect(_on_room_option_toggled)
	options.add_child(_room_panel_show_outside)
	var buttons := HBoxContainer.new()
	buttons.alignment = BoxContainer.ALIGNMENT_END
	buttons.add_theme_constant_override(&"separation", 8)
	box.add_child(buttons)
	_room_panel_delete = Button.new()
	_room_panel_delete.text = "Delete"
	PixelUi.style_button(_room_panel_delete, true)
	_room_panel_delete.pressed.connect(_on_room_delete)
	buttons.add_child(_room_panel_delete)
	var close := Button.new()
	close.text = "Close"
	PixelUi.style_button(close, true)
	close.pressed.connect(_close_room_panel)
	buttons.add_child(close)
	_room_panel_layer.visible = false

func _process(_delta: float) -> void:
	if not active:
		return
	_update_cursor_cell()
	# The drag corner follows the live cursor cell every frame, so the
	# preview tracks the mouse without needing motion events.
	if _dragging:
		_drag_current = cursor_cell
	# Blueprint hiding applies to GRID view only; ROOMS view keeps the
	# normal room visuals for layout inspection.
	if view_mode == ViewMode.GRID:
		_hide_world_contents()
	else:
		_restore_world_contents()
	queue_redraw()
	_update_hud()

func _unhandled_input(event: InputEvent) -> void:
	if active:
		if event is InputEventMouseButton:
			_handle_editor_mouse(event as InputEventMouseButton)
		elif event is InputEventKey:
			var key_event := event as InputEventKey
			if key_event.pressed and not key_event.echo:
				_handle_editor_key(key_event.physical_keycode)
	elif event is InputEventKey:
		var key_event := event as InputEventKey
		# F enters Creation Mode only from Build Mode; Q is the catalog
		# toggle there and Play Mode has no creation shortcut.
		if key_event.pressed and not key_event.echo \
				and key_event.physical_keycode == KEY_F and _construction_mode_active():
			enter()
			get_viewport().set_input_as_handled()

func _handle_editor_key(keycode: Key) -> void:
	# The room inspector owns the keyboard while open; Escape closes it.
	if _room_panel_is_open():
		if keycode == KEY_ESCAPE:
			_close_room_panel()
			get_viewport().set_input_as_handled()
		return
	# While the confirmation panel is open it owns the keyboard except
	# Escape, which cancels back to the selection.
	if _panel_is_open():
		if keycode == KEY_ESCAPE:
			_cancel_pending()
			get_viewport().set_input_as_handled()
		return
	match keycode:
		KEY_Q, KEY_F:
			exit()
			get_viewport().set_input_as_handled()
		KEY_ESCAPE:
			# First Escape cancels an in-progress drag; with nothing
			# pending it leaves Creation Mode for Build Mode.
			if _dragging:
				_dragging = false
			else:
				exit()
			get_viewport().set_input_as_handled()
		KEY_V:
			_dragging = false
			_cycle_view()
			get_viewport().set_input_as_handled()
		RESET_VIEW_KEY:
			_dragging = false
			_focus_overview()
			get_viewport().set_input_as_handled()
		CREATE_TOOL_KEY:
			_toggle_create_tool()
			get_viewport().set_input_as_handled()
		CONFIRM_KEY:
			# X confirms the pending selection: an in-progress drag is
			# finished first, then the confirmation panel opens.
			if tool == Tool.CREATE_ROOM and view_mode == ViewMode.GRID:
				if _dragging:
					_dragging = false
					_finish_drag()
				if _pending_rect.has_area():
					_open_panel(_pending_rect)
			get_viewport().set_input_as_handled()

func _handle_editor_mouse(mouse_button: InputEventMouseButton) -> void:
	# Right click cancels an in-progress drag or pending selection.
	if mouse_button.button_index == MOUSE_BUTTON_RIGHT:
		if _dragging or _pending_rect.has_area():
			_dragging = false
			_cancel_pending()
			get_viewport().set_input_as_handled()
		return
	# Only the left button drives room selection; middle-drag camera pan
	# and wheel zoom are handled by WorldCamera and never reach a drag.
	if mouse_button.button_index != MOUSE_BUTTON_LEFT:
		return
	if _panel_is_open() or _room_panel_is_open() or view_mode != ViewMode.GRID:
		return
	if mouse_button.pressed:
		_pressing = cursor_cell_valid
		_press_cell = cursor_cell
		if _pressing and tool == Tool.CREATE_ROOM:
			_dragging = true
			_drag_anchor = cursor_cell
			_drag_current = cursor_cell
		if _pressing:
			get_viewport().set_input_as_handled()
	elif _dragging or _pressing:
		var was_dragging := _dragging
		_dragging = false
		_pressing = false
		if was_dragging:
			if _drag_anchor == _drag_current:
				# Click without drag: inspect the room under the cursor.
				_handle_room_click()
			else:
				_finish_drag()
		elif _press_cell == cursor_cell:
			_handle_room_click()
		get_viewport().set_input_as_handled()

# ------------------------------------------------------------------
# Mode transitions
# ------------------------------------------------------------------

func enter() -> bool:
	if active:
		return true
	_room_world = get_parent() as RoomWorld
	if _room_world == null:
		_room_world = get_tree().get_first_node_in_group(&"room_worlds") as RoomWorld
	if _room_world == null or _room_world.grid == null:
		push_error("FloorEditor requires a RoomWorld with an IsometricGrid.")
		return false
	_grid = _room_world.grid
	_camera = get_viewport().get_camera_2d() as WorldCamera
	_hook_controller()
	# Show every room at full strength while editing; restored on exit.
	_saved_hide_outside = _room_world.hide_rooms_outside_neighborhood
	_saved_deemphasize = _room_world.deemphasize_neighbors
	_room_world.hide_rooms_outside_neighborhood = false
	_room_world.deemphasize_neighbors = false
	_room_world.visuals.refresh()
	# The catalog belongs to Build Mode; keep it closed while editing.
	var catalog := _catalog_panel()
	if catalog != null:
		catalog.catalog_open = false
	active = true
	_apply_view_visibility()
	if _camera != null:
		# Keep the camera where the player was looking — no forced
		# overview; B still recenters on the floor bounds on demand.
		_camera.set_editor_mode(true)
	return true

## Blueprint view (GRID mode only): hides every room visual — floor
## renderer, tiles, carpets, blocks, furniture, hover highlight,
## connection markers, labels — plus the player avatar and the build-mode
## placement ghost. Re-applied every frame so late-registered rooms are
## covered; prior visibility is restored on view switch or exit.
func _hide_world_contents() -> void:
	_restore_world_contents()
	if _room_world == null:
		return
	for room in _room_world.get_rooms():
		if room == null or not is_instance_valid(room):
			continue
		for child in room.get_children():
			var item := child as CanvasItem
			if item != null and HIDDEN_ROOM_CHILDREN.has(item.name):
				_hidden_items.append([item, item.visible])
				item.visible = false
	var player := get_tree().get_first_node_in_group(&"player") as CanvasItem
	if player != null:
		_hidden_items.append([player, player.visible])
		player.visible = false
	var world := get_tree().get_first_node_in_group(&"world") as WorldBootstrap
	var ghost: CanvasItem = null
	if world != null:
		ghost = world.get_node_or_null(^"PlacementGhost") as CanvasItem
	if ghost != null:
		_hidden_items.append([ghost, ghost.visible])
		ghost.visible = false

func _restore_world_contents() -> void:
	for pair in _hidden_items:
		var stored: Variant = pair[0]
		if is_instance_valid(stored) and stored is CanvasItem:
			(stored as CanvasItem).visible = pair[1]
	_hidden_items.clear()

func exit() -> void:
	if not active:
		return
	active = false
	tool = Tool.NONE
	_dragging = false
	_pressing = false
	_pending_rect = Rect2i()
	_close_panel()
	_close_room_panel()
	cursor_cell_valid = false
	_restore_world_contents()
	if _room_world != null:
		_room_world.hide_rooms_outside_neighborhood = _saved_hide_outside
		_room_world.deemphasize_neighbors = _saved_deemphasize
		_room_world.visuals.refresh()
	if _camera != null:
		_camera.set_editor_mode(false)
	visible = false
	if _hud_layer != null:
		_hud_layer.visible = false

## Leaving Build Mode (E toggle, toolbar Normal) ends Creation Mode.
func _on_construction_mode_changed(enabled: bool) -> void:
	if not enabled and active:
		exit()

func _hook_controller() -> void:
	if _controller_hooked:
		return
	var controller := get_tree().get_first_node_in_group(&"block_placement_controller") as BlockPlacementController
	if controller != null and not controller.construction_mode_changed.is_connected(_on_construction_mode_changed):
		controller.construction_mode_changed.connect(_on_construction_mode_changed)
		_controller_hooked = true

func _construction_mode_active() -> bool:
	var controller := get_tree().get_first_node_in_group(&"block_placement_controller") as BlockPlacementController
	return controller != null and controller.construction_mode

func _catalog_panel() -> CatalogPanel:
	var world := get_tree().get_first_node_in_group(&"world") as WorldBootstrap
	if world == null:
		return null
	return world.get_node_or_null(^"CatalogPanel") as CatalogPanel

func _cycle_view() -> void:
	view_mode = ViewMode.ROOMS if view_mode == ViewMode.GRID else ViewMode.GRID
	_close_room_panel()
	_apply_view_visibility()

func _apply_view_visibility() -> void:
	visible = active and view_mode == ViewMode.GRID
	if _hud_layer != null:
		_hud_layer.visible = active
	# GRID view needs the wide editor zooms for whole-floor overview;
	# ROOMS view uses the normal gameplay zooms so pixel art stays crisp.
	if _camera != null and _camera.is_editor_active():
		if view_mode == ViewMode.ROOMS:
			_camera.editor_use_gameplay_zoom()
		else:
			_camera.editor_use_editor_zoom()

# ------------------------------------------------------------------
# Create Room tool
# ------------------------------------------------------------------

func _toggle_create_tool() -> void:
	_dragging = false
	if tool == Tool.CREATE_ROOM:
		tool = Tool.NONE
		_cancel_pending()
		return
	tool = Tool.CREATE_ROOM
	# The selection preview is drawn by the editor canvas, which is only
	# visible in GRID view — switch so the drag is actually visible.
	if view_mode != ViewMode.GRID:
		_cycle_view()

## Current drag rect as an inclusive-cell Rect2i (origin + size), or
## an empty rect when nothing is being selected.
func _selection_rect() -> Rect2i:
	if tool != Tool.CREATE_ROOM:
		return Rect2i()
	if _dragging:
		return _rect_from_cells(_drag_anchor, _drag_current)
	if _pending_rect.has_area():
		return _pending_rect
	return Rect2i()

static func _rect_from_cells(first: Vector2i, second: Vector2i) -> Rect2i:
	var min_cell := Vector2i(mini(first.x, second.x), mini(first.y, second.y))
	var max_cell := Vector2i(maxi(first.x, second.x), maxi(first.y, second.y))
	return Rect2i(min_cell, max_cell - min_cell + Vector2i.ONE)

## Validity of a candidate rect against the live room layout.
func _selection_validity(rect: Rect2i) -> SelectionValidity:
	if rect.size.x < MIN_ROOM_DIMENSION or rect.size.y < MIN_ROOM_DIMENSION \
			or rect.size.x > MAX_ROOM_DIMENSION or rect.size.y > MAX_ROOM_DIMENSION:
		return SelectionValidity.INVALID
	if _room_world != null:
		var has_rooms := false
		for room in _room_world.get_rooms():
			if room == null:
				continue
			has_rooms = true
			if room.global_bounds().intersects(rect):
				return SelectionValidity.OVERLAP
		# Orphan rooms are not allowed: the selection must share an edge
		# with an existing room. An empty floor accepts its first room.
		if has_rooms and not _touches_existing_room(rect):
			return SelectionValidity.ISOLATED
	return SelectionValidity.VALID

## True when rect shares a full edge segment (not just a corner) with
## at least one live room's global bounds.
func _touches_existing_room(rect: Rect2i) -> bool:
	if _room_world == null:
		return false
	for room in _room_world.get_rooms():
		if room != null and _edges_touch(rect, room.global_bounds()):
			return true
	return false

## Edge adjacency: the rects must touch along a side with positive
## overlap on the perpendicular axis — corner contact does not count.
static func _edges_touch(a: Rect2i, b: Rect2i) -> bool:
	var a_end := a.position + a.size
	var b_end := b.position + b.size
	var y_overlap := mini(a_end.y, b_end.y) - maxi(a.position.y, b.position.y)
	var x_overlap := mini(a_end.x, b_end.x) - maxi(a.position.x, b.position.x)
	var side_by_side := (a_end.x == b.position.x or b_end.x == a.position.x) and y_overlap > 0
	var stacked := (a_end.y == b.position.y or b_end.y == a.position.y) and x_overlap > 0
	return side_by_side or stacked

func _finish_drag() -> void:
	var rect := _rect_from_cells(_drag_anchor, _drag_current)
	if not rect.has_area():
		return
	# Releasing the mouse only keeps the selection; X opens the panel.
	_pending_rect = rect

func _panel_is_open() -> bool:
	return _panel_layer != null and _panel_layer.visible

func _open_panel(rect: Rect2i) -> void:
	if _panel == null:
		return
	_panel_info.text = "Size: %d x %d   Origin: (%d, %d)" % [
		rect.size.x, rect.size.y, rect.position.x, rect.position.y]
	_panel_id_edit.text = _next_room_id_label()
	_panel_id_edit.editable = false
	_panel_show_from_outside.button_pressed = true
	_panel_show_outside.button_pressed = true
	_refresh_panel_status(rect)
	_panel_layer.visible = true

func _close_panel() -> void:
	if _panel_layer != null:
		_panel_layer.visible = false

## Cancels the pending selection and its confirmation panel.
func _cancel_pending() -> void:
	_pending_rect = Rect2i()
	_close_panel()

# ------------------------------------------------------------------
# Room inspector panel (click a room in GRID view)
# ------------------------------------------------------------------

func _room_panel_is_open() -> bool:
	return _room_panel_layer != null and _room_panel_layer.visible

func _close_room_panel() -> void:
	if _room_panel_layer != null:
		_room_panel_layer.visible = false
	_room_panel_room = null

## LMB press+release on the same cell inspects the room there.
func _handle_room_click() -> void:
	_cancel_pending()
	if _room_world == null:
		return
	var room := _room_world.get_room_at_world_cell(cursor_cell)
	if room != null:
		_open_room_panel(room)

func _open_room_panel(room: Room) -> void:
	if room == null or _room_panel == null:
		return
	_room_panel_room = room
	var bounds := room.global_bounds()
	_room_panel_info.text = "ID %s   Origin (%d, %d)   Size %dx%d   Options: %s/%s" % [
		_id_label(room.room_coordinates), bounds.position.x, bounds.position.y,
		bounds.size.x, bounds.size.y,
		"outside" if room.show_from_outside else "hidden",
		"reveals" if room.show_outside else "conceals"]
	var counts: Dictionary = room.placed_content_counts()
	var parts: Array[String] = []
	if int(counts["blocks"]) > 0:
		parts.append("%d block(s)/furniture" % counts["blocks"])
	if int(counts["carpets"]) > 0:
		parts.append("%d carpet(s)" % counts["carpets"])
	if int(counts["tiles"]) > 0:
		parts.append("%d tile override(s)" % counts["tiles"])
	_room_panel_contents.text = "Contents: " + ("empty" if parts.is_empty() else ", ".join(parts))
	_room_panel_status.text = ""
	var floor_manager := _floor_manager()
	var verdict := {"allowed": false, "reason": "No active floor."}
	if floor_manager != null:
		verdict = floor_manager.can_delete_room(room.room_coordinates)
	_room_panel_delete.disabled = not bool(verdict.get("allowed", false))
	if not bool(verdict.get("allowed", false)):
		_room_panel_status.text = "Cannot delete: %s" % str(verdict.get("reason", ""))
	# Reflect the room's current options; setting button_pressed does
	# not emit toggled, so this never retriggers the handler.
	_room_panel_show_from_outside.set_pressed_no_signal(room.show_from_outside)
	_room_panel_show_outside.set_pressed_no_signal(room.show_outside)
	_room_panel_layer.visible = true

## Checkbox toggle on an existing room: applies live (with the usual
## show/hide animation), mirrors the flags onto the floor spec, and
## persists layout.json immediately.
func _on_room_option_toggled(_pressed: bool = false) -> void:
	var room := _room_panel_room
	if room == null or not is_instance_valid(room):
		return
	room.show_from_outside = _room_panel_show_from_outside.button_pressed
	room.show_outside = _room_panel_show_outside.button_pressed
	var floor_manager := _floor_manager()
	if floor_manager != null and floor_manager.active_floor != null:
		var spec := floor_manager.active_floor.find_room_spec(room.room_coordinates)
		if spec != null:
			spec.show_from_outside = room.show_from_outside
			spec.show_outside = room.show_outside
			floor_manager.save_floor_layout()
	if _room_world != null:
		_room_world.visuals.begin_transition()

func _on_room_delete() -> void:
	var floor_manager := _floor_manager()
	if floor_manager == null or _room_panel_room == null \
			or not is_instance_valid(_room_panel_room):
		_close_room_panel()
		return
	var room_id: Vector2i = _room_panel_room.room_coordinates
	if floor_manager.remove_room_from_active_floor(room_id):
		_set_notice("Room %s deleted." % _id_label(room_id))
		_room_panel_room = null
		_close_room_panel()
	else:
		var verdict := floor_manager.can_delete_room(room_id)
		_room_panel_status.text = "Delete failed: %s" % str(verdict.get("reason", "unknown"))

func _refresh_panel_status(rect: Rect2i) -> void:
	if _panel_status == null:
		return
	match _selection_validity(rect):
		SelectionValidity.VALID:
			_panel_status.text = "Area is free."
			_panel_create.disabled = false
		SelectionValidity.OVERLAP:
			_panel_status.text = "Overlaps an existing room."
			_panel_create.disabled = true
		SelectionValidity.ISOLATED:
			_panel_status.text = "Must share an edge with an existing room."
			_panel_create.disabled = true
		SelectionValidity.INVALID:
			_panel_status.text = "Invalid size: rooms need at least %dx%d and at most %d per axis." % [
				MIN_ROOM_DIMENSION, MIN_ROOM_DIMENSION, MAX_ROOM_DIMENSION]
			_panel_create.disabled = true

func _on_panel_create() -> void:
	if not _pending_rect.has_area():
		_close_panel()
		return
	var parsed: Variant = _parse_room_id(_panel_id_edit.text)
	if parsed == null:
		_panel_status.text = "Room ID must be two integers, e.g. 4,7"
		return
	var room_id: Vector2i = parsed
	if _room_id_in_use(room_id):
		_panel_status.text = "Room ID %s is already used." % _id_label(room_id)
		return
	var spec := FloorRoomSpec.new()
	spec.room_id = room_id
	spec.global_origin = _pending_rect.position
	spec.size = _pending_rect.size
	spec.show_from_outside = _panel_show_from_outside.button_pressed
	spec.show_outside = _panel_show_outside.button_pressed
	var floor_manager := _floor_manager()
	if floor_manager == null:
		_panel_status.text = "No active floor — room creation requires one."
		return
	var room := floor_manager.add_room_to_active_floor(spec)
	if room == null:
		_panel_status.text = "Creation rejected (overlap or invalid room)."
		return
	_set_notice("Room created: %s at (%d, %d) %dx%d" % [
		_id_label(room_id), spec.global_origin.x, spec.global_origin.y,
		spec.size.x, spec.size.y])
	_pending_rect = Rect2i()
	_close_panel()
	# Recenter on the new room so the player sees the result.
	if _camera != null:
		var center := _grid.grid_to_screen_position(
			Vector2(spec.global_origin) + Vector2(spec.size) * 0.5, 0.0)
		_camera.focus_on(center)

func _floor_manager() -> FloorManager:
	var world := get_tree().get_first_node_in_group(&"world") as WorldBootstrap
	if world != null:
		return world.floor_manager
	return null

func _room_id_in_use(room_id: Vector2i) -> bool:
	if _room_world != null and _room_world.has_room(room_id):
		return true
	var floor_manager := _floor_manager()
	if floor_manager != null and floor_manager.active_floor != null:
		for spec in floor_manager.active_floor.rooms:
			if spec != null and spec.room_id == room_id:
				return true
	return false

## First unused room id scanning right along row 0 — deterministic and
## collision-free because used ids are checked against both the live
## registry and the floor's spec list.
func _next_room_id() -> Vector2i:
	var candidate := Vector2i.ZERO
	while _room_id_in_use(candidate):
		candidate.x += 1
	return candidate

func _next_room_id_label() -> String:
	return _id_label(_next_room_id())

static func _id_label(room_id: Vector2i) -> String:
	return "%d,%d" % [room_id.x, room_id.y]

func _parse_room_id(text: String) -> Variant:
	var parts := text.split(",")
	if parts.size() != 2:
		return null
	var xs := parts[0].strip_edges()
	var ys := parts[1].strip_edges()
	if not xs.is_valid_int() or not ys.is_valid_int():
		return null
	return Vector2i(xs.to_int(), ys.to_int())

func _set_notice(text: String) -> void:
	_notice = text
	_notice_until_ms = Time.get_ticks_msec() + 4000

# ------------------------------------------------------------------
# Camera / cursor
# ------------------------------------------------------------------

## World-cell under the mouse, or Vector2i.ZERO when unavailable.
func cursor_cell_position() -> Vector2i:
	return cursor_cell

func _update_cursor_cell() -> void:
	if _grid == null:
		cursor_cell_valid = false
		return
	if cursor_override_valid:
		cursor_cell = cursor_override
		cursor_cell_valid = true
		return
	cursor_cell = cursor_cell_for_world_position(get_global_mouse_position())
	cursor_cell_valid = true

## Global world-cell for an arbitrary world position. Split out from
## _update_cursor_cell so the conversion can be exercised without a
## real mouse (headless tests).
func cursor_cell_for_world_position(world_position: Vector2) -> Vector2i:
	if _grid == null:
		return Vector2i.ZERO
	return _grid.screen_to_grid(world_position)

## Centers the camera on the floor's room bounds (or the grid origin
## when the floor has no rooms yet) at the widest overview zoom.
func _focus_overview() -> void:
	if _camera == null:
		return
	var center := Vector2.ZERO
	if _room_world != null:
		var bounds := _room_world.get_world_cell_bounds()
		if bounds.has_area():
			var mid := Vector2(bounds.position) + Vector2(bounds.size) * 0.5
			center = _grid.grid_to_screen_position(mid, 0.0)
		else:
			center = _grid.grid_to_screen_position(Vector2.ZERO, 0.0)
	_camera.focus_on(center, 0)

func _update_hud() -> void:
	if _hud_label == null:
		return
	var lines: Array[String] = [
		"CREATION MODE  [V] %s view  [Q/F/Esc] build  [B] overview  [MMB-drag/WASD] pan" % (
			"grid" if view_mode == ViewMode.GRID else "rooms"),
	]
	if tool == Tool.CREATE_ROOM:
		lines.append("[C] select tool  LMB drag: new room  [X] confirm  RMB/Esc: cancel")
		var rect := _selection_rect()
		if rect.has_area():
			lines.append("Selection: %dx%d at (%d, %d)" % [
				rect.size.x, rect.size.y, rect.position.x, rect.position.y])
			if not _dragging and not _panel_is_open():
				lines.append("Press [X] to place it, RMB/Esc to cancel")
	else:
		lines.append("[C] create room tool")
	if cursor_cell_valid:
		lines.append("Cell: (%d, %d)" % [cursor_cell.x, cursor_cell.y])
	if _notice != "" and Time.get_ticks_msec() < _notice_until_ms:
		lines.append(_notice)
	if _camera != null:
		lines.append("Zoom: %.2f" % _camera.zoom.x)
	_hud_label.text = "\n".join(lines)

# ------------------------------------------------------------------
# Grid rendering (GRID view)
# ------------------------------------------------------------------

func _draw() -> void:
	if _grid == null or _room_world == null:
		return
	var cell_range := _visible_cell_range()
	if cell_range.size.x <= 0 or cell_range.size.y <= 0:
		return
	_draw_grid_lines(cell_range)
	_draw_room_bounds()
	_draw_selection_preview()
	_draw_cursor_cell()

## World-cell range covering the camera's visible rect, padded by one
## cell so edges stay covered while panning.
func _visible_cell_range() -> Rect2i:
	var camera := get_viewport().get_camera_2d()
	var view_size := get_viewport().get_visible_rect().size
	var center := Vector2.ZERO
	var zoom := 1.0
	if camera != null:
		center = camera.get_screen_center_position()
		zoom = maxf(camera.zoom.x, 0.001)
	var half := view_size * 0.5 / zoom
	var world_rect := Rect2(center - half, half * 2.0)
	var min_cell := Vector2i(MAX_DRAW_AXIS, MAX_DRAW_AXIS)
	var max_cell := Vector2i(-MAX_DRAW_AXIS, -MAX_DRAW_AXIS)
	for corner in [world_rect.position, world_rect.position + Vector2(world_rect.size.x, 0.0),
			world_rect.end, world_rect.position + Vector2(0.0, world_rect.size.y)]:
		var cell := _grid.screen_to_grid(corner)
		min_cell = Vector2i(mini(min_cell.x, cell.x), mini(min_cell.y, cell.y))
		max_cell = Vector2i(maxi(max_cell.x, cell.x), maxi(max_cell.y, cell.y))
	min_cell -= Vector2i.ONE
	max_cell += Vector2i.ONE
	# Clamp to a sane draw budget; the grid is infinite but _draw is not.
	if max_cell.x - min_cell.x > MAX_DRAW_AXIS or max_cell.y - min_cell.y > MAX_DRAW_AXIS:
		var mid := Vector2i(
			int((min_cell.x + max_cell.x) * 0.5),
			int((min_cell.y + max_cell.y) * 0.5))
		min_cell = mid - Vector2i(MAX_DRAW_AXIS * 0.5, MAX_DRAW_AXIS * 0.5)
		max_cell = mid + Vector2i(MAX_DRAW_AXIS * 0.5, MAX_DRAW_AXIS * 0.5)
	return Rect2i(min_cell, max_cell - min_cell + Vector2i.ONE)

## Cell diamonds are centered on integer anchors; their edges lie on
## half-integer grid lines. Lines are drawn at u/v = k + 0.5 so they
## align with the cells players actually see and hover.
func _draw_grid_lines(cell_range: Rect2i) -> void:
	var line_color := Color(1.0, 1.0, 1.0, 0.07)
	var y0 := float(cell_range.position.y) - 2.0
	var y1 := float(cell_range.end.y) + 2.0
	for k in range(cell_range.position.x - 1, cell_range.end.x + 1):
		var u := float(k) + 0.5
		var a := _grid.grid_to_screen_position(Vector2(u, y0), 0.0)
		var b := _grid.grid_to_screen_position(Vector2(u, y1), 0.0)
		draw_line(a, b, line_color, 1.0)
	var x0 := float(cell_range.position.x) - 2.0
	var x1 := float(cell_range.end.x) + 2.0
	for k in range(cell_range.position.y - 1, cell_range.end.y + 1):
		var v := float(k) + 0.5
		var a := _grid.grid_to_screen_position(Vector2(x0, v), 0.0)
		var b := _grid.grid_to_screen_position(Vector2(x1, v), 0.0)
		draw_line(a, b, line_color, 1.0)

## Filled + outlined iso polygon for each registered room's global
## bounds, plus its room id at the centroid.
func _draw_room_bounds() -> void:
	var fill := Color(0.35, 0.75, 1.0, 0.10)
	var border := Color(0.45, 0.85, 1.0, 0.6)
	var font := ThemeDB.fallback_font
	for room in _room_world.get_rooms():
		if room == null:
			continue
		var bounds := room.global_bounds()
		# Half-integer corners: the outline hugs the outer edges of the
		# boundary cells' diamonds, not their centers.
		var x0 := float(bounds.position.x) - 0.5
		var y0 := float(bounds.position.y) - 0.5
		var x1 := float(bounds.end.x) - 0.5
		var y1 := float(bounds.end.y) - 0.5
		var points := PackedVector2Array()
		for corner in [Vector2(x0, y0), Vector2(x1, y0), Vector2(x1, y1), Vector2(x0, y1)]:
			points.append(_grid.grid_to_screen_position(corner, 0.0))
		draw_colored_polygon(points, fill)
		draw_polyline(points + PackedVector2Array([points[0]]), border, 1.5)
		if font != null:
			var center := _grid.grid_to_screen_position(
				Vector2(bounds.position) + Vector2(bounds.size) * 0.5, 0.0)
			draw_string(font, center + Vector2(-16.0, 4.0), "(%d, %d)" % [
				room.room_coordinates.x, room.room_coordinates.y],
				HORIZONTAL_ALIGNMENT_LEFT, -1, 11, Color(0.8, 0.95, 1.0, 0.85))

func _draw_cursor_cell() -> void:
	if not cursor_cell_valid:
		return
	var occupied := _room_world.get_room_at_world_cell(cursor_cell) != null
	var color := Color(1.0, 0.55, 0.35, 0.35) if occupied else Color(0.4, 1.0, 0.5, 0.30)
	# Diamond centered on the cell anchor (half-integer corners) — same
	# shape the room floor/tile rendering uses, so hover matches visuals.
	var x := float(cursor_cell.x)
	var y := float(cursor_cell.y)
	var points := PackedVector2Array()
	for corner in [Vector2(x - 0.5, y - 0.5), Vector2(x + 0.5, y - 0.5),
			Vector2(x + 0.5, y + 0.5), Vector2(x - 0.5, y + 0.5)]:
		points.append(_grid.grid_to_screen_position(corner, 0.0))
	draw_colored_polygon(points, color)
	draw_polyline(points + PackedVector2Array([points[0]]),
		color.lightened(0.3), 1.5)

## Live drag preview plus the finished selection awaiting confirmation.
## Same half-integer corner convention as room bounds so the preview
## aligns exactly with the room that will be created.
func _draw_selection_preview() -> void:
	var rect := _selection_rect()
	if not rect.has_area():
		return
	var validity := _selection_validity(rect)
	var fill: Color
	var border: Color
	match validity:
		SelectionValidity.VALID:
			fill = Color(0.35, 1.0, 0.55, 0.18)
			border = Color(0.45, 1.0, 0.6, 0.9)
		SelectionValidity.OVERLAP:
			fill = Color(1.0, 0.6, 0.25, 0.20)
			border = Color(1.0, 0.65, 0.3, 0.9)
		SelectionValidity.ISOLATED:
			fill = Color(1.0, 0.85, 0.25, 0.20)
			border = Color(1.0, 0.9, 0.35, 0.9)
		SelectionValidity.INVALID:
			fill = Color(1.0, 0.3, 0.3, 0.20)
			border = Color(1.0, 0.35, 0.35, 0.9)
	var x0 := float(rect.position.x) - 0.5
	var y0 := float(rect.position.y) - 0.5
	var x1 := float(rect.end.x) - 0.5
	var y1 := float(rect.end.y) - 0.5
	var points := PackedVector2Array()
	for corner in [Vector2(x0, y0), Vector2(x1, y0), Vector2(x1, y1), Vector2(x0, y1)]:
		points.append(_grid.grid_to_screen_position(corner, 0.0))
	draw_colored_polygon(points, fill)
	var width := 2.5 if _pending_rect == rect and not _dragging else 1.5
	draw_polyline(points + PackedVector2Array([points[0]]), border, width)
	var font := ThemeDB.fallback_font
	if font != null:
		var center := _grid.grid_to_screen_position(
			Vector2(rect.position) + Vector2(rect.size) * 0.5, 0.0)
		var status := "valid" if validity == SelectionValidity.VALID else \
			("overlap" if validity == SelectionValidity.OVERLAP else \
			("isolated" if validity == SelectionValidity.ISOLATED else "invalid"))
		draw_string(font, center + Vector2(-30.0, 4.0),
			"%dx%d  (%d, %d)  %s" % [rect.size.x, rect.size.y,
				rect.position.x, rect.position.y, status],
			HORIZONTAL_ALIGNMENT_LEFT, -1, 11, border)
