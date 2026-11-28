class_name DebugChat
extends CanvasLayer

## Minecraft-style chat/command line: Enter opens a single-line
## input above the bottom-left corner; "/" commands run immediately,
## anything else is echoed back as an unknown command. Normal Mode
## only — Build Mode, Creation Mode, FloorPanel, combat, transitions,
## and the other panels all own the keyboard while active.
##
## While open it blocks world interaction via DebugChat.any_open()
## (checked alongside AvatarPanel/DisciplinePanel).

signal chat_toggled(is_open: bool)

const TOGGLE_KEY := KEY_ENTER
const ALT_TOGGLE_KEY := KEY_KP_ENTER
const LAYER_INDEX := 70
const INPUT_WIDTH := 320.0

var chat_open := false:
	set(value):
		if chat_open == value:
			return
		chat_open = value
		if _root != null:
			_root.visible = value
		if value:
			_history.text = ""
			_input.text = ""
			_input.grab_focus()
		else:
			_input.release_focus()
		chat_toggled.emit(value)

var _root: Control
var _history: Label
var _input: LineEdit
var _controller: BlockPlacementController

func _ready() -> void:
	layer = LAYER_INDEX
	add_to_group(&"debug_chats")
	_build_ui()
	_root.visible = chat_open

func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventKey):
		return
	var key_event := event as InputEventKey
	if not key_event.pressed or key_event.echo:
		return
	if chat_open:
		# The LineEdit consumes printable keys itself; only Escape
		# reaches unhandled input while typing.
		if key_event.keycode == KEY_ESCAPE:
			close()
			get_viewport().set_input_as_handled()
		return
	if (key_event.keycode == TOGGLE_KEY or key_event.keycode == ALT_TOGGLE_KEY) \
			and _can_open():
		open()
		get_viewport().set_input_as_handled()

## True when nothing else owns the keyboard — same Normal-Mode rule
## as AvatarPanel/DisciplinePanel.
func _can_open() -> bool:
	if FloorEditor.any_active(get_tree()) or FloorPanel.any_open(get_tree()) \
			or TransitionOverlay.any_active(get_tree()) \
			or CombatManager.any_active(get_tree()) \
			or AvatarPanel.any_open(get_tree()) \
			or DisciplinePanel.any_open(get_tree()):
		return false
	if _controller == null:
		_controller = get_tree().get_first_node_in_group(&"block_placement_controller") as BlockPlacementController
	return _controller == null or not _controller.construction_mode

func open() -> void:
	chat_open = true

func close() -> void:
	chat_open = false

func toggle() -> void:
	chat_open = not chat_open

## True when any DebugChat in the tree has its input open.
static func any_open(tree: SceneTree) -> bool:
	if tree == null:
		return false
	for node in tree.get_nodes_in_group(&"debug_chats"):
		var chat := node as DebugChat
		if chat != null and chat.chat_open:
			return true
	return false

# ------------------------------------------------------------------
# Commands
# ------------------------------------------------------------------

func _on_text_submitted(text: String) -> void:
	var response := _run_command(text.strip_edges())
	_history.text = response
	_history.add_theme_color_override(&"font_color",
		Color(1.0, 0.55, 0.5) if response.begins_with("!") else PixelUi.TEXT_DIM)
	close()

func _run_command(text: String) -> String:
	if text.is_empty():
		return ""
	var parts := text.split(" ", false)
	var command := parts[0].to_lower()
	match command:
		"/help":
			return "Commands: /setlevel <1-5>, /help"
		"/setlevel":
			return _cmd_setlevel(parts)
		_:
			return "!Unknown command: %s" % text

func _cmd_setlevel(parts: Array) -> String:
	var progression := CharacterProgression.find(get_tree())
	if progression == null:
		return "!No character progression found."
	if parts.size() < 2 or not parts[1].is_valid_int():
		return "!Usage: /setlevel <level>"
	var requested := int(parts[1])
	progression.set_level(requested)
	return "Mutant Cursed level set to %d." % progression.level

# ------------------------------------------------------------------
# UI (code-built, matching the other panels)
# ------------------------------------------------------------------

func _build_ui() -> void:
	_root = Control.new()
	_root.name = "DebugChatRoot"
	_root.anchor_left = 0.0
	_root.anchor_right = 0.0
	_root.anchor_top = 1.0
	_root.anchor_bottom = 1.0
	_root.offset_left = 8.0
	_root.offset_top = -80.0
	_root.offset_right = 8.0 + INPUT_WIDTH
	_root.offset_bottom = -48.0
	add_child(_root)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 2)
	_root.add_child(box)

	_history = Label.new()
	_history.custom_minimum_size = Vector2(0.0, 14.0)
	PixelUi.style_label(_history, PixelUi.TEXT_DIM, 9)
	_history.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(_history)

	_input = LineEdit.new()
	_input.custom_minimum_size = Vector2(INPUT_WIDTH, 16.0)
	_input.placeholder_text = "Enter command..."
	_input.add_theme_color_override(&"font_color", PixelUi.TEXT_COLOR)
	_input.add_theme_color_override(&"font_placeholder_color", PixelUi.TEXT_DIM)
	_input.add_theme_stylebox_override(&"normal",
		PixelUi.make_panel_stylebox(Color(0.07, 0.07, 0.11, 0.9),
			Color(0.4, 0.38, 0.5, 0.9)))
	_input.add_theme_stylebox_override(&"focus",
		PixelUi.make_panel_stylebox(Color(0.09, 0.08, 0.15, 0.95),
			Color(0.85, 0.72, 0.45, 0.9)))
	PixelUi.nearest(_input)
	_input.text_submitted.connect(_on_text_submitted)
	box.add_child(_input)
