# MIT License.
# Made by Jomoho Games, based on original work by Dylearn

# Manages a SubViewport that renders effector sprites and grass coverage
# masks.  Effectors use a channel-routing shader (blend_disabled +
# screen_texture) for independent per-channel writes (R/G/B/A).
# Coverage masks use blend_premul_alpha to write G=1 without touching A.
# BackBufferCopy nodes between effectors ensure correct accumulation.
# The viewport follows the game camera.

@tool
extends Node

@export var chunk_manager: Node
@export var camera: Camera2D
@export_range(0.25, 1.0, 0.25) var viewport_scale: float = 1.0
@export var displacement_buffer: float = 128.0

var _viewport: SubViewport
var _internal_cam: Camera2D
var _mirror_sprites: Array[Dictionary] = []
var _channel_shader: Shader
var _mask_shader: Shader
var _grass_material: ShaderMaterial
var _viewport_resolution: Vector2i
var _fixed_world_size: Vector2

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
  _fixed_world_size = screen_size + Vector2(displacement_buffer * 2.0, displacement_buffer * 2.0)

  # Create SubViewport
  _viewport = SubViewport.new()
  _viewport.size = _viewport_resolution
  _viewport.transparent_bg = true
  _viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
  add_child(_viewport)

  # Camera2D — positioned dynamically in _process()
  _internal_cam = Camera2D.new()
  _viewport.add_child(_internal_cam)

  # Create mask MeshInstance2D pool (renders BEFORE effector sprites)
  _create_mask_pool()

  # Load channel-routing and mask shaders
  _channel_shader = load("res://addons/dynamic_2d_grass/shaders/effector_channel.gdshader")
  _mask_shader = load("res://addons/dynamic_2d_grass/shaders/mask_coverage.gdshader")

  # Defer effector discovery so all nodes have finished _ready() and joined groups
  await get_tree().process_frame

  # Create mirror sprites for all effectors
  for effector in get_tree().get_nodes_in_group("grass_effectors"):
    _add_mirror(effector)

  # Listen for effectors added at runtime (e.g. explosion craters)
  get_tree().node_added.connect(_on_node_added)

  # Wait another frame so the viewport texture is valid
  await get_tree().process_frame

  # Bind viewport texture to grass material
  _grass_material.set_shader_parameter("terrain_data_texture", _viewport.get_texture())
  _grass_material.set_shader_parameter("displacement_enabled", true)


func get_terrain_texture() -> ViewportTexture:
  if _viewport:
    return _viewport.get_texture()
  return null


func _process(_delta: float) -> void:
  if not camera or not _internal_cam or not _grass_material:
    return

  # Clean up mirrors whose source nodes have been freed
  for i in range(_mirror_sprites.size() - 1, -1, -1):
    if not is_instance_valid(_mirror_sprites[i].source):
      _mirror_sprites[i].mirror.queue_free()
      _mirror_sprites[i].bbc.queue_free()
      _mirror_sprites.remove_at(i)

  # Fixed world coverage — independent of game zoom to prevent texel grid flicker
  var world_size := _fixed_world_size

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

  # Sync mirror sprite transforms
  for entry in _mirror_sprites:
    var source: Node2D = entry.source
    var mirror: Sprite2D = entry.mirror
    mirror.global_transform = source.global_transform
    mirror.modulate = source.modulate
    mirror.offset = source.offset
    mirror.flip_h = source.flip_h
    mirror.flip_v = source.flip_v


# -- Effector sprites ------------------------------------------------------

func _add_mirror(effector: Node) -> void:
  var tex: Texture2D = effector.texture if "texture" in effector else null
  if not tex:
    push_warning("GrassEffector2D has no texture: ", effector.name)
    return

  var source_ch: int = effector.source_channel if "source_channel" in effector else 0
  var target_ch: int = effector.target_channel if "target_channel" in effector else 0
  var blend_op: int = effector.blend_operation if "blend_operation" in effector else 0

  # BackBufferCopy so this effector reads the up-to-date framebuffer
  var bbc := BackBufferCopy.new()
  bbc.copy_mode = BackBufferCopy.COPY_MODE_VIEWPORT
  _viewport.add_child(bbc)

  # Mirror sprite with channel-routing shader
  var mirror := Sprite2D.new()
  mirror.texture = tex
  var mat := ShaderMaterial.new()
  mat.shader = _channel_shader
  mat.set_shader_parameter("source_channel", source_ch)
  mat.set_shader_parameter("target_channel", target_ch)
  mat.set_shader_parameter("subtract_mode", blend_op == 1)
  mirror.material = mat
  mirror.centered = effector.centered
  mirror.offset = effector.offset
  mirror.flip_h = effector.flip_h
  mirror.flip_v = effector.flip_v
  mirror.global_transform = effector.global_transform
  _viewport.add_child(mirror)

  _mirror_sprites.append({source = effector, mirror = mirror, bbc = bbc})


func _on_node_added(node: Node) -> void:
  # Defer so _ready() has run and the node has joined its group
  (func() -> void:
    if not is_instance_valid(node) or not node.is_in_group("grass_effectors"):
      return
    # Skip if already mirrored
    for entry in _mirror_sprites:
      if entry.source == node:
        return
    _add_mirror(node)
  ).call_deferred()


# -- Grass mask pool -------------------------------------------------------

func _create_mask_pool() -> void:
  if not chunk_manager or not "get_chunk_map" in chunk_manager:
    return
  var mask_mat := ShaderMaterial.new()
  mask_mat.shader = load("res://addons/dynamic_2d_grass/shaders/mask_coverage.gdshader")
  # Pool size matches the grass chunk pool
  var pool_count: int = chunk_manager.get_chunk_map().size()
  for i in pool_count:
    var mi := MeshInstance2D.new()
    mi.material = mask_mat
    mi.visible = false
    _viewport.add_child(mi)
    _mask_pool.append(mi)
    _mask_pool_free.append(i)

  # BackBufferCopy after all masks, before any effector sprites
  var bbc := BackBufferCopy.new()
  bbc.copy_mode = BackBufferCopy.COPY_MODE_VIEWPORT
  _viewport.add_child(bbc)


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
