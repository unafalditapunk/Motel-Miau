class_name FloorPortal
extends Resource

## A FloorPortal links one global world cell on its owning Floor to a
## different Floor — the cross-floor counterpart of a RoomConnection.
## Portals are pure data owned by the Floor (Floor.portals): they hold
## no RoomWorld reference and survive save/load and runtime world
## reconstruction unchanged.
##
## Triggering is cell-based: stepping onto world_cell inside room_id
## requests a transition to destination_floor_id through the normal
## FloorManager switch path (single-player) or the authoritative
## transition request (multiplayer). Arriving uses the destination
## floor's normal spawn placement unless destination_world_cell is
## set — then the traveler lands on that exact global cell of the
## destination floor, which is how portal-to-portal chains work
## (point one portal's arrival at another portal's cell).
##
## Portals are directional and never imply a reciprocal portal: the
## destination floor must place its own portal back if wanted.

## Sentinel for "no arrival override": the traveler uses the
## destination floor's normal (random) spawn placement.
const NO_DESTINATION_CELL := Vector2i(-2147483648, -2147483648)

## Unique id within the owning floor. Placement derives it
## deterministically from the cell ("portal_x_y"), which is unique
## because at most one portal may occupy a cell.
@export var portal_id: StringName
## room_id of the FloorRoomSpec whose footprint contains world_cell.
## Kept explicit so validation and lookups never re-derive it.
@export var room_id := Vector2i.ZERO
## Global world cell (same space as Floor.spawn_points) the player
## steps onto to trigger the portal.
@export var world_cell := Vector2i.ZERO
## floor_id of the destination Floor. Must name another registered
## floor — same-floor portals are refused.
@export var destination_floor_id: StringName
## Optional precise arrival: a global world cell on
## destination_floor_id the traveler lands on instead of a random
## spawn point. Typically another portal's world_cell for portal
## chains. Must lie inside a room footprint of the destination floor;
## unresolvable values fall back to spawn placement at travel time.
@export var destination_world_cell := NO_DESTINATION_CELL

## True when this portal overrides the arrival cell.
func has_destination_cell() -> bool:
	return destination_world_cell != NO_DESTINATION_CELL
