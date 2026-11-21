class_name FurnitureCatalog
extends ObjectCatalog

func get_definition(furniture_id: StringName) -> FurnitureDefinition:
	for definition_resource in definitions:
		var definition := definition_resource as FurnitureDefinition
		if definition != null and definition.object_id == furniture_id:
			return definition
	return null
