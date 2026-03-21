# MIT License.
# Made by Dylearn

# Manages a SubViewport that renders displacement sprites and grass coverage
# masks. Displacement sprites write to the R channel (character push).
# Grass mask meshes write to the G channel (coverage area).
# The viewport follows the game camera.

@tool
extends Node

@export var chunk_manager: Node
@export var camera: Camera2D
@export_range(0.25, 1.0, 0.25) var viewport_scale: float = 1.0
@export var displacement_buffer: float = 128.0
@export var grass_nav_layer: int = 0

const DEFAULT_SPRITE_SIZE := 64

var _viewport: SubViewport
var _internal_cam: Camera2D
var _mirror_sprites: Array[Dictionary] = []
var _gradient_shader: Shader
var _default_texture: PlaceholderTexture2D
var _additive_mat: CanvasItemMaterial
var _grass_material: ShaderMaterial
var _viewport_resolution: Vector2i

# Mask pool — MeshInstance2D nodes in the SubViewport for green coverage meshes
var _mask_pool: Array[MeshInstance2D] = []
var _mask_pool_free: Array[int] = []
var _mask_active: Dictionary = {}  # chunk_key -> pool_idx


func _ready() -> void:
  if not chunk_manager or not "grass_material" in chunk_manager:
    return
  _grass_material = chunk_manager.grass_material
  if not _grass_material:
    return
  if not camera:
    return

  # Compute viewport resolution from screen size (matches screen pixels to avoid sub-pixel flicker)
  var screen_size := get_viewport().get_visible_rect().size
  _viewport_resolution = Vector2i(Vector2(screen_size) * viewport_scale)

  # Create SubViewport
  _viewport = SubViewport.new()
  _viewport.size = _viewport_resolution
  _viewport.transparent_bg = true
  _viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
  add_child(_viewport)

  # Camera2D — positioned dynamically in _process()
  _internal_cam = Camera2D.new()
  _viewport.add_child(_internal_cam)

  # Create mask MeshInstance2D pool (renders BEFORE displacement sprites)
  _create_mask_pool()

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
  _grass_material.set_shader_parameter("terrain_data_texture", _viewport.get_texture())
  _grass_material.set_shader_parameter("displacement_enabled", true)


func _process(_delta: float) -> void:
  if not camera or not _internal_cam or not _grass_material:
    return

  # Compute world-space coverage for the displacement viewport
  var viewport_size := get_viewport().get_visible_rect().size
  var world_size := viewport_size / camera.zoom + Vector2(displacement_buffer * 2.0, displacement_buffer * 2.0)

  # Snap SubViewport camera to texel-aligned position (prevents sub-texel rasterization flicker)
  var texel_size := world_size / Vector2(_viewport_resolution)
  var snapped_pos := (camera.global_position / texel_size).round() * texel_size
  _internal_cam.position = snapped_pos
  _internal_cam.zoom = Vector2(_viewport_resolution) / world_size

  # Update terrain_bounds from snapped position (shader UVs must match rasterized mask)
  var half_world := world_size / 2.0
  var bounds_min := snapped_pos - half_world
  var bounds_max := snapped_pos + half_world
  _grass_material.set_shader_parameter("terrain_bounds", Vector4(
    bounds_min.x, bounds_min.y, bounds_max.x, bounds_max.y
  ))

  # Update mask chunks to match active grass chunks
  _update_mask_chunks()

  # Sync mirror sprite positions
  for entry in _mirror_sprites:
    var source: Node2D = entry.source
    var mirror: Sprite2D = entry.mirror
    if not is_instance_valid(source):
      continue
    mirror.position = source.global_position
    if "displacement_radius" in source:
      var radius: float = source.displacement_radius
      _apply_scale(mirror, entry.tex_size, radius)


# -- Displacement sprites --------------------------------------------------

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


# -- Grass mask pool -------------------------------------------------------

func _create_mask_pool() -> void:
  if not chunk_manager or not "get_chunk_map" in chunk_manager:
    return
  # Pool size matches the grass chunk pool
  var pool_count: int = chunk_manager.get_chunk_map().size()
  for i in pool_count:
    var mi := MeshInstance2D.new()
    mi.modulate = Color(0, 1, 0, 1)
    mi.visible = false
    _viewport.add_child(mi)
    _mask_pool.append(mi)
    _mask_pool_free.append(i)


func _update_mask_chunks() -> void:
  if not chunk_manager or not "get_active_chunk_keys" in chunk_manager:
    return

  # Build set of currently active grass chunk keys
  var current_set: Dictionary = {}
  for key in chunk_manager.get_active_chunk_keys():
    current_set[key] = true

  # Deactivate mask chunks no longer active
  for key in _mask_active.keys():
    if key not in current_set:
      _deactivate_mask_chunk(key)

  # Activate new mask chunks
  for key in current_set:
    if key not in _mask_active:
      _activate_mask_chunk(key)


func _activate_mask_chunk(chunk_key: Vector2i) -> void:
  if _mask_pool_free.is_empty():
    return
  var chunk_map: Dictionary = chunk_manager.get_chunk_map()
  if chunk_key not in chunk_map:
    return
  var chunk: Object = chunk_map[chunk_key]
  if not chunk.mask_mesh:
    return
  var pool_idx: int = _mask_pool_free.pop_back()
  var mi := _mask_pool[pool_idx]
  mi.mesh = chunk.mask_mesh
  mi.visible = true
  _mask_active[chunk_key] = pool_idx


func _deactivate_mask_chunk(chunk_key: Vector2i) -> void:
  var pool_idx: int = _mask_active[chunk_key]
  _mask_pool[pool_idx].visible = false
  _mask_pool_free.append(pool_idx)
  _mask_active.erase(chunk_key)
