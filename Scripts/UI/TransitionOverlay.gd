class_name TransitionOverlay
extends CanvasLayer

## Screen-space floor-transition presenter (Phase P3). Pure
## presentation: it never decides whether a transition succeeds and
## holds no authority over floors, worlds or networking — it only
## reacts to transition lifecycle events.
##
## Visual language: the current floor's rooms slide down and off
## ("leave through the bottom"), the destination floor's rooms slide
## in from above ("arrive from the top") — the same slide animation
## RoomVisuals uses for room-to-room moves, applied to the whole
## floor. RoomVisuals.slide_all_out/in/home do the work; this node
## sequences them around the actual floor switch.
##
## Two drivers share this one controller:
##   - Single player: play_transition(callable) slides the old floor
##     out, THEN runs the callable (e.g. FloorManager.switch_floor)
##     once the screen has cleared, then slides the new floor in.
##     Because the callable is deferred, its result is reported via
##     the transition_completed signal; play_transition itself returns
##     true when the transition started (or the callable's real result
##     when there was nothing to animate and it ran synchronously).
##   - Multiplayer client: MultiplayerManager.transition_requested
##     slides the current floor out and parks the overlay in WAITING;
##     transition_result(accepted, reason) — emitted only for the
##     matching transition_id per the P2.1 lifecycle — slides the new
##     floor in, or slides the old floor back home on rejection.
##
## Per-player isolation is structural: each WorldBootstrap owns one
## overlay, and only the LOCAL client's lifecycle signals reach it —
## nothing is broadcast, so other players and the dedicated server
## never see a transition.

signal transition_visual_started
signal transition_visual_finished
## Emitted once per transition with the final success flag. For the
## synchronous fast path this fires inside play_transition; for the
## animated path it fires when the slide-in (or failure recovery)
## completes.
signal transition_completed(success: bool)

enum Phase { IDLE, SLIDING_OUT, WAITING, SLIDING_IN }

## True while a transition is in progress (sliding, waiting or
## sliding back in). Building UI checks this via any_active().
var phase := Phase.IDLE

var _phase_left := 0.0
var _is_waiting := false
var _in_callable := false
var _pending_callable := Callable()
var _transition_ok := true
var _held_player: Player = null
var _held_lock := false
var _label: Label
var _message_left := 0.0

static func any_active(tree: SceneTree) -> bool:
	for node in tree.get_nodes_in_group(&"transition_overlay"):
		var overlay := node as TransitionOverlay
		if overlay != null and overlay.phase != Phase.IDLE:
			return true
	return false

static func find_overlay(tree: SceneTree) -> TransitionOverlay:
	return tree.get_first_node_in_group(&"transition_overlay") as TransitionOverlay

func _ready() -> void:
	layer = 68
	add_to_group(&"transition_overlay")
	_label = Label.new()
	_label.name = "Message"
	_label.visible = false
	_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_label.add_theme_color_override(&"font_color", PixelUi.TEXT_COLOR)
	_label.add_theme_color_override(&"font_shadow_color", Color(0, 0, 0, 0.8))
	_label.add_theme_constant_override(&"shadow_offset_x", 1)
	_label.add_theme_constant_override(&"shadow_offset_y", 1)
	_label.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	_label.position = Vector2(-200, -72)
	_label.size = Vector2(400, 24)
	add_child(_label)
	# The net manager may be created after this node; binding is
	# deferred and retried until it exists (single-player stays
	# unbound — play_transition covers that path).
	call_deferred(&"_bind_multiplayer")

func _bind_multiplayer() -> void:
	var net := get_tree().get_first_node_in_group(&"multiplayer_manager") as MultiplayerManager
	if net == null:
		return
	if not net.transition_requested.is_connected(_on_transition_requested):
		net.transition_requested.connect(_on_transition_requested)
	if not net.transition_result.is_connected(_on_transition_result):
		net.transition_result.connect(_on_transition_result)

# ------------------------------------------------------------------
# World access
# ------------------------------------------------------------------

func _world() -> WorldBootstrap:
	return get_tree().get_first_node_in_group(&"world") as WorldBootstrap

func _room_world() -> RoomWorld:
	var world := _world()
	if world != null and world.room_world != null:
		return world.room_world
	# Fallback for bare RoomWorlds (tests, custom setups) that are not
	# inside a WorldBootstrap.
	return get_tree().get_first_node_in_group(&"room_worlds") as RoomWorld

func _visuals() -> RoomVisuals:
	var room_world := _room_world()
	return room_world.visuals if room_world != null else null

func _slide_duration() -> float:
	var room_world := _room_world()
	return room_world.room_slide_duration if room_world != null else 0.22

# ------------------------------------------------------------------
# Single-player / synchronous driver
# ------------------------------------------------------------------

