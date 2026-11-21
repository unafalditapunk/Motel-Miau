class_name BuildingCatalog
extends Resource

@export var categories: Array[CatalogCategory] = []

func get_category(category_id: StringName) -> CatalogCategory:
	for category in categories:
		if category != null and category.category_id == category_id:
			return category
	return null

func get_definitions(category_id: StringName) -> Array[PlaceableDefinition]:
	var category := get_category(category_id)
	if category == null or category.catalog == null:
		return []
	return category.catalog.get_definitions()

func find_definition(object_id: StringName) -> PlaceableDefinition:
	for category in categories:
		if category == null or category.catalog == null:
			continue
		var definition := category.catalog.get_definition(object_id)
		if definition != null:
			return definition
	return null
