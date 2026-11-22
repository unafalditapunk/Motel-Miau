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
