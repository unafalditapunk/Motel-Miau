class_name CombatEnemy
extends Node2D

## Prototype enemy body for the first playable combat encounter.
## World-cell anchored like Player: world_cell is in shared world
## coordinates and the visual is an AnimatedSprite2D snapped to the
## cell surface. No combat logic or AI lives here — CombatManager
## owns the Combatant and turn behavior and calls the play_*()
## animation hooks when attacks resolve.
##
## Art convention (same layout as player characters):
##   <root>/rotations/<dir>.png                    — idle, 4 dirs
##   <root>/animations/Walking/<dir>/frame_*.png   — walk cycle
##   <root>/animations/Attacking/<dir>/frame_*.png — attack
##   <root>/animations/Attacked/<dir>/frame_*.png  — hit reaction
##   <root>/animations/Death/<dir>/frame_*.png     — death (non-loop)
## Only west dirs (south-west/north-west) need art on disk; east dirs
## fall back to horizontally mirrored west frames, same as Player.
## Missing folders/animations degrade gracefully to idle.

const ENEMY_ROOT := "res://Assets/Enemies/baby blue slime"
## Last-resort art while real enemy packs are being authored.
const FALLBACK_ROOT := "res://Assets/Characters/vobine/grey-bull"
## Warm tint marks the fallback bull as hostile; real enemy art is
## shown untinted.
const FALLBACK_TINT := Color(1.0, 0.6, 0.6)
## Per-cell slide time for animate_to_path — matches the player's
## combat_move_duration so both actors move at the same tactical pace.
const STEP_SECONDS := 0.12
## Animation playback rates (frames per second). Walk cycles are
## authored longer than a single step, so ~16fps reads as a hop
## cycle spanning several cells.
const WALK_FPS := 16.0
const ACTION_FPS := 12.0
const DEATH_FPS := 10.0

## Grid direction → art dir name, identical mapping to Player:
## (0,1) = screen down-left = south-west, (1,0) = down-right =
## south-east, (-1,0) = up-left = north-west, (0,-1) = up-right =
## north-east.
const DIR_NAMES := {
	Vector2i(0, 1): "south-west",
	Vector2i(1, 0): "south-east",
	Vector2i(-1, 0): "north-west",
	Vector2i(0, -1): "north-east",
}
## East art falls back to mirrored west frames when the folder is
## absent — the slime pack only ships west dirs.
const MIRRORED_DIRS := {
	"south-east": "south-west",
	"north-east": "north-west",
}
## Animation prefix → folder under <root>/animations/.
const ACTION_FOLDERS := {
	"attack": "Attacking",
	"attacked": "Attacked",
}

enum VisualMode { IDLE, WALK, ACTION, DEATH }

var world_cell := Vector2i.ZERO
var elevation := 0.0
var height_units := 2.0
var grid: IsometricGrid
var block_layer: BlockLayer
var room: Room
var display_name := "Slime"
## True while the death animation is playing; CombatManager lets the
## node live until the clip finishes (it frees itself on completion)
## instead of queue_freeing it during teardown.
var death_pending := false

var facing := Vector2i(0, 1)

var _visual: AnimatedSprite2D
var _root := ""
var _move_tween: Tween
var _mode := VisualMode.IDLE
## Action clip queued while a path slide is still running; played by
## _on_path_done when the tween drains.
var _pending_action := &""
## Per-animation y offsets aligning each clip's feet to the idle
## ground line (walk frames reserve canvas space differently).
var _anim_y_offsets: Dictionary = {}

func _ready() -> void:
	_root = _resolve_root()
	_visual = AnimatedSprite2D.new()
	_visual.name = "Visual"
	_visual.texture_filter = CanvasItem.TEXTURE_FILTER_PARENT_NODE
	_visual.sprite_frames = _build_frames()
	if _root == FALLBACK_ROOT:
		_visual.modulate = FALLBACK_TINT
	_visual.animation_finished.connect(_on_animation_finished)
	add_child(_visual)
	_update_visual_metrics()
	_play_idle()
	_update_visual()

func _resolve_root() -> String:
	# exists() guard: load() logs an engine error per missing file.
	if ResourceLoader.exists("%s/rotations/south-west.png" % ENEMY_ROOT):
		return ENEMY_ROOT
	if ResourceLoader.exists("%s/rotations/south-west.png" % FALLBACK_ROOT):
		push_warning("CombatEnemy: '%s' missing — using fallback art." % ENEMY_ROOT)
		return FALLBACK_ROOT
	push_warning("CombatEnemy: no enemy art found; sprite will be blank.")
	return ""

# ------------------------------------------------------------------
# SpriteFrames construction
# ------------------------------------------------------------------

