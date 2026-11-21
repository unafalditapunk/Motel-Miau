class_name TileCatalog
extends ObjectCatalog

func get_definition(tile_id: StringName) -> TileDefinition:
	for definition_resource in definitions:
		var definition := definition_resource as TileDefinition
		if definition != null and definition.object_id == tile_id:
			return definition
	return null
