extends SceneTree

var _catalog: BuildingCatalog
var _selector: BuildingSelector
var _frames := 0
var _failures: Array[String] = []

func _initialize() -> void:
	_catalog = load("res://Resources/BuildingCatalog.tres") as BuildingCatalog
	_expect(_catalog != null, "BuildingCatalog.tres failed to load")
	if _catalog == null:
		_report()
		quit()
		return

	_expect(_catalog.categories.size() == 4, "expected 4 categories, got %d" % _catalog.categories.size())

	var tiles := _catalog.get_category(&"tiles")
	var carpets := _catalog.get_category(&"carpets")
	var blocks := _catalog.get_category(&"blocks")
	var furniture := _catalog.get_category(&"furniture")
	_expect(tiles != null, "tiles category missing")
	_expect(carpets != null, "carpets category missing")
	_expect(blocks != null, "blocks category missing")
	_expect(furniture != null, "furniture category missing")
	if tiles == null or carpets == null or blocks == null or furniture == null:
		_report()
		quit()
		return

	var tile_defs := tiles.catalog.get_definitions()
	var carpet_defs := carpets.catalog.get_definitions()
	var block_defs := blocks.catalog.get_definitions()
	var furniture_defs := furniture.catalog.get_definitions()
	_expect(tile_defs.any(func(d): return d.object_id == &"floor_iso"), "floor_iso missing from tiles category")
	_expect(carpet_defs.any(func(d): return d.object_id == &"flower_carpet"), "flower_carpet missing from carpets category")
	_expect(block_defs.any(func(d): return d.object_id == &"standard_block"), "standard_block missing from blocks category")
	_expect(furniture_defs.any(func(d): return d.object_id == &"chair"), "chair missing from furniture category")
	_expect(_catalog.find_definition(&"flower_carpet") is CarpetDefinition, "find_definition should return CarpetDefinition for flower_carpet")
	_expect(_catalog.find_definition(&"chair") is FurnitureDefinition, "find_definition should return FurnitureDefinition for chair")
	_expect(_catalog.find_definition(&"standard_block") is BlockDefinition, "find_definition should return BlockDefinition for standard_block")
	_expect(_catalog.find_definition(&"floor_iso") is TileDefinition, "find_definition should return TileDefinition for floor_iso")

	_selector = BuildingSelector.new()
	_selector.building_catalog = _catalog
	root.add_child(_selector)

func _process(_delta: float) -> bool:
	_frames += 1
	if _frames < 2:
		return false
	if _selector != null:
		_test_selector()
		_selector.queue_free()
	_report()
	quit()
	return true

func _test_selector() -> void:
	var tiles := _catalog.get_category(&"tiles")
	var carpets := _catalog.get_category(&"carpets")
	var blocks := _catalog.get_category(&"blocks")
	var furniture := _catalog.get_category(&"furniture")
	_expect(_selector.selected_category == tiles, "selector should auto-select first category")
	_expect(_selector.selected_definition != null and _selector.selected_definition.object_id == &"floor_iso", "selector should auto-select first tile")

	_selector.select_category(carpets)
	_expect(_selector.selected_category == carpets, "select_category(carpets) failed")
	_expect(_selector.selected_definition != null and _selector.selected_definition.object_id == &"flower_carpet", "carpets selection should default to flower_carpet")

	_selector.select_category(blocks)
	_expect(_selector.selected_category == blocks, "select_category(blocks) failed")
	_expect(_selector.selected_definition != null and _selector.selected_definition.object_id == &"standard_block", "blocks selection should default to standard_block")

	_selector.select_category(furniture)
	_expect(_selector.selected_category == furniture, "select_category(furniture) failed")
	_expect(_selector.selected_definition != null and _selector.selected_definition.object_id == &"chair", "furniture selection should default to chair")

	_selector.rotate()
	_expect(_selector.rotation_degrees == 90, "rotate should set 90 degrees, got %d" % _selector.rotation_degrees)

	_selector.select_definition(_catalog.find_definition(&"standard_block"))
	_expect(_selector.selected_definition != null and _selector.selected_definition.object_id == &"standard_block", "select_definition failed")

func _expect(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)

func _report() -> void:
	if _failures.is_empty():
		print("BUILDING_CATALOG_SMOKE: OK")
	else:
		for failure in _failures:
			push_error("BUILDING_CATALOG_SMOKE FAIL: " + failure)
		print("BUILDING_CATALOG_SMOKE: FAILED (%d)" % _failures.size())
