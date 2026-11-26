class_name TileDefinition
extends PlaceableDefinition

## Vertical anchor for sprite_texture when the texture is taller than
## the tile diamond (tile_height px):
##   0 = Bottom Center — the texture's bottom tile_height pixels are the
##       cell diamond and decoration grows upward (grass, flowers).
##   1 = Center — the texture's vertical center sits on the cell center.
@export_enum("Bottom Center", "Center") var sprite_anchor := 0
