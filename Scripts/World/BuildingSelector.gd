class_name BuildingSelector
extends Node

signal category_changed(category: CatalogCategory)
signal selection_changed(definition: PlaceableDefinition)

@export var building_catalog: BuildingCatalog:
	set(value):
		if building_catalog == value:
			return
		building_catalog = value
		if is_node_ready():
			set_catalog(value)
@export var auto_select_first := true

var selected_category: CatalogCategory
var selected_definition: PlaceableDefinition
var rotation_degrees := 0
var flipped := false

func _ready() -> void:
	if building_catalog != null and auto_select_first:
		_select_first_category()

func set_catalog(catalog: BuildingCatalog) -> void:
	building_catalog = catalog
	selected_category = null
	selected_definition = null
	rotation_degrees = 0
	flipped = false
	if building_catalog != null and auto_select_first:
		_select_first_category()

func get_categories() -> Array[CatalogCategory]:
	if building_catalog == null:
		return []
	return building_catalog.categories

func get_definitions() -> Array[PlaceableDefinition]:
	if selected_category == null or selected_category.catalog == null:
		return []
	return selected_category.catalog.get_definitions()

func select_category(category: CatalogCategory) -> void:
	if category == null or category == selected_category:
		return
	selected_category = category
	rotation_degrees = 0
	flipped = false
	category_changed.emit(category)
	_select_first_definition()

func select_category_by_id(category_id: StringName) -> void:
	if building_catalog == null:
		return
	select_category(building_catalog.get_category(category_id))

func select_definition(definition: PlaceableDefinition) -> void:
	if definition == null:
		clear_selection()
		return
	selected_definition = definition
	selection_changed.emit(definition)

func clear_selection() -> void:
	selected_definition = null
	rotation_degrees = 0
	flipped = false
	selection_changed.emit(null)

func flip() -> void:
	flipped = not flipped
	selection_changed.emit(selected_definition)

func rotate() -> void:
	rotation_degrees = posmod(rotation_degrees + 90, 360)
	selection_changed.emit(selected_definition)

func _select_first_category() -> void:
	var categories := get_categories()
	if categories.is_empty():
		return
	select_category(categories[0])

func _select_first_definition() -> void:
	var definitions := get_definitions()
	if definitions.is_empty():
		selected_definition = null
		selection_changed.emit(null)
		return
	select_definition(definitions[0])
