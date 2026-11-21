class_name Main
extends Node2D

const STARTUP_SCENE := preload("res://Scenes/World/World.tscn")

func _ready() -> void:
	var startup_scene := STARTUP_SCENE.instantiate()
	add_child(startup_scene)
