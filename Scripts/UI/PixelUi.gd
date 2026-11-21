class_name PixelUi
extends RefCounted

## Shared styling helpers for the building UI. Everything is generated
## in code so the interface needs no external theme assets.

const PANEL_BG := Color(0.09, 0.08, 0.15, 0.94)
const PANEL_BORDER := Color(0.85, 0.72, 0.45, 0.9)
const BUTTON_BG := Color(0.16, 0.14, 0.24, 0.95)
const BUTTON_BORDER := Color(0.55, 0.48, 0.35, 0.9)
const BUTTON_PRESSED_BG := Color(0.85, 0.62, 0.30, 0.95)
const TEXT_COLOR := Color(0.95, 0.92, 0.85)
const TEXT_DIM := Color(0.95, 0.92, 0.85, 0.55)

const PLACEHOLDER_SIZE := 16

static func make_panel_stylebox(bg := PANEL_BG, border := PANEL_BORDER, border_width := 1) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = bg
	style.border_color = border
	style.set_border_width_all(border_width)
	style.set_corner_radius_all(0)
	style.anti_aliasing = false
	style.content_margin_left = 6.0
	style.content_margin_right = 6.0
	style.content_margin_top = 6.0
	style.content_margin_bottom = 6.0
	return style

static func style_panel(container: PanelContainer, bg := PANEL_BG, border := PANEL_BORDER) -> void:
	container.add_theme_stylebox_override(&"panel", make_panel_stylebox(bg, border))

static func style_button(button: Button, small_font := false) -> void:
	button.add_theme_stylebox_override(&"normal", make_button_stylebox(BUTTON_BG, BUTTON_BORDER))
	button.add_theme_stylebox_override(&"hover", make_button_stylebox(BUTTON_BG.lightened(0.12), BUTTON_BORDER))
	button.add_theme_stylebox_override(&"pressed", make_button_stylebox(BUTTON_PRESSED_BG, BUTTON_BORDER))
	button.add_theme_stylebox_override(&"hover_pressed", make_button_stylebox(BUTTON_PRESSED_BG.lightened(0.1), BUTTON_BORDER))
	button.add_theme_stylebox_override(&"disabled", make_button_stylebox(Color(BUTTON_BG, 0.4), BUTTON_BORDER))
	button.add_theme_color_override(&"font_color", TEXT_COLOR)
	button.add_theme_color_override(&"font_hover_color", TEXT_COLOR)
	button.add_theme_color_override(&"font_pressed_color", Color(0.15, 0.12, 0.08))
	button.add_theme_color_override(&"font_disabled_color", TEXT_DIM)
	button.add_theme_constant_override(&"h_separation", 4)
	if small_font:
		button.add_theme_font_size_override(&"font_size", 10)

static func make_button_stylebox(bg: Color, border: Color) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = bg
	style.border_color = border
	style.set_border_width_all(1)
	style.set_corner_radius_all(0)
	style.anti_aliasing = false
	style.content_margin_left = 6.0
	style.content_margin_right = 6.0
	style.content_margin_top = 3.0
	style.content_margin_bottom = 3.0
	return style

static func style_label(label: Label, color := TEXT_COLOR, font_size := 10, centered := false) -> void:
	label.add_theme_color_override(&"font_color", color)
	label.add_theme_font_size_override(&"font_size", font_size)
	if centered:
		label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER

## Deterministic placeholder icon used until final UI artwork exists.
## Returns a 16x16 pixel-art-style swatch tinted per definition.
static func placeholder_icon(object_id: StringName) -> ImageTexture:
	var hue := float(posmod(int(object_id.hash()), 360)) / 360.0
	var base := Color.from_hsv(hue, 0.55, 0.85)
	var dark := base.darkened(0.4)
	var light := base.lightened(0.25)
	var image := Image.create(PLACEHOLDER_SIZE, PLACEHOLDER_SIZE, false, Image.FORMAT_RGBA8)
	image.fill(base)
	# 1px darker border
	for x in PLACEHOLDER_SIZE:
		image.set_pixel(x, 0, dark)
		image.set_pixel(x, PLACEHOLDER_SIZE - 1, dark)
	for y in PLACEHOLDER_SIZE:
		image.set_pixel(0, y, dark)
		image.set_pixel(PLACEHOLDER_SIZE - 1, y, dark)
	# simple inner glyph: lighter top-left block, dark bottom-right block
	for y in range(4, 9):
		for x in range(4, 9):
			image.set_pixel(x, y, light if x + y < 12 else dark)
	return ImageTexture.create_from_image(image)

static func nearest(control: CanvasItem) -> void:
	control.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