func _build_frames() -> SpriteFrames:
	var frames := SpriteFrames.new()
	if _root.is_empty():
		return frames
	for direction in DIR_NAMES:
		var dir_name: String = DIR_NAMES[direction]
		var idle_tex := _load_texture("%s/rotations/%s.png" % [_root, dir_name])
		if idle_tex != null:
			_add_clip(frames, "idle_%s" % dir_name, [idle_tex], true, 1.0)
	for prefix in ACTION_FOLDERS:
		for direction in DIR_NAMES:
			var dir_name: String = DIR_NAMES[direction]
			var textures := _clip_frames("%s/animations/%s/%s" % [_root, ACTION_FOLDERS[prefix], dir_name])
			if textures.is_empty():
				textures = _mirrored_clip_frames(prefix, dir_name)
			if not textures.is_empty():
				# One-shot clips: animation_finished drives the return
				# to idle (and death's deferred start after a hit).
				_add_clip(frames, "%s_%s" % [prefix, dir_name], textures, false, ACTION_FPS)
	for direction in DIR_NAMES:
		var dir_name: String = DIR_NAMES[direction]
		var textures := _clip_frames("%s/animations/Walking/%s" % [_root, dir_name])
		if textures.is_empty():
			textures = _mirrored_clip_frames("walk", dir_name)
		if not textures.is_empty():
			_add_clip(frames, "walk_%s" % dir_name, textures, true, WALK_FPS)
	# Death ships a single facing in the slime pack; use it for all.
	var death := _clip_frames("%s/animations/Death/south-west" % _root)
	if death.is_empty():
		death = _clip_frames("%s/animations/Death/north-west" % _root)
	if not death.is_empty():
		_add_clip(frames, "death", death, false, DEATH_FPS)
	_computing_offsets(frames)
	return frames

## "<prefix>_<dir>" clips align their feet against the matching
## "idle_<dir>"; "death" (no dir suffix) uses south-west.
func _idle_for_clip(frames: SpriteFrames, anim_name: String) -> StringName:
	var dir_name := "south-west"
	for known in DIR_NAMES.values():
		if anim_name.ends_with("_%s" % known):
			dir_name = known
			break
	var idle := StringName("idle_%s" % dir_name)
	if frames.has_animation(idle):
		return idle
	return &""

func _add_clip(frames: SpriteFrames, anim: String, textures: Array,
		loop: bool, fps: float) -> void:
	if not frames.has_animation(anim):
		frames.add_animation(anim)
	for texture in textures:
		frames.add_frame(anim, texture)
	frames.set_animation_loop(anim, loop)
	frames.set_animation_speed(anim, fps)

func _clip_frames(dir_path: String) -> Array:
	var all: Array = []
	for i in 32:
		var path := "%s/frame_%03d.png" % [dir_path, i]
		if not ResourceLoader.exists(path):
			break
		var texture := load(path) as Texture2D
		if texture == null:
			break
		all.append(texture)
	return all

## East clips fall back to flipped west frames — same convention as
## Player._walk_frames_for.
func _mirrored_clip_frames(prefix: String, dir_name: String) -> Array:
	var mirror := String(MIRRORED_DIRS.get(dir_name, ""))
	if mirror.is_empty():
		return []
	var folder := ""
	match prefix:
		"walk":
			folder = "Walking"
		"attack":
			folder = "Attacking"
		"attacked":
			folder = "Attacked"
		_:
			return []
	var source := _clip_frames("%s/animations/%s/%s" % [_root, folder, mirror])
	var flipped: Array = []
	for texture in source:
		flipped.append(_flip_texture_horizontal(texture))
	return flipped

func _flip_texture_horizontal(texture: Texture2D) -> Texture2D:
	var image := texture.get_image()
	if image == null:
		return texture
	image.flip_x()
	image.generate_mipmaps()
	return ImageTexture.create_from_image(image)

func _load_texture(path: String) -> Texture2D:
	if not ResourceLoader.exists(path):
		return null
	return load(path) as Texture2D

# ------------------------------------------------------------------
# Animation playback
# ------------------------------------------------------------------

func _idle_anim_for(direction: Vector2i) -> StringName:
	var dir_name: String = DIR_NAMES.get(direction, "south-west")
	var anim := StringName("idle_%s" % dir_name)
	if _visual != null and _visual.sprite_frames != null \
			and _visual.sprite_frames.has_animation(anim):
		return anim
	# Facing dir has no idle art — fall back to any idle clip.
	if _visual == null or _visual.sprite_frames == null:
		return &""
	for anim_name in _visual.sprite_frames.get_animation_names():
		if String(anim_name).begins_with("idle_"):
			return anim_name
	return &""

func _play(anim: StringName) -> void:
	if anim == &"" or _visual == null or _visual.sprite_frames == null:
		return
	if not _visual.sprite_frames.has_animation(anim):
		return
	_mode = _mode_for(anim)
	if _visual.animation != anim or not _visual.is_playing():
		_visual.animation = anim
		_visual.play(anim)
	_apply_visual_offset()

