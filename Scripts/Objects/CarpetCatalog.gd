class_name CarpetCatalog
extends ObjectCatalog

func get_definition(carpet_id: StringName) -> CarpetDefinition:
	for definition_resource in definitions:
		var definition := definition_resource as CarpetDefinition
		if definition != null and definition.object_id == carpet_id:
			return definition
	return null
