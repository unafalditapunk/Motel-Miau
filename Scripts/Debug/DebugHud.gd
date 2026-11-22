class_name DebugHud
extends CanvasLayer

@export var player: Player
@export var grid: IsometricGrid
@export var toggle_key := KEY_F3

const LAYER_INDEX := 128
const UPDATE_INTERVAL := 0.05

var enabled := false

var _root: Control
var _label: Label
var _elapsed := 0.0

func _ready() -> void:
	layer = LAYER_INDEX
	_root = Control.new()
	_root.name = "DebugRoot"
	_root.set_anchors_preset(Control.PRESET_TOP_LEFT)
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.visible = false
	add_child(_root)

	var panel := PanelContainer.new()
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.0, 0.0, 0.0, 0.55)
	style.content_margin_left = 8.0
	style.content_margin_right = 8.0
	style.content_margin_top = 6.0
	style.content_margin_bottom = 6.0
	panel.add_theme_stylebox_override(&"panel", style)
	_root.add_child(panel)

	_label = Label.new()
	_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_label.add_theme_font_size_override(&"font_size", 14)
	_label.add_theme_color_override(&"font_color", Color(0.9, 1.0, 0.9, 0.95))
	_label.add_theme_constant_override(&"line_spacing", 2)
	panel.add_child(_label)

func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventKey):
		return
	var key_event := event as InputEventKey
	if not key_event.pressed or key_event.echo:
		return
	if key_event.physical_keycode == toggle_key:
		enabled = not enabled
		_root.visible = enabled
		if enabled:
			_refresh()
		get_viewport().set_input_as_handled()

func _process(delta: float) -> void:
	if not enabled:
		return
	_elapsed += delta
	if _elapsed >= UPDATE_INTERVAL:
		_elapsed = 0.0
		_refresh()

func _refresh() -> void:
	if _label == null:
		return
	_label.text = _build_text()

func _build_text() -> String:
	var lines: Array[String] = ["Miau Motel Debug  [F3 to hide]"]
	if player == null:
		lines.append("Player: <none>")
		return "\n".join(lines)

	var cell := player.grid_position
	var world_pos := player.global_position
	var cell_screen := Vector2.ZERO
	var world_cell := Vector2i.ZERO
	if grid != null:
		var anchor_cell := cell
		if player.room != null:
			anchor_cell = player.room.world_cell_coordinates(cell)
		world_cell = anchor_cell
		cell_screen = grid.grid_to_screen(anchor_cell, player.elevation)
	lines.append("Grid cell:   (%d, %d)   World cell: (%d, %d)" % [cell.x, cell.y, world_cell.x, world_cell.y])
	var room_world := _room_world()
	if player.room != null:
		lines.append("Room:        (%d, %d)  size %s  origin %s" % [
			player.room.room_coordinates.x, player.room.room_coordinates.y,
			str(player.room.size), str(player.room.cell_origin)])
	else:
		lines.append("Room:        <none>")
	if room_world != null:
		var room_id: Vector2i = player.room.room_coordinates if player.room != null else room_world.primary_room_coordinates
		var linked := room_world.get_connected_room_ids(room_id)
		var linked_text := "none"
		if not linked.is_empty():
			var parts: Array[String] = []
			for id in linked:
				parts.append("(%d,%d)" % [id.x, id.y])
			linked_text = ", ".join(parts)
		var visible_rooms := room_world.get_visible_room_coordinates()
		var de_emphasized := 0
		for id in visible_rooms:
			if id != room_world.primary_room_coordinates:
				de_emphasized += 1
		lines.append("Connections: %d from room  Visible rooms: %d  De-emphasized: %d" % [linked.size(), visible_rooms.size(), de_emphasized])
		lines.append("Linked rooms: %s" % linked_text)
	lines.append("World pos:   (%.2f, %.2f)" % [world_pos.x, world_pos.y])
	lines.append(_floor_line())
	var creation := _creation_line()
	if not creation.is_empty():
		lines.append(creation)
	lines.append("Cell anchor: (%.2f, %.2f)" % [cell_screen.x, cell_screen.y])
	lines.append("Facing:      %s   Buffered: %s" % [str(player.facing_direction), str(player._buffered_direction)])
	var next := player.next_move_target()
	var step := next - cell
	var transition := player.evaluate_transition(step)
	if transition.get("attempted", false):
		var dest: Vector2i = transition.get("room_coordinates", Vector2i.ZERO)
		var status: String = "ok -> local %s" % str(transition.get("local_cell")) if transition.get("valid", false) else "blocked: %s" % str(transition.get("reason"))
		lines.append("Transition %s -> room (%d, %d): %s" % [str(step), dest.x, dest.y, status])
	var state := "Idle"
	if player._is_moving:
		var t := clampf(player._move_elapsed / maxf(player.move_duration, 0.0001), 0.0, 1.0)
		state = "Moving (%.0f%%)" % (t * 100.0)
	lines.append("State:       %s" % state)
	lines.append("Elevation:   %.3f" % player.elevation)

	var camera := get_viewport().get_camera_2d() as WorldCamera
	if camera != null:
		lines.append("Camera:      zoom %.2f  pos (%.1f, %.1f)" % [camera.zoom.x, camera.global_position.x, camera.global_position.y])
		if grid != null:
			var mouse_world := grid.screen_to_grid(camera.get_world_mouse_position())
			var mouse_cell := mouse_world
			if player.room != null:
				mouse_cell = player.room.local_cell_coordinates(mouse_world)
			lines.append("Mouse cell:  (%d, %d)" % [mouse_cell.x, mouse_cell.y])
	lines.append("FPS:         %d" % Engine.get_frames_per_second())
	return "\n".join(lines)

func _room_world() -> RoomWorld:
	return get_tree().get_first_node_in_group(&"room_worlds") as RoomWorld

func _floor_manager() -> FloorManager:
	var world := get_tree().get_first_node_in_group(&"world") as WorldBootstrap
	return world.floor_manager if world != null else null

func _floor_line() -> String:
	var manager := _floor_manager()
	if manager == null or manager.active_floor == null:
		return "Floor:       <none> (legacy world)"
	var floor_def := manager.active_floor
	var dirty := "dirty" if manager.is_floor_dirty() else "clean"
	var saved := "saved" if manager.has_floor_save(floor_def.floor_id) else "unsaved"
	return "Floor:       %s [%s]  rooms %d  %s  %s" % [
		floor_def.display_name, floor_def.floor_id, floor_def.rooms.size(), dirty, saved]

## Creation Mode line: mode, view, cursor global cell, camera zoom.
## Empty when the editor is inactive so normal debug output is unchanged.
func _creation_line() -> String:
	var editor := _floor_editor()
	if editor == null or not editor.active:
		return ""
	var view := "grid" if editor.view_mode == FloorEditor.ViewMode.GRID else "rooms"
	var text := "Mode:        CREATION (%s view)" % view
	if editor.cursor_cell_valid:
		text += "  cursor (%d, %d)" % [editor.cursor_cell.x, editor.cursor_cell.y]
	return text

func _floor_editor() -> FloorEditor:
	return get_tree().get_first_node_in_group(&"floor_editor") as FloorEditor