func _mode_for(anim: StringName) -> VisualMode:
	var clip := String(anim)
	if clip == "death":
		return VisualMode.DEATH
	if clip.begins_with("walk_"):
		return VisualMode.WALK
	if clip.begins_with("attack_") or clip.begins_with("attacked_"):
		return VisualMode.ACTION
	return VisualMode.IDLE

func _play_idle() -> void:
	_play(_idle_anim_for(facing))

## Plays an action clip now, or queues it behind the in-flight path
## slide. Empty/missing clips are ignored so art-less packs degrade
## to plain movement.
func _play_or_queue(anim: StringName) -> void:
	if anim == &"":
		return
	if _tween_running():
		_pending_action = anim
		return
	_pending_action = &""
	_play(anim)

func _action_anim(prefix: String) -> StringName:
	var dir_name: String = DIR_NAMES.get(facing, "south-west")
	return StringName("%s_%s" % [prefix, dir_name])

## Enemy attack clip, faced toward the player (CombatManager sets
## facing first via face_toward_world).
func play_attack() -> void:
	_play_or_queue(_action_anim("attack"))

## Hit reaction when the player lands an attack.
func play_attacked() -> void:
	_play_or_queue(_action_anim("attacked"))

## Death clip: snaps to the committed cell, kills any slide, and
## frees the node when the clip finishes. Teardown skips queue_free
## while death_pending so the animation is actually visible.
func play_death() -> void:
	_kill_tween()
	_pending_action = &""
	_update_visual()
	if _visual == null or _visual.sprite_frames == null \
			or not _visual.sprite_frames.has_animation(&"death"):
		queue_free()
		return
	death_pending = true
	# Let a playing hit reaction read first, then collapse.
	if _mode == VisualMode.ACTION and _visual.is_playing():
		_visual.animation_finished.connect(_play_death_clip, CONNECT_ONE_SHOT)
	else:
		_play_death_clip()

func _play_death_clip() -> void:
	if _visual == null or not is_inside_tree():
		return
	_mode = VisualMode.DEATH
	_visual.animation = &"death"
	_visual.play(&"death")
	_apply_visual_offset()

func face_toward_world(target_cell: Vector2i) -> void:
	_set_facing(_dominant_dir(target_cell - world_cell))

func _set_facing(direction: Vector2i) -> void:
	if not DIR_NAMES.has(direction):
		return
	facing = direction
	if _mode == VisualMode.IDLE:
		_play_idle()

func _dominant_dir(delta: Vector2i) -> Vector2i:
	if delta == Vector2i.ZERO:
		return facing
	if absi(delta.x) >= absi(delta.y):
		return Vector2i(1 if delta.x > 0 else -1, 0)
	return Vector2i(0, 1 if delta.y > 0 else -1)

## AnimatedSprite2D.animation_finished emits no arguments — the
## finished clip is still readable via _visual.animation.
func _on_animation_finished() -> void:
	var anim := _visual.animation
	if anim == &"death":
		queue_free()
	elif _mode == VisualMode.ACTION and not death_pending:
		_play_idle()

func _tween_running() -> bool:
	return _move_tween != null and _move_tween.is_valid() \
		and _move_tween.is_running()

# ------------------------------------------------------------------
# Movement presentation
# ------------------------------------------------------------------

## Snaps the enemy to a world cell + surface elevation. Called by
## CombatManager when the session reports combatant_moved, and as the
## fallback when no animation path is available.
func place_at_world(new_cell: Vector2i, new_elevation: float) -> void:
	_kill_tween()
	_pending_action = &""
	world_cell = new_cell
	elevation = new_elevation
	_play_idle()
	_update_visual()

## Slides the sprite along an ordered world-cell path (INCLUDING both
## endpoints, CombatGrid.get_path convention). Each step sets facing
## and the matching walk clip before the slide; logical world_cell
## and elevation commit to the destination immediately — the tween is
## presentation-only, so turn logic never waits on it.
func animate_to_path(cells: Array) -> void:
	_kill_tween()
	_pending_action = &""
	if cells.is_empty():
		return
	var final: Vector2i = cells[cells.size() - 1]
	world_cell = final
	elevation = _elevation_for(final)
	if cells.size() < 2 or grid == null:
		_play_idle()
		_update_visual()
		return
	_move_tween = create_tween()
	_move_tween.set_parallel(false)
	for i in range(1, cells.size()):
		var cell: Vector2i = cells[i]
		var step_dir := _dominant_dir(cell - cells[i - 1])
		_move_tween.tween_callback(_begin_step.bind(step_dir))
		var target := grid.grid_to_screen_position(Vector2(cell), _elevation_for(cell))
		_move_tween.tween_property(self, "position", target, STEP_SECONDS)
	_move_tween.tween_callback(_on_path_done)

