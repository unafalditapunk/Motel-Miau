class_name Main
extends Node2D

const WORLD_SCENE := preload("res://Scenes/World/WorldBootstrap.tscn")

func _ready() -> void:
	var world := WORLD_SCENE.instantiate() as WorldBootstrap
	if world == null:
		push_error("Main: failed to instantiate WorldBootstrap scene.")
		return
	# Boot straight into the Motel floor: WorldBootstrap materializes it
	# from Floor specs (user://floors/motel/ holds saves) instead of the
	# legacy single-room + manual ring registration.
	world.startup_floor_id = &"motel"
	add_child(world)
	# Edge exits require an explicit connection; the floor's
	# auto_connect_adjacent materialization generates the doors.
	world.room_world.require_explicit_connections = true
	# Debug builds get a " (DEBUG)" window-title suffix from the engine;
	# override it via DisplayServer (Window.title re-appends the suffix).
	# Re-apply over the first seconds in case the OS title is rewritten
	# after the window is realized. Release exports skip this.
	if OS.has_feature("debug"):
		var title := String(ProjectSettings.get_setting("application/config/name", "Miau Motel"))
		for i in 120:
			await RenderingServer.frame_post_draw
			DisplayServer.window_set_title(title, get_window().get_window_id())
