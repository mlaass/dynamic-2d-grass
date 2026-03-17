# MIT License.
# Made by Dylearn

# Manages a SubViewport that renders displacement sprites for each
# GrassDisplacer2D node, then binds the resulting texture to the grass
# shader so blades shear away from nearby displacers.

@tool
extends Node

@export var grass_spawner: MultiMeshInstance2D
@export var viewport_resolution: Vector2i = Vector2i(512, 512)
@export var bounds_padding: float = 96.0

const DEFAULT_SPRITE_SIZE := 64

var _viewport: SubViewport
var _mirror_sprites: Array[Dictionary] = []
var _gradient_shader: Shader
var _default_texture: PlaceholderTexture2D
var _additive_mat: CanvasItemMaterial
var _bounds: Rect2


func _ready() -> void:
	if not grass_spawner:
		return
	if not "tile_map" in grass_spawner or not grass_spawner.tile_map:
		return

	_bounds = _compute_grass_bounds()
	if _bounds.size.x <= 0.0 or _bounds.size.y <= 0.0:
		return

	# Create SubViewport
	_viewport = SubViewport.new()
	_viewport.size = viewport_resolution
	_viewport.transparent_bg = true
	_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(_viewport)

	# Camera2D covering the grass bounds
	var cam := Camera2D.new()
	cam.position = _bounds.get_center()
	cam.zoom = Vector2(_viewport.size) / _bounds.size
	_viewport.add_child(cam)

	# Additive blend material for custom-texture displacers
	_additive_mat = CanvasItemMaterial.new()
	_additive_mat.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD

	# Default gradient shader + placeholder for displacers without a texture
	_gradient_shader = load("res://Shaders/2D/displacement_gradient.gdshader")
	_default_texture = PlaceholderTexture2D.new()
	_default_texture.size = Vector2(DEFAULT_SPRITE_SIZE, DEFAULT_SPRITE_SIZE)

	# Defer displacer discovery so all nodes have finished _ready() and joined groups
	await get_tree().process_frame

	# Create mirror sprites for all displacers
	for displacer in get_tree().get_nodes_in_group("grass_displacers"):
		_add_mirror(displacer)

	# Wait another frame so the viewport texture is valid
	await get_tree().process_frame

	# Bind viewport texture to grass material
	var mat := grass_spawner.material as ShaderMaterial
	if not mat:
		return
	mat.set_shader_parameter("terrain_data_texture", _viewport.get_texture())
	mat.set_shader_parameter("terrain_bounds", Vector4(
		_bounds.position.x, _bounds.position.y,
		_bounds.end.x, _bounds.end.y
	))
	mat.set_shader_parameter("displacement_enabled", true)


func _process(_delta: float) -> void:
	for entry in _mirror_sprites:
		var source: Node2D = entry.source
		var mirror: Sprite2D = entry.mirror
		if not is_instance_valid(source):
			continue
		mirror.position = source.global_position
		if "displacement_radius" in source:
			var radius: float = source.displacement_radius
			_apply_scale(mirror, entry.tex_size, radius)


func _add_mirror(displacer: Node) -> void:
	var mirror := Sprite2D.new()
	var tex: Texture2D = displacer.displacement_texture if "displacement_texture" in displacer else null
	var tex_size: float

	if tex:
		# Custom texture — use CanvasItemMaterial for additive blend
		mirror.texture = tex
		mirror.material = _additive_mat
		tex_size = tex.get_size().x
	else:
		# No texture — use procedural gradient shader (has blend_add built in)
		mirror.texture = _default_texture
		var gradient_mat := ShaderMaterial.new()
		gradient_mat.shader = _gradient_shader
		mirror.material = gradient_mat
		tex_size = DEFAULT_SPRITE_SIZE

	mirror.position = displacer.global_position
	var radius: float = displacer.displacement_radius if "displacement_radius" in displacer else 64.0
	_apply_scale(mirror, tex_size, radius)
	_viewport.add_child(mirror)
	_mirror_sprites.append({source = displacer, mirror = mirror, tex_size = tex_size})


func _apply_scale(mirror: Sprite2D, tex_size: float, radius: float) -> void:
	mirror.scale = Vector2.ONE * radius / (tex_size / 2.0)


func _compute_grass_bounds() -> Rect2:
	var tile_map: TileMapLayer = grass_spawner.tile_map
	var cells := tile_map.get_used_cells()
	if cells.is_empty():
		return Rect2()
	var min_pos := Vector2(INF, INF)
	var max_pos := Vector2(-INF, -INF)
	for cell in cells:
		var world_pos := tile_map.map_to_local(cell)
		min_pos = min_pos.min(world_pos)
		max_pos = max_pos.max(world_pos)
	var tile_size := Vector2(tile_map.tile_set.tile_size)
	min_pos -= tile_size / 2.0 + Vector2(bounds_padding, bounds_padding)
	max_pos += tile_size / 2.0 + Vector2(bounds_padding, bounds_padding)
	return Rect2(min_pos, max_pos - min_pos)
