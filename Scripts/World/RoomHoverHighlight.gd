class_name RoomHoverHighlight
extends Node2D

const NORMAL_TEXTURE := preload("res://Assets/Sprites/Hover Tiles/normal_mode_iso.png")
const CONSTRUCTION_TEXTURE := preload("res://Assets/Sprites/Hover Tiles/construcition_mode_iso.png")

var room: Room
var _controller: BlockPlacementController
var _last_construction_mode := false

func _ready() -> void:
	z_index = 4096
	if get_parent() is Room:
		room = get_parent() as Room

func _process(_delta: float) -> void:
	if _controller == null:
		_controller = get_tree().get_first_node_in_group(&"block_placement_controller") as BlockPlacementController
		if _controller == null:
			return
		_last_construction_mode = _controller.construction_mode
	if _controller.construction_mode != _last_construction_mode:
		_last_construction_mode = _controller.construction_mode
		queue_redraw()

func _hover_elevation() -> float:
	return room.hovered_elevation if room != null else 0.0

func _draw() -> void:
	if room == null or room.grid == null:
		return
	if not room.grid.is_valid(room.hovered_cell, room.size):
		return
	var center := room.grid.grid_to_screen_position(Vector2(room.hovered_cell), _hover_elevation())
	var texture := CONSTRUCTION_TEXTURE if _controller != null and _controller.construction_mode else NORMAL_TEXTURE
	var top_left := center - Vector2(texture.get_size()) * 0.5
	draw_texture(texture, top_left)
