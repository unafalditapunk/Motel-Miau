extends SceneTree

## DebugChat smoke test: Enter toggles the chat line in Normal Mode,
## "/setlevel" drives CharacterProgression (with clamping and error
## paths), unknown commands echo back, Escape closes, and
## DebugChat.any_open reports correctly.
##
## Saves redirect to a wiped user:// smoke dir — real saves untouched.

const SMOKE_DIR := "user://smoke_debug_chat"

var _chat: DebugChat
var _progression: CharacterProgression
var _frames := 0
var _failures: Array[String] = []
var _saved_floor_root := ""
var _saved_save_dir := ""

func _initialize() -> void:
	_saved_floor_root = FloorSaveSystem.save_root
	_saved_save_dir = RoomSaveSystem.save_dir
	FloorSaveSystem.save_root = SMOKE_DIR.path_join("floors")
	RoomSaveSystem.save_dir = SMOKE_DIR.path_join("saves")
	_wipe_dir(SMOKE_DIR)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(SMOKE_DIR))
	_progression = CharacterProgression.new()
	_progression.name = "CharacterProgression"
	root.add_child(_progression)
	_chat = DebugChat.new()
	_chat.name = "DebugChat"
	root.add_child(_chat)

func _wipe_dir(path: String) -> void:
	var abs := ProjectSettings.globalize_path(path)
	if not DirAccess.dir_exists_absolute(abs):
		return
	var dir := DirAccess.open(abs)
	if dir == null:
		return
	dir.list_dir_begin()
	var entry := dir.get_next()
	while entry != "":
		var child := abs.path_join(entry)
		if dir.current_is_dir():
			_wipe_dir(child)
		else:
			DirAccess.remove_absolute(child)
		entry = dir.get_next()
	dir.list_dir_end()
	DirAccess.remove_absolute(abs)

func _process(_delta: float) -> bool:
	_frames += 1
	if _frames < 3:
		return false
	_run_checks()
	FloorSaveSystem.save_root = _saved_floor_root
	RoomSaveSystem.save_dir = _saved_save_dir
	_report()
	quit()
	return true

func _expect(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)

func _key(keycode: Key) -> InputEventKey:
	var event := InputEventKey.new()
	event.keycode = keycode
	event.physical_keycode = keycode
	event.pressed = true
	event.echo = false
	return event

func _run_checks() -> void:
	_test_toggle()
	_test_setlevel()
	_test_errors()
	_test_persistence()

func _test_toggle() -> void:
	_expect(not _chat.chat_open, "chat should start closed")
	_expect(not DebugChat.any_open(self), "any_open should be false")
	_chat._unhandled_input(_key(KEY_ENTER))
	_expect(_chat.chat_open, "Enter should open the chat")
	_expect(DebugChat.any_open(self), "any_open should be true")
	# A second Enter while open is consumed by the LineEdit path —
	# simulate Escape instead, which reaches unhandled input.
	_chat._unhandled_input(_key(KEY_ESCAPE))
	_expect(not _chat.chat_open, "Escape should close the chat")
	_expect(not DebugChat.any_open(self), "any_open should clear")
	# Numpad Enter opens too.
	_chat._unhandled_input(_key(KEY_KP_ENTER))
	_expect(_chat.chat_open, "numpad Enter should open the chat")
	_chat.close()

func _test_setlevel() -> void:
	_progression.set_level(1)
	_chat.open()
	_chat._on_text_submitted("/setlevel 5")
	_expect(_progression.level == 5, "setlevel 5 should set level 5")
	_expect(_progression.is_equipped(&"little_sacrifice"),
		"level 5 should unlock and equip Little Sacrifice")
	_expect(not _chat.chat_open, "submit should close the chat")
	_expect(_chat._history.text.contains("level set to 5"),
		"history should confirm: '%s'" % _chat._history.text)
	# Level down works too (drops locked equips).
	_chat.open()
	_chat._on_text_submitted("/setlevel 2")
	_expect(_progression.level == 2, "setlevel 2 should set level 2")
	_expect(not _progression.is_equipped(&"drowsiness"),
		"level-down must drop locked equips")

func _test_errors() -> void:
	_chat.open()
	_chat._on_text_submitted("/bogus")
	_expect(_chat._history.text.begins_with("!"),
		"unknown command should error, got '%s'" % _chat._history.text)
	_chat.open()
	_chat._on_text_submitted("/setlevel")
	_expect(_chat._history.text.begins_with("!Usage"),
		"missing arg should show usage")
	_chat.open()
	_chat._on_text_submitted("/setlevel abc")
	_expect(_chat._history.text.begins_with("!Usage"),
		"non-int arg should show usage")
	_chat.open()
	_chat._on_text_submitted("hello")
	_expect(_chat._history.text.begins_with("!Unknown"),
		"plain text should be an unknown command")
	_chat.open()
	_chat._on_text_submitted("/help")
	_expect(_chat._history.text.contains("/setlevel"),
		"help should list commands")
	# Out-of-range levels clamp at the discipline max.
	_chat.open()
	_chat._on_text_submitted("/setlevel 99")
	_expect(_progression.level == 5, "level should clamp to max 5")

func _test_persistence() -> void:
	# set_level flushed through _changed(); a fresh node must read
	# the same level back from the smoke save dir.
	var prog2 := CharacterProgression.new()
	root.add_child(prog2)
	_expect(prog2.level == _progression.level,
		"level should persist across nodes, got %d" % prog2.level)
	prog2.queue_free()

func _report() -> void:
	if _failures.is_empty():
		print("DEBUG_CHAT_SMOKE: OK")
	else:
		for failure in _failures:
			push_error("DEBUG_CHAT_SMOKE FAIL: " + failure)
		print("DEBUG_CHAT_SMOKE: FAILED (%d)" % _failures.size())
