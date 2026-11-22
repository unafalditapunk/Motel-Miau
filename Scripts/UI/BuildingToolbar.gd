class_name BuildingToolbar
extends CanvasLayer

const BAR_HEIGHT := 30.0
const BUTTON_MIN_SIZE := Vector2(78.0, 20.0)

const CATEGORY_TILES := &"tiles"
const CATEGORY_CARPETS := &"carpets"
const CATEGORY_BLOCKS := &"blocks"
const CATEGORY_FURNITURE := &"furniture"

var placement_controller: BlockPlacementController
var building_selector: BuildingSelector
var world: WorldBootstrap
var catalog_panel: CatalogPanel

var _normal_button: Button
var _build_button: Button
var _strip: Control
var _controller_bound := false
var _mode_group := ButtonGroup.new()

func _ready() -> void:
	layer = 62
	_build_ui()
	_sync_mode_buttons()

func _process(_delta: float) -> void:
	if placement_controller == null:
		placement_controller = get_tree().get_first_node_in_group(&"block_placement_controller") as BlockPlacementController
		_bind_controller()
	if world == null:
		world = get_tree().get_first_node_in_group(&"world") as WorldBootstrap
	if building_selector == null:
		building_selector = _find_building_selector()
	if catalog_panel == null:
		catalog_panel = _find_catalog_panel()

func setup(controller: BlockPlacementController, selector: BuildingSelector, world_ref: WorldBootstrap, catalog: CatalogPanel) -> void:
	placement_controller = controller
	building_selector = selector
	world = world_ref
	catalog_panel = catalog
	_bind_controller()

func _build_ui() -> void:
	# Full-width bottom strip that ignores the mouse; the visible bar is a
	# shrink-wrapped panel centered inside it, so it stays centered at any
	# resolution and never blocks world clicks outside its own rect.
	var strip := Control.new()
	strip.name = "ToolbarStrip"
	strip.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	strip.offset_top = -BAR_HEIGHT - 12.0
	strip.offset_bottom = -6.0
	strip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	strip.visible = false
	add_child(strip)
	_strip = strip

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	strip.add_child(center)

	var root := PanelContainer.new()
	root.name = "ToolbarRoot"
	root.custom_minimum_size = Vector2(0.0, BAR_HEIGHT)
	PixelUi.style_panel(root)
	PixelUi.nearest(root)
	center.add_child(root)

	var margin := MarginContainer.new()
	for side in [&"margin_left", &"margin_right", &"margin_top", &"margin_bottom"]:
		margin.add_theme_constant_override(side, 3)
	root.add_child(margin)

	var hbox := HBoxContainer.new()
	hbox.alignment = BoxContainer.ALIGNMENT_CENTER
	hbox.add_theme_constant_override(&"separation", 4)
	margin.add_child(hbox)

	_normal_button = _make_button("Normal", _on_normal_pressed)
	_normal_button.toggle_mode = true
	_normal_button.button_group = _mode_group
	_build_button = _make_button("Build", _on_build_pressed)
	_build_button.toggle_mode = true
	_build_button.button_group = _mode_group
	hbox.add_child(_normal_button)
	hbox.add_child(_build_button)
	hbox.add_child(_make_separator())
	hbox.add_child(_make_button("Tiles", _on_tiles_pressed))
	hbox.add_child(_make_button("Carpets", _on_carpets_pressed))
	hbox.add_child(_make_button("Blocks", _on_blocks_pressed))
	hbox.add_child(_make_button("Furniture", _on_furniture_pressed))
	hbox.add_child(_make_separator())
	hbox.add_child(_make_button("Save Room", _on_save_pressed))

func _make_button(text: String, on_pressed: Callable) -> Button:
	var button := Button.new()
	button.text = text
	button.custom_minimum_size = BUTTON_MIN_SIZE
	PixelUi.style_button(button)
	PixelUi.nearest(button)
	button.pressed.connect(on_pressed)
	return button

func _make_separator() -> Control:
	var separator := ColorRect.new()
	separator.custom_minimum_size = Vector2(1.0, 16.0)
	separator.color = PixelUi.PANEL_BORDER
	separator.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	return separator

func _bind_controller() -> void:
	if placement_controller == null or _controller_bound:
		return
	if not placement_controller.construction_mode_changed.is_connected(_on_mode_changed):
		placement_controller.construction_mode_changed.connect(_on_mode_changed)
	_controller_bound = true
	_sync_mode_buttons()
	_sync_visibility()

func _on_mode_changed(_enabled: bool) -> void:
	_sync_mode_buttons()
	_sync_visibility()

func _sync_visibility() -> void:
	if _strip != null:
		_strip.visible = placement_controller != null and placement_controller.construction_mode

func _sync_mode_buttons() -> void:
	if _normal_button == null or _build_button == null:
		return
	var building := placement_controller != null and placement_controller.construction_mode
	_normal_button.set_pressed_no_signal(not building)
	_build_button.set_pressed_no_signal(building)

func _on_normal_pressed() -> void:
	if placement_controller != null:
		placement_controller.construction_mode = false
	_sync_mode_buttons()

func _on_build_pressed() -> void:
	if placement_controller != null:
		placement_controller.construction_mode = true
	_sync_mode_buttons()

func _open_catalog_category(category_id: StringName) -> void:
	if placement_controller != null:
		placement_controller.construction_mode = true
	_sync_mode_buttons()
	if building_selector != null:
		building_selector.select_category_by_id(category_id)
	if catalog_panel != null:
		catalog_panel.open()

func _on_tiles_pressed() -> void:
	_open_catalog_category(CATEGORY_TILES)

func _on_carpets_pressed() -> void:
	_open_catalog_category(CATEGORY_CARPETS)

func _on_blocks_pressed() -> void:
	_open_catalog_category(CATEGORY_BLOCKS)

func _on_furniture_pressed() -> void:
	_open_catalog_category(CATEGORY_FURNITURE)

func _on_save_pressed() -> void:
	if world != null:
		world.save_game()

func _find_building_selector() -> BuildingSelector:
	var world_node := get_tree().get_first_node_in_group(&"world") as WorldBootstrap
	if world_node == null:
		return null
	return world_node.get_node_or_null(^"BuildingSelector") as BuildingSelector

func _find_catalog_panel() -> CatalogPanel:
	var world_node := get_tree().get_first_node_in_group(&"world") as WorldBootstrap
	if world_node == null:
		return null
	return world_node.get_node_or_null(^"CatalogPanel") as CatalogPanel
