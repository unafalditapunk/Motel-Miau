class_name CatalogPanel
extends CanvasLayer

signal catalog_toggled(is_open: bool)

const PANEL_WIDTH := 216.0
const PANEL_HEIGHT := 240.0
const GRID_COLUMNS := 4
const ITEM_SIZE := Vector2(44.0, 44.0)
## Q toggles the catalog while Build Mode is active. Creation Mode
## reserves Q for exiting the editor, so the key is only intercepted
## when creation mode is not active (toggle() guards too).
const CATALOG_KEY := KEY_Q

var building_selector: BuildingSelector
var catalog_open := false:
	set(value):
		if catalog_open == value:
			return
		catalog_open = value
		if _root != null:
			_root.visible = value
		catalog_toggled.emit(value)

var _root: PanelContainer
var _tabs_box: HBoxContainer
var _grid: GridContainer
var _empty_label: Label

var _tab_buttons: Dictionary = {}
var _item_buttons: Dictionary = {}
var _controller: BlockPlacementController

func _ready() -> void:
	layer = 64
	_build_ui()
	_root.visible = catalog_open
	if building_selector != null:
		_connect_selector()
		_refresh_all()

func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventKey):
		return
	var key_event := event as InputEventKey
	if not key_event.pressed or key_event.echo:
		return
	# Only Build Mode owns Q; in Play Mode and Creation Mode the key is
	# left alone so FloorEditor/FloorPanel shortcuts keep working.
	if key_event.physical_keycode == CATALOG_KEY \
			and _construction_mode_active() and not _creation_mode_active():
		toggle()
		get_viewport().set_input_as_handled()

func _process(_delta: float) -> void:
	if _controller == null:
		_controller = get_tree().get_first_node_in_group(&"block_placement_controller") as BlockPlacementController
		if _controller != null and not _controller.construction_mode_changed.is_connected(_on_mode_changed):
			_controller.construction_mode_changed.connect(_on_mode_changed)

func open() -> void:
	if _creation_mode_active():
		return
	if _construction_mode_active():
		catalog_open = true

func close() -> void:
	catalog_open = false

func toggle() -> void:
	if catalog_open:
		catalog_open = false
	elif not _creation_mode_active() and _construction_mode_active():
		catalog_open = true

func _creation_mode_active() -> bool:
	return FloorEditor.any_active(get_tree())

func _construction_mode_active() -> bool:
	if _controller == null:
		_controller = get_tree().get_first_node_in_group(&"block_placement_controller") as BlockPlacementController
	return _controller == null or _controller.construction_mode

func _on_mode_changed(enabled: bool) -> void:
	if not enabled:
		catalog_open = false

func is_open() -> bool:
	return catalog_open

func set_building_selector(selector: BuildingSelector) -> void:
	_disconnect_selector()
	building_selector = selector
	_connect_selector()
	_refresh_all()

func open_category(category_id: StringName) -> void:
	if building_selector != null:
		building_selector.select_category_by_id(category_id)
	open()

func _build_ui() -> void:
	_root = PanelContainer.new()
	_root.name = "CatalogRoot"
	_root.set_anchors_preset(Control.PRESET_CENTER_RIGHT)
	_root.anchor_left = 1.0
	_root.anchor_right = 1.0
	_root.anchor_top = 0.5
	_root.anchor_bottom = 0.5
	_root.offset_left = -PANEL_WIDTH - 10.0
	_root.offset_top = -PANEL_HEIGHT * 0.5
	_root.offset_right = -10.0
	_root.offset_bottom = PANEL_HEIGHT * 0.5
	_root.custom_minimum_size = Vector2(PANEL_WIDTH, PANEL_HEIGHT)
	PixelUi.style_panel(_root)
	PixelUi.nearest(_root)
	add_child(_root)

	var margin := MarginContainer.new()
	for side in [&"margin_left", &"margin_right", &"margin_top", &"margin_bottom"]:
		margin.add_theme_constant_override(side, 4)
	_root.add_child(margin)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override(&"separation", 4)
	margin.add_child(vbox)

	var title := Label.new()
	title.text = "Catalog"
	PixelUi.style_label(title, PixelUi.TEXT_COLOR, 12, true)
	vbox.add_child(title)

	_tabs_box = HBoxContainer.new()
	_tabs_box.add_theme_constant_override(&"separation", 4)
	vbox.add_child(_tabs_box)

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	vbox.add_child(scroll)

	_grid = GridContainer.new()
	_grid.columns = GRID_COLUMNS
	_grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_grid.add_theme_constant_override(&"h_separation", 2)
	_grid.add_theme_constant_override(&"v_separation", 2)
	scroll.add_child(_grid)

	_empty_label = Label.new()
	_empty_label.text = "No catalog assigned."
	PixelUi.style_label(_empty_label, PixelUi.TEXT_DIM, 10, true)
	vbox.add_child(_empty_label)

