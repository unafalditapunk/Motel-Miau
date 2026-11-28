class_name CombatHighlights
extends Node2D

## World-space overlay for combat cell markers. Two layers:
## - Textured markers (Assets/Sprites/Combat/Tiles) become individual
##   Sprite2D children with z_as_relative = false and the cell's
##   surface depth, so they occlude exactly like floor tiles — tall
##   sprites in front hide them, entities on the cell cover them.
## - Tint markers (attack target etc.) are drawn flat by this node at
##   z_index 4096, always on top as a UI-ish indicator.
## CombatManager feeds it precomputed canvas positions — it never
## queries the grid itself.

var grid: IsometricGrid
## Global alpha applied to textured markers — the cell/path tiles
## are loud enough to read through at ~45%.
const TILE_ALPHA := 0.6
## Array of {pos: Vector2, color: Color, texture: Texture2D, depth: int}.
## A non-null texture is drawn by a pooled Sprite2D, not by _draw.
var markers: Array = []
## Second layer drawn above markers — the hover path preview.
var preview: Array = []

## Cached opaque-bbox centers per texture: the combat tiles pack the
## cell diamond into the bottom half of a 64x64 canvas, so the draw
## offset is the bbox center, not the texture center.
var _anchors: Dictionary = {}
var _sprites: Array[Sprite2D] = []

func set_markers(list: Array) -> void:
	markers = list
	_sync_textures()
	queue_redraw()

func set_preview(list: Array) -> void:
	preview = list
	_sync_textures()
	queue_redraw()

func clear() -> void:
	set_markers([])
	set_preview([])

## Rebuilds the textured-marker sprites. Called on every marker
## change; counts stay small (reachable cells + path steps), so a
## full rebuild per hover-cell change is cheap.
func _sync_textures() -> void:
	for sprite in _sprites:
		sprite.queue_free()
	_sprites.clear()
	for marker in markers:
		_make_sprite(marker)
	for marker in preview:
		_make_sprite(marker)

func _make_sprite(marker: Dictionary) -> void:
	var tex: Texture2D = marker.get("texture")
	if tex == null:
		return
	var sprite := Sprite2D.new()
	sprite.texture = tex
	sprite.centered = false
	sprite.texture_filter = CanvasItem.TEXTURE_FILTER_PARENT_NODE
	sprite.position = marker.get("pos", Vector2.ZERO) - _anchor_for(tex)
	# Absolute z: sort by the cell's surface depth among world
	# sprites regardless of this overlay's own z_index=4096.
	sprite.z_as_relative = false
	sprite.z_index = int(marker.get("depth", 0))
	sprite.modulate = Color(1, 1, 1, TILE_ALPHA)
	add_child(sprite)
	_sprites.append(sprite)

func _draw() -> void:
	if grid == null:
		return
	for marker in markers:
		_draw_marker(marker)
	for marker in preview:
		_draw_marker(marker)

func _draw_marker(marker: Dictionary) -> void:
	var pos: Vector2 = marker.get("pos", Vector2.ZERO)
	# Textured markers are Sprite2D children — skip them here.
	if marker.get("texture") != null:
		return
	var half_w := grid.tile_width * 0.5
	var half_h := grid.tile_height * 0.5
	var pts := PackedVector2Array([
		pos + Vector2(0.0, -half_h),
		pos + Vector2(half_w, 0.0),
		pos + Vector2(0.0, half_h),
		pos + Vector2(-half_w, 0.0),
	])
	draw_colored_polygon(pts, marker.get("color", Color(0, 0, 0, 0)))
	var closed := PackedVector2Array()
	closed.append_array(pts)
	closed.append(pts[0])
	draw_polyline(closed, Color(1, 1, 1, 0.6), 1.0)

## Center of the texture's opaque pixels — where the cell diamond
## sits inside the canvas. Falls back to the texture center.
func _anchor_for(tex: Texture2D) -> Vector2:
	if _anchors.has(tex):
		return _anchors[tex]
	var anchor := Vector2(tex.get_width(), tex.get_height()) * 0.5
	var image := tex.get_image()
	if image != null:
		var w := image.get_width()
		var h := image.get_height()
		var min_x := w
		var min_y := h
		var max_x := -1
		var max_y := -1
		for y in h:
			for x in w:
				if image.get_pixel(x, y).a > 0.1:
					if x < min_x:
						min_x = x
					if x > max_x:
						max_x = x
					if y < min_y:
						min_y = y
					if y > max_y:
						max_y = y
		if max_x >= 0:
			anchor = Vector2((min_x + max_x + 1) * 0.5,
				(min_y + max_y + 1) * 0.5)
	_anchors[tex] = anchor
	return anchor
