extends SceneTree
## Benchmarks the per-frame cost of FloorEditor's tile computation:
## cell set + boundary masks + inner-mark planning, replicated from
## _draw_shape_tiles/_plan_inner_marks. Draw calls themselves are
## cheap canvas commands; this measures the GDScript overhead.

const EDGE_UL := 1
const EDGE_UR := 2
const EDGE_LR := 4
const EDGE_LL := 8

func _boundary_mask(cell: Vector2i, cells: Dictionary) -> int:
	var mask := 0
	if not cells.has(cell + Vector2i(-1, 0)):
		mask |= EDGE_UL
	if not cells.has(cell + Vector2i(0, -1)):
		mask |= EDGE_UR
	if not cells.has(cell + Vector2i(1, 0)):
		mask |= EDGE_LR
	if not cells.has(cell + Vector2i(0, 1)):
		mask |= EDGE_LL
	return mask

func _plan_inner_marks(cells: Dictionary, masks: Dictionary) -> int:
	var reflex := {}
	for cell: Vector2i in cells:
		var x := cell.x
		var y := cell.y
		var verts := {
			Vector2i(2 * x - 1, 2 * y - 1): [cell, cell + Vector2i(-1, 0),
				cell + Vector2i(0, -1), cell + Vector2i(-1, -1)],
			Vector2i(2 * x + 1, 2 * y - 1): [cell, cell + Vector2i(0, -1),
				cell + Vector2i(1, 0), cell + Vector2i(1, -1)],
			Vector2i(2 * x + 1, 2 * y + 1): [cell, cell + Vector2i(1, 0),
				cell + Vector2i(0, 1), cell + Vector2i(1, 1)],
			Vector2i(2 * x - 1, 2 * y + 1): [cell, cell + Vector2i(-1, 0),
				cell + Vector2i(0, 1), cell + Vector2i(-1, 1)],
		}
		for v in verts:
			if reflex.has(v):
				continue
			var present := 0
			for c in verts[v]:
				if cells.has(c):
					present += 1
			if present == 3:
				reflex[v] = verts[v]
	var count := 0
	for v in reflex:
		count += 1
	return count

func _frame_cost(sections: Array) -> float:
	var cells := {}
	for section in sections:
		for y in range(section.position.y, section.end.y):
			for x in range(section.position.x, section.end.x):
				cells[Vector2i(x, y)] = true
	var masks := {}
	for cell in cells:
		masks[cell] = _boundary_mask(cell, cells)
	return _plan_inner_marks(cells, masks)

## Proxy for _build_room_draw_ops: same cell/mask/mark pass, emits
## flat [id, Vector2 pos, Vector2 half] triples instead of drawing.
func _build_ops_proxy(sections: Array) -> Array:
	var cells := {}
	for section in sections:
		for y in range(section.position.y, section.end.y):
			for x in range(section.position.x, section.end.x):
				cells[Vector2i(x, y)] = true
	var masks := {}
	for cell in cells:
		masks[cell] = _boundary_mask(cell, cells)
	_plan_inner_marks(cells, masks)
	var ops := []
	for cell in cells:
		ops.append([cells[cell], Vector2(cell), Vector2(32, 16)])
	return ops

## Proxy for the cached draw loop: transform + subtract per op.
func _frame_iterate(ops: Array) -> float:
	var acc := 0.0
	for op in ops:
		var p: Vector2 = op[1] * 64.0
		acc += p.x + p.y + op[2].x
	return acc

func _init() -> void:
	# Simulate floors: N rooms of SxS cells each, spaced apart.
	for room_count: int in [17, 50, 100]:
		for size: int in [12, 32]:
			var sections: Array = []
			for i: int in range(room_count):
				var ox: int = (i % 10) * (size + 4)
				var oy: int = (i / 10) * (size + 4)
				sections.append(Rect2i(Vector2i(ox, oy), Vector2i(size, size)))
			# warmup + timed run of one "frame" worth of compute
			_frame_cost(sections)
			var t0 := Time.get_ticks_usec()
			var iterations := 20
			for i in range(iterations):
				_frame_cost(sections)
			var avg := (Time.get_ticks_usec() - t0) / 1000.0 / iterations
			var total_cells: int = room_count * size * size
			print("rooms=%d size=%dx%d cells=%d -> %.2f ms/frame (uncached)" % [
				room_count, size, size, total_cells, avg])
			# Cached path: geometry built once, then per-frame work is
			# iterating flat [texture, pos, half] ops + a grid->screen
			# transform per op (draw_texture itself not measurable headless).
			var ops := _build_ops_proxy(sections)
			var t1 := Time.get_ticks_usec()
			for i in range(iterations):
				_frame_iterate(ops)
			var cavg := (Time.get_ticks_usec() - t1) / 1000.0 / iterations
			print("rooms=%d size=%dx%d cells=%d -> %.3f ms/frame (cached iterate, no draw)" % [
				room_count, size, size, total_cells, cavg])
	print("BENCH DONE")
	quit()