func _begin_step(direction: Vector2i) -> void:
	_set_facing(direction)
	var dir_name: String = DIR_NAMES.get(direction, "south-west")
	var walk := StringName("walk_%s" % dir_name)
	if _visual != null and _visual.sprite_frames != null \
			and _visual.sprite_frames.has_animation(walk):
		_play(walk)
	else:
		_play_idle()

func _on_path_done() -> void:
	_move_tween = null
	_update_depth()
	if _pending_action != &"":
		var queued := _pending_action
		_pending_action = &""
		_play(queued)
	else:
		_play_idle()

func _kill_tween() -> void:
	if _tween_running():
		_move_tween.kill()
	_move_tween = null

func _elevation_for(cell: Vector2i) -> float:
	if block_layer != null:
		return block_layer.get_surface_elevation(cell - block_layer.cell_origin)
	return 0.0

func _exit_tree() -> void:
	_kill_tween()

## While a path tween runs, re-sample depth every frame from the
## sprite's feet — same convention as Player._depth_for_screen_position.
## Without this the enemy keeps the START cell's z_index for the whole
## slide and slides behind carpet/tiles of the cells it enters.
func _process(_delta: float) -> void:
	if _tween_running():
		_update_depth()

func _update_visual() -> void:
	if grid == null or not is_inside_tree():
		return
	position = grid.grid_to_screen_position(Vector2(world_cell), elevation)
	_update_depth()

func _update_depth() -> void:
	if grid == null or block_layer == null or not is_inside_tree():
		return
	# Same formula as Player._depth_for_screen_position: feet sample
	# (bottom vertex of the cell diamond minus a hair) lifted by the
	# elevation offset, then depth_for_cell on the world cell found.
	var feet := position + Vector2(0.0, grid.tile_height * 0.5 - 2.0)
	var anchored := feet + Vector2(0.0, elevation * grid.height_pixels_per_unit)
	var local := grid.screen_to_grid(anchored) - block_layer.cell_origin
	z_index = clampi(block_layer.depth_for_cell(local, elevation) + 1, -4096, 4096)

# ------------------------------------------------------------------
# Foot-line alignment (same pixel measurement as Player)
# ------------------------------------------------------------------

## Per-animation y offset so every clip's feet land on the same
## ground line as the idle sprites. Measured once at startup from
## the lowest opaque pixel of each clip vs the facing idle.
func _computing_offsets(frames: SpriteFrames) -> void:
	_anim_y_offsets.clear()
	for anim_name in frames.get_animation_names():
		var clip := String(anim_name)
		if clip.begins_with("idle_"):
			continue
		var idle_name := _idle_for_clip(frames, clip)
		if idle_name == &"":
			continue
		var idle_tex := frames.get_frame_texture(idle_name, 0)
		if idle_tex == null:
			continue
		var idle_margin := _sprite_bottom_margin(idle_tex)
		var clip_margin := INF
		var clip_height := 0.0
		for i in frames.get_frame_count(anim_name):
			var tex := frames.get_frame_texture(anim_name, i)
			if tex == null:
				continue
			clip_margin = minf(clip_margin, _sprite_bottom_margin(tex))
			clip_height = maxf(clip_height, float(tex.get_height()))
		if clip_margin == INF or idle_margin == 0.0:
			continue
		_anim_y_offsets[anim_name] = (idle_tex.get_height() - clip_height) * 0.5 \
			+ (clip_margin - idle_margin)

func _sprite_bottom_margin(texture: Texture2D) -> float:
	var image := texture.get_image()
	if image == null:
		return 0.0
	var height := image.get_height()
	var width := image.get_width()
	for y in range(height - 1, -1, -1):
		for x in range(width):
			if image.get_pixel(x, y).a > 0.05:
				return float(height - y)
	return 0.0

func _update_visual_metrics() -> void:
	if _visual == null or _visual.sprite_frames == null or grid == null:
		return
	var idle_tex := _visual.sprite_frames.get_frame_texture(_idle_anim_for(facing), 0)
	var base_height := float(idle_tex.get_height()) if idle_tex != null else 0.0
	_visual.position.y = -base_height * 0.5 + grid.tile_height * 0.5

func _apply_visual_offset() -> void:
	if _visual == null or grid == null:
		return
	# Base line comes from the facing idle sprite; each clip adds its
	# measured foot-line correction on top.
	var idle_tex := _visual.sprite_frames.get_frame_texture(_idle_anim_for(facing), 0) \
		if _visual.sprite_frames != null else null
	var base_height := float(idle_tex.get_height()) if idle_tex != null else 0.0
	_visual.position.y = -base_height * 0.5 + grid.tile_height * 0.5 \
		+ float(_anim_y_offsets.get(_visual.animation, 0.0))
