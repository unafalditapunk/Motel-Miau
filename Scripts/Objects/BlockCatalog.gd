class_name BlockCatalog
extends ObjectCatalog

func get_definition(block_id: StringName) -> BlockDefinition:
	for definition_resource in definitions:
		var definition := definition_resource as BlockDefinition
		if definition != null and definition.object_id == block_id:
			return definition
	return null
