extends SceneTree

## One-shot setup for live multiplayer portal verification. Boots the
## real WorldBootstrap headless, creates an "attic" floor, covers the
## motel entry room with portals to it, gives the attic return
## portals to motel, and saves everything under the --saves dir (or
## the default user://floors). Not part of the smoke suite — run:
##
##   godot --headless --path . -s res://Scripts/Test/PortalMpSetup.gd -- --saves=user://mp_portal

const BOOTSTRAP_SCENE := "res://Scenes/World/WorldBootstrap.tscn"

var _world: WorldBootstrap
var _frames := 0

func _process(_delta: float) -> bool:
	_frames += 1
	if _frames == 1:
		var scene := load(BOOTSTRAP_SCENE) as PackedScene
		_world = scene.instantiate() as WorldBootstrap
		_world.startup_floor_id = &"motel"
		root.add_child(_world)
	if _frames == 5:
		_setup()
		_report()
		quit()
		return true
	return false

func _setup() -> void:
	var fm := _world.floor_manager
	if fm == null or fm.active_floor == null:
		print("PORTAL_MP_SETUP: no floor manager/active floor")
		return
	# Attic: one 8x8 room floor.
	var spec := FloorRoomSpec.new()
	spec.room_id = Vector2i.ZERO
	spec.global_origin = Vector2i.ZERO
	spec.size = Vector2i(8, 8)
	var attic := fm.create_floor(&"attic", "Attic", [spec])
	if attic == null:
		print("PORTAL_MP_SETUP: create_floor attic failed")
		return
	# Cover every cell of the motel entry room with a portal -> attic.
	# Specs may defer size/origin to a RoomDefinition, so iterate the
	# materialized Room's footprint cells instead.
	var entry_room := _world.room_world.get_room(
		fm.active_floor.entry_room_id)
	var placed := 0
	if entry_room != null:
		for local in entry_room.cells:
			var wc: Vector2i = entry_room.world_cell_coordinates(local)
			if fm.place_portal_on_floor(&"motel", wc, &"attic"):
				placed += 1
	print("PORTAL_MP_SETUP: motel->attic portals placed: %d" % placed)
	# Materialize attic and cover it with return portals -> motel.
	if not fm.switch_floor(&"attic"):
		print("PORTAL_MP_SETUP: switch to attic failed")
		return
	var back := 0
	for s in fm.active_floor.rooms:
		for y in range(s.size.y):
			for x in range(s.size.x):
				var wc: Vector2i = s.global_origin + Vector2i(x, y)
				if fm.place_portal(wc, &"motel"):
					back += 1
	print("PORTAL_MP_SETUP: attic->motel portals placed: %d" % back)
	if not fm.switch_floor(&"motel"):
		print("PORTAL_MP_SETUP: switch back to motel failed")
		return
	fm.save_active_floor()

func _report() -> void:
	print("PORTAL_MP_SETUP: done")
