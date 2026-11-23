class_name FloorRoomSpec
extends Resource

## One room slot inside a Floor definition. Room IDs are only unique
## within their floor; global_origin positions the room's local (0,0)
## cell in the floor's shared world cell grid.

@export var room_id := Vector2i.ZERO
@export var global_origin := Vector2i.ZERO
## Room dimensions in cells. Vector2i.ZERO defers to room_definition's
## size, or the bound RoomWorld's default room_dimensions.
@export var size := Vector2i.ZERO
## Optional RoomDefinition supplying floor texture, default tile,
## furniture and carpet placements.
@export var room_definition: RoomDefinition
@export var floor_colors: Array[Color] = []
## Creation-Mode visibility options. show_from_outside=false hides the
## room unless the player is inside it; show_outside=false hides the
## block layers of edge-adjacent rooms while this room is primary.
@export var show_from_outside := true
@export var show_outside := true
## Optional non-rectangular footprint: rects in GLOBAL cell
## coordinates (same space as global_origin) whose union defines the
## room's cells — L-shapes, T-shapes, etc. Empty means the plain
## rectangle described by global_origin + size. When present,
## global_origin/size are normalized to the union's bounding box.
@export var shape_sections: Array[Rect2i] = []

## Global cell rects that make up this spec's footprint: the stored
## sections, or the single global_origin+size rectangle.
func global_sections() -> Array[Rect2i]:
	if not shape_sections.is_empty():
		return shape_sections.duplicate()
	var resolved := size
	if resolved == Vector2i.ZERO and room_definition != null:
		resolved = room_definition.size
	if resolved == Vector2i.ZERO:
		return []
	return [Rect2i(global_origin, resolved)]

## Union bounding box of the footprint in global cells, or an empty
## rect when the spec has no resolvable shape.
func bounds() -> Rect2i:
	var sections := global_sections()
	if sections.is_empty():
		return Rect2i()
	var result := sections[0]
	for section in sections.slice(1):
		result = result.merge(section)
	return result

## Total number of cells in the footprint (sections may overlap, so
## this counts the union, not the sum).
func cell_count() -> int:
	var cells := {}
	for section in global_sections():
		for x in range(section.position.x, section.end.x):
			for y in range(section.position.y, section.end.y):
				cells[Vector2i(x, y)] = true
	return cells.size()
