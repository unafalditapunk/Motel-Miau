extends Node2D

var text := ""
var color := Color(1.0, 1.0, 1.0, 0.85)
var font_size := 12

func _draw() -> void:
	var font := ThemeDB.fallback_font
	if font == null or text.is_empty():
		return
	var label_position := Vector2(-12.0, -4.0)
	draw_string(font, label_position + Vector2(1.0, 0.0), text, HORIZONTAL_ALIGNMENT_LEFT, -1.0, font_size, Color(0.0, 0.0, 0.0, color.a * 0.8))
	draw_string(font, label_position + Vector2(-1.0, 0.0), text, HORIZONTAL_ALIGNMENT_LEFT, -1.0, font_size, Color(0.0, 0.0, 0.0, color.a * 0.8))
	draw_string(font, label_position + Vector2(0.0, 1.0), text, HORIZONTAL_ALIGNMENT_LEFT, -1.0, font_size, Color(0.0, 0.0, 0.0, color.a * 0.8))
	draw_string(font, label_position + Vector2(0.0, -1.0), text, HORIZONTAL_ALIGNMENT_LEFT, -1.0, font_size, Color(0.0, 0.0, 0.0, color.a * 0.8))
	draw_string(font, label_position, text, HORIZONTAL_ALIGNMENT_LEFT, -1.0, font_size, color)