func _connect_selector() -> void:
	if building_selector == null:
		return
	if not building_selector.category_changed.is_connected(_on_category_changed):
		building_selector.category_changed.connect(_on_category_changed)
	if not building_selector.selection_changed.is_connected(_on_selection_changed):
		building_selector.selection_changed.connect(_on_selection_changed)

func _disconnect_selector() -> void:
	if building_selector == null:
		return
	if building_selector.category_changed.is_connected(_on_category_changed):
		building_selector.category_changed.disconnect(_on_category_changed)
	if building_selector.selection_changed.is_connected(_on_selection_changed):
		building_selector.selection_changed.disconnect(_on_selection_changed)

func _refresh_all() -> void:
	_rebuild_tabs()
	_rebuild_items()

func _rebuild_tabs() -> void:
	for child in _tabs_box.get_children():
		child.queue_free()
	_tab_buttons.clear()
	_empty_label.visible = building_selector == null or building_selector.get_categories().is_empty()
	if building_selector == null:
		return
	for category in building_selector.get_categories():
		var button := Button.new()
		button.text = category.display_name
		button.toggle_mode = true
		button.custom_minimum_size = Vector2(0.0, 18.0)
		button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		PixelUi.style_button(button, true)
		PixelUi.nearest(button)
		button.button_pressed = category == building_selector.selected_category
		button.pressed.connect(_on_tab_pressed.bind(category))
		_tabs_box.add_child(button)
		_tab_buttons[category] = button

func _rebuild_items() -> void:
	for child in _grid.get_children():
		child.queue_free()
	_item_buttons.clear()
	if building_selector == null:
		return
	for definition in building_selector.get_definitions():
		var button := Button.new()
		button.toggle_mode = true
		button.tooltip_text = definition.display_name
		button.custom_minimum_size = ITEM_SIZE
		button.expand_icon = true
		PixelUi.style_button(button)
		PixelUi.nearest(button)
		button.icon = definition.sprite_texture if definition.sprite_texture != null else PixelUi.placeholder_icon(definition.object_id)
		button.button_pressed = definition == building_selector.selected_definition
		button.pressed.connect(_on_item_pressed.bind(definition))
		_grid.add_child(button)
		_item_buttons[definition] = button

func _on_tab_pressed(category: CatalogCategory) -> void:
	if building_selector != null:
		building_selector.select_category(category)
	for tab_category in _tab_buttons.keys():
		var button: Button = _tab_buttons[tab_category]
		button.set_pressed_no_signal(building_selector != null and tab_category == building_selector.selected_category)

func _on_item_pressed(definition: PlaceableDefinition) -> void:
	if building_selector != null:
		building_selector.select_definition(definition)
	var controller := get_tree().get_first_node_in_group(&"block_placement_controller") as BlockPlacementController
	if controller != null:
		controller.construction_mode = true
	close()

func _on_category_changed(_category: CatalogCategory) -> void:
	_rebuild_tabs()
	_rebuild_items()

func _on_selection_changed(_definition: PlaceableDefinition) -> void:
	for button in _item_buttons.values():
		button.set_pressed_no_signal(false)
	if building_selector != null and building_selector.selected_definition != null:
		var button: Button = _item_buttons.get(building_selector.selected_definition)
		if button != null:
			button.set_pressed_no_signal(true)
