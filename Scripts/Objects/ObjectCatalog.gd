class_name ObjectCatalog
extends Resource

@export var definitions: Array[Resource] = []

func get_definition(object_id: StringName) -> PlaceableDefinition:
	for definition_resource in definitions:
		var definition := definition_resource as PlaceableDefinition
		if definition != null and definition.object_id == object_id:
			return definition
	return null

func get_definitions() -> Array[PlaceableDefinition]:
	var result: Array[PlaceableDefinition] = []
	for definition_resource in definitions:
		var definition := definition_resource as PlaceableDefinition
		if definition != null:
			result.append(definition)
	return result
