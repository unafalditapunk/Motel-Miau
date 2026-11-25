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
## floor's normal spawn placement; per-portal spawn selection is a
## future extension point, not part of this resource yet.
##
## Portals are directional and never imply a reciprocal portal: the
## destination floor must place its own portal back if wanted.

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
