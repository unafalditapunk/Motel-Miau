extends SceneTree

## Smoke test for the Phase P3 TransitionOverlay slide lifecycle.
## Drives the phase machine with tiny slide durations: the animated
## single-player path (slide-out -> deferred switch -> slide-in),
## failure recovery, the synchronous no-rooms fast path, the
## multiplayer transition_requested/transition_result lifecycle,
## WAITING refusal of play_transition, and per-instance isolation.

const GRID_PATH := "res://Resources/IsometricGrid/TestGrid.tres"
const TILE_CATALOG_PATH := "res://Resources/TileCatalog.tres"
const BLOCK_CATALOG_PATH := "res://Resources/BlockCatalog.tres"
const FURNITURE_CATALOG_PATH := "res://Resources/FurnitureCatalog.tres"
const CARPET_CATALOG_PATH := "res://Resources/CarpetCatalog.tres"
const BLOCK_SCENE_PATH := "res://Scenes/Objects/Block.tscn"
const PLAYER_SCENE_PATH := "res://Scenes/Player/Player.tscn"

var _overlay: TransitionOverlay
var _overlay_b: TransitionOverlay
var _mm: MultiplayerManager
var _player: Player
var _world: RoomWorld
var _room: Room
var _frames := 0
var _stage := 0
var _failures: Array[String] = []
var _called := [false, false]
var _completed: Array[bool] = []

func _initialize() -> void:
	pass

func _process(_delta: float) -> bool:
	_frames += 1
	match _stage:
		0:
			if _frames == 2:
				_setup()
				_stage = 1
		1:
			if _frames == 4:
				_sp_success_start()
				_stage = 2
		2:
			# Callable must have run during slide-out; now sliding in.
			if _overlay.phase == TransitionOverlay.Phase.SLIDING_IN:
				_expect(_called[0], "deferred callable did not run after slide-out")
				_stage = 3
		3:
			if _overlay.phase == TransitionOverlay.Phase.IDLE:
				_sp_success_finish()
				_stage = 4
		4:
			_sp_failure_and_busy()
			_stage = 5
		5:
			if _overlay.phase == TransitionOverlay.Phase.IDLE:
				_mp_lifecycle()
				_stage = 6
		6:
			if _overlay.phase == TransitionOverlay.Phase.WAITING:
				_mp_waiting_checks()
				_stage = 7
		7:
			if _overlay.phase == TransitionOverlay.Phase.IDLE:
				_mp_rejection_start()
				_stage = 8
		8:
			if _overlay.phase == TransitionOverlay.Phase.WAITING:
				_mm.transition_result.emit(false, &"timeout")
				_expect(_overlay._label.text == "Travel timed out.",
					"timeout reason text wrong (got '%s')" % _overlay._label.text)
				_stage = 9
		9:
			if _overlay.phase == TransitionOverlay.Phase.IDLE:
				_expect(_completed == [true, false, true, false],
					"transition_completed results wrong: %s" % str(_completed))
				_report()
				quit()
				return true
	return false

func _setup() -> void:
	_overlay = TransitionOverlay.new()
	_overlay.add_to_group(&"transition_overlay")
	root.add_child(_overlay)
	_overlay_b = TransitionOverlay.new()
	_overlay_b.add_to_group(&"transition_overlay")
	root.add_child(_overlay_b)
	# Local player for the input-lock checks.
	_world = _make_world()
	_player = _make_player(_world)
	# One visible room so slide_all_out actually animates (the
	# animated path is what these tests exercise).
	_room = _world.create_room_at(Vector2i(0, 0), Vector2i(0, 0), Vector2i(4, 4))
	_world.set_primary_room(Vector2i(0, 0))
	_world.room_slide_duration = 0.02
	# Fake client net manager so the deferred bind finds it.
	_mm = MultiplayerManager.new()
	_mm.name = "MultiplayerManager"
	_mm.mode = MultiplayerManager.Mode.CLIENT
	_mm.add_to_group(&"multiplayer_manager")
	root.add_child(_mm)
	_overlay.transition_completed.connect(func(ok: bool) -> void: _completed.append(ok))
	_overlay._bind_multiplayer()

func _expect(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)

func _sp_success_start() -> void:
	var result: Variant = _overlay.play_transition(Callable(self, "_fake_switch_ok"))
	_expect(result == true, "animated play_transition did not report started")
	_expect(_overlay.phase == TransitionOverlay.Phase.SLIDING_OUT,
		"play_transition did not start sliding out")
	_expect(TransitionOverlay.any_active(self), "any_active false during transition")
	_expect(_player != null and _player.local_input_locked,
		"local player not locked during transition")
	_expect(_completed.is_empty(), "transition_completed fired before slide-in")

