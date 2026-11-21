extends SceneTree

var _frames := 0
var _failures: Array[String] = []
var _world: World
var _toolbar: BuildingToolbar
var _catalog: CatalogPanel
var _controller: BlockPlacementController
var _selector: BuildingSelector

func _initialize() -> void:
	_world = load("res://Scenes/World/World.tscn").instantiate()
	root.add_child(_world)
	_toolbar = _world.get_node_or_null("BuildingToolbar") as BuildingToolbar
	_catalog = _world.get_node_or_null("CatalogPanel") as CatalogPanel
	_controller = _world.get_node_or_null("BlockPlacementController") as BlockPlacementController
	_selector = _world.get_node_or_null("BuildingSelector") as BuildingSelector

func _process(_delta: float) -> bool:
	_frames += 1
	if _frames < 5:
		return false
	_run_checks()
	_report()
	quit()
	return true

func _expect(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)

func _button_texts() -> Array[String]:
	var texts: Array[String] = []
	for button in _toolbar.find_children("*", "Button", true, false):
		texts.append((button as Button).text)
	return texts

func _press_key(keycode: Key) -> void:
	var event := InputEventKey.new()
	event.keycode = keycode
	event.pressed = true
	_catalog._unhandled_input(event)

func _run_checks() -> void:
	_expect(_toolbar != null, "BuildingToolbar node missing from World")
	_expect(_catalog != null, "CatalogPanel node missing from World")
	_expect(_controller != null, "BlockPlacementController missing")
	_expect(_selector != null, "BuildingSelector missing")
	if _toolbar == null or _catalog == null or _controller == null or _selector == null:
		return

	var texts := _button_texts()
	for expected in ["Normal", "Build", "Tiles", "Carpets", "Blocks", "Furniture", "Save Room"]:
		_expect(texts.has(expected), "toolbar missing button '%s' (got %s)" % [expected, texts])

	_expect(not _catalog.is_open(), "catalog should start closed")
	_press_key(KEY_Q)
	_expect(not _catalog.is_open(), "Q opened the catalog in normal mode")

	_expect(not _toolbar._strip.visible, "toolbar should be hidden in normal mode")
	_toolbar._on_build_pressed()
	_expect(_toolbar._strip.visible, "toolbar should be visible in construction mode")
	_press_key(KEY_Q)
	_expect(_catalog.is_open(), "Q did not open the catalog in construction mode")
	_press_key(KEY_Q)
	_expect(not _catalog.is_open(), "Q did not close the catalog")

	_catalog.open()
	_toolbar._on_normal_pressed()
	_expect(not _toolbar._strip.visible, "toolbar should hide again in normal mode")
	_expect(not _catalog.is_open(), "catalog stayed open after leaving construction mode")
	_toolbar._on_build_pressed()

	_toolbar._on_tiles_pressed()
	_expect(_selector.selected_category != null and _selector.selected_category.category_id == &"tiles",
		"Tiles button did not select the tiles category")
	_expect(_catalog.is_open(), "Tiles button did not open the catalog")

	_toolbar._on_carpets_pressed()
	_expect(_selector.selected_category != null and _selector.selected_category.category_id == &"carpets",
		"Carpets button did not select the carpets category")

	_toolbar._on_blocks_pressed()
	_expect(_controller.construction_mode, "Blocks button did not enable construction mode")
	_expect(_catalog.is_open(), "Blocks button did not open the catalog")
	_expect(_selector.selected_category != null and _selector.selected_category.category_id == &"blocks",
		"Blocks button did not select the blocks category")
	_expect(_catalog._item_buttons.size() >= 1, "blocks category produced no catalog items")

	_catalog.open()
	var first_definition: PlaceableDefinition = _selector.get_definitions()[0]
	_catalog._on_item_pressed(first_definition)
	_expect(not _catalog.is_open(), "catalog did not close after item selection")
	_expect(_controller.construction_mode, "item selection did not enable construction mode")

	_toolbar._on_furniture_pressed()
	_expect(_selector.selected_category != null and _selector.selected_category.category_id == &"furniture",
		"Furniture button did not select the furniture category")

	_toolbar._on_normal_pressed()
	_expect(not _controller.construction_mode, "Normal button did not disable construction mode")

func _report() -> void:
	if _failures.is_empty():
		print("BUILDING_UI_SMOKE: OK")
	else:
		for failure in _failures:
			push_error("BUILDING_UI_SMOKE FAIL: %s" % failure)
		print("BUILDING_UI_SMOKE: FAIL (%d)" % _failures.size())