## Slides the current floor out, runs `callable` once the screen has
## cleared, then slides the destination floor in. Returns true when
## the animated transition started; when there is nothing to animate
## (no rooms, or room_slide_duration == 0 — the test knob) the
## callable runs synchronously and its real result is returned.
## Refuses while any transition is in progress — a second switch
## mid-slide could corrupt world state — and against re-entry from
## inside the callable itself.
func play_transition(callable: Callable) -> Variant:
	if phase != Phase.IDLE or _in_callable or not callable.is_valid():
		return false
	var visuals := _visuals()
	var duration := _slide_duration()
	var slide_count := 0
	if visuals != null and duration > 0.0:
		slide_count = visuals.slide_all_out()
	if slide_count == 0:
		# Nothing on screen to move: fully synchronous, the result
		# passes straight through like the old fade path did.
		_lock_local_player()
		_in_callable = true
		var result: Variant = callable.call()
		_in_callable = false
		_unlock_local_player()
		if result == false:
			_show_message("Transition failed.")
		transition_completed.emit(result != false)
		return result
	_pending_callable = callable
	_is_waiting = false
	_transition_ok = true
	_lock_local_player()
	phase = Phase.SLIDING_OUT
	_phase_left = duration
	transition_visual_started.emit()
	return true

func _on_slide_out_done() -> void:
	# The old floor has cleared the screen — now run the real switch.
	_in_callable = true
	var result: Variant = _pending_callable.call()
	_in_callable = false
	_pending_callable = Callable()
	if result == false:
		_transition_ok = false
		_show_message("Transition failed.")
		_begin_slide_home()
		return
	_begin_slide_in()

func _begin_slide_in() -> void:
	var visuals := _visuals()
	var count := visuals.slide_all_in() if visuals != null else 0
	phase = Phase.SLIDING_IN
	_phase_left = _slide_duration() if count > 0 else 0.0
	# The destination world is already fully built and the player is
	# placed — release input immediately so the player can walk while
	# the rooms are still sliding in. The player stays visible the
	# whole transition: they are never hidden, they simply wait at
	# their cell while the floor slides out and stand at the spawn
	# while the new floor slides in.
	_unlock_local_player()

func _begin_slide_home() -> void:
	# Failure recovery: the old floor was never destroyed — snap its
	# rooms back and release input right away; the world is already
	# in its final state.
	var visuals := _visuals()
	if visuals != null:
		visuals.slide_all_home()
	phase = Phase.SLIDING_IN
	_phase_left = _slide_duration()
	_unlock_local_player()

func _finish_transition() -> void:
	phase = Phase.IDLE
	_unlock_local_player()
	transition_visual_finished.emit()
	transition_completed.emit(_transition_ok)

# ------------------------------------------------------------------
# Multiplayer driver (local signals only — never broadcast)
# ------------------------------------------------------------------

## A local transition request was accepted: slide the current floor
## out, then park until transition_result resolves it.
func _on_transition_requested() -> void:
	if phase != Phase.IDLE:
		return
	_is_waiting = true
	_pending_callable = Callable()
	_transition_ok = true
	var visuals := _visuals()
	var count := visuals.slide_all_out() if visuals != null else 0
	phase = Phase.SLIDING_OUT
	_phase_left = _slide_duration() if count > 0 else 0.0
	transition_visual_started.emit()
	print("TransitionOverlay: sliding out (multiplayer transition pending).")

## The matching transition resolved. Accepted: the snapshot already
## applied the new world, so slide it in. Rejected/timed out: the old
## floor is intact — slide it back home.
func _on_transition_result(accepted: bool, reason: StringName) -> void:
	if phase == Phase.IDLE:
		# Result without a matching begin (shouldn't happen — the
		# client only emits for live requests): still surface failure.
		if not accepted:
			_show_message(_reason_text(reason))
		return
	if not accepted:
		_is_waiting = false
		_transition_ok = false
		_show_message(_reason_text(reason))
		_begin_slide_home()
		return
	_is_waiting = false
	_begin_slide_in()

func _reason_text(reason: StringName) -> String:
	match reason:
		&"timeout":
			return "Travel timed out."
		&"busy":
			return "Already traveling."
		&"unknown_floor", &"no_portal", &"not_at_portal", &"already_there":
			return "Travel refused."
		_:
			return "Travel failed."

func _show_message(text: String) -> void:
	_label.text = text
	_message_left = 2.5
	_label.visible = true

# ------------------------------------------------------------------
# Input lock + frame update
# ------------------------------------------------------------------

func _lock_local_player() -> void:
	# Capture the pre-transition lock state only once: the lock must
	# not be overwritten with the already-locked value.
	if _held_player != null and is_instance_valid(_held_player):
		_held_player.local_input_locked = true
		return
	_held_player = get_tree().get_first_node_in_group(&"player") as Player
	if _held_player != null:
		_held_lock = _held_player.local_input_locked
		_held_player.local_input_locked = true

func _unlock_local_player() -> void:
	if _held_player != null and is_instance_valid(_held_player):
		_held_player.local_input_locked = _held_lock
	_held_player = null
	_held_lock = false

func _process(delta: float) -> void:
	if phase == Phase.IDLE:
		if _message_left > 0.0:
			_message_left -= delta
			if _message_left <= 0.0:
				_label.visible = false
		return
	_phase_left -= delta
	if _phase_left > 0.0:
		return
	match phase:
		Phase.SLIDING_OUT:
			if _is_waiting:
				# Multiplayer: old floor cleared — park at the empty
				# world until transition_result arrives.
				phase = Phase.WAITING
			else:
				_on_slide_out_done()
		Phase.SLIDING_IN:
			_finish_transition()
		# WAITING parks until _on_transition_result resolves it.