func _sp_success_finish() -> void:
	_expect(not _player.local_input_locked, "input still locked after slide-in")
	_expect(_completed == [true], "transition_completed did not report success")

func _fake_switch_ok() -> bool:
	_called[0] = true
	return true

func _fake_switch_fail() -> bool:
	return false

func _fake_switch_nested() -> bool:
	_called[1] = true
	return true

func _sp_failure_and_busy() -> void:
	# Failed switch: slides the old floor back, shows the message,
	# reports failure and releases input — verified next stage.
	var result: Variant = _overlay.play_transition(Callable(self, "_fake_switch_fail"))
	_expect(result == true, "failure transition did not start")
	# A second play_transition while a slide is in progress must be
	# refused without running its callable.
	var again: Variant = _overlay.play_transition(Callable(self, "_fake_switch_nested"))
	_expect(again == false and not _called[1],
		"play_transition re-entered during an active slide")

func _mp_lifecycle() -> void:
	# Wait for the failure recovery to finish, then drive the MP path.
	_expect(_completed == [true, false],
		"failure transition did not report false (got %s)" % str(_completed))
	_expect(_overlay._label.text == "Transition failed.",
		"failure did not set the overlay message (got '%s')" % _overlay._label.text)
	_expect(not _player.local_input_locked, "input still locked after failure")
	_expect(_room.visible, "failed transition did not restore the room")
	# Per-instance isolation: overlay_b must ignore stray results.
	_overlay_b._on_transition_result(false, &"timeout")
	_expect(_overlay_b.phase == TransitionOverlay.Phase.IDLE,
		"second overlay reacted to a stray result")
	# Production has exactly one overlay; sever overlay_b's deferred
	# _bind_multiplayer connections (they run after _setup returns)
	# so the isolation check tests a genuinely unbound overlay.
	if _mm.transition_requested.is_connected(_overlay_b._on_transition_requested):
		_mm.transition_requested.disconnect(_overlay_b._on_transition_requested)
	if _mm.transition_result.is_connected(_overlay_b._on_transition_result):
		_mm.transition_result.disconnect(_overlay_b._on_transition_result)
	_mm.transition_requested.emit()
	_expect(_overlay.phase == TransitionOverlay.Phase.SLIDING_OUT,
		"transition_requested did not start the slide-out")

func _mp_waiting_checks() -> void:
	_expect(_overlay._is_waiting, "waiting flag not set")
	_expect(_overlay_b.phase == TransitionOverlay.Phase.IDLE,
		"second overlay animated on the first overlay's transition")
	# A synchronous switch must not interrupt a parked MP transition.
	var refused: Variant = _overlay.play_transition(Callable(self, "_fake_switch_nested"))
	_expect(refused == false and not _called[1],
		"play_transition interrupted a parked MP transition")
	# The accepted snapshot would have swapped in a fresh visible
	# world; simulate that before resolving so slide_all_in has a
	# room to animate.
	_room.visible = true
	_mm.transition_result.emit(true, &"")

func _mp_rejection_start() -> void:
	_mm.transition_requested.emit()

func _report() -> void:
	_failures.erase("")
	if _failures.is_empty():
		print("TRANSITION_OVERLAY_SMOKE: OK")
	else:
		print("TRANSITION_OVERLAY_SMOKE: FAILED (%d)" % _failures.size())
		for failure in _failures:
			print("  FAIL: %s" % failure)

func _make_world() -> RoomWorld:
	var world := RoomWorld.new()
	world.name = "OverlayTestWorld"
	world.grid = load(GRID_PATH) as IsometricGrid
	world.room_dimensions = Vector2i(16, 16)
	world.default_tile_id = &"floor_iso"
	world.tile_catalog = load(TILE_CATALOG_PATH) as TileCatalog
	world.block_catalog = load(BLOCK_CATALOG_PATH) as BlockCatalog
	world.furniture_catalog = load(FURNITURE_CATALOG_PATH) as FurnitureCatalog
	world.carpet_catalog = load(CARPET_CATALOG_PATH) as CarpetCatalog
	world.block_scene = load(BLOCK_SCENE_PATH) as PackedScene
	world.player_scene = load(PLAYER_SCENE_PATH) as PackedScene
	root.add_child(world)
	return world

func _make_player(world: RoomWorld) -> Player:
	var scene := load(PLAYER_SCENE_PATH) as PackedScene
	var player := scene.instantiate() as Player
	player.grid = world.grid
	player.move_duration = 0.0
	world.entity_layer.add_child(player)
	return player
