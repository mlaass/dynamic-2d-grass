# MIT License.
# Made by Dylearn

# Reads a TileMapLayer and spawns grass instances via MultiMesh.
# Primary configuration point for 2D grass — exports push values to the shader.

@tool
extends MultiMeshInstance2D

@export var tile_map : TileMapLayer
@export var density : int = 6
@export var grass_sprite_size : Vector2 = Vector2(16, 24)
@export var regenerate : bool = false:
  set(value):
    if value:
      _spawn_grass()
    regenerate = false

@export_group("Textures")
@export var grass_texture : Texture2D:
  set(value):
    grass_texture = value
    _sync_material()
@export var accent_texture_1 : Texture2D:
  set(value):
    accent_texture_1 = value
    _sync_material()
@export var accent_texture_2 : Texture2D:
  set(value):
    accent_texture_2 = value
    _sync_material()

@export_group("Colours")
@export var grass_colour : Color = Color(0.85, 1.0, 0.47):
  set(value):
    grass_colour = value
    _sync_material()
@export var patch_colour_2 : Color = Color(0.67, 0.88, 0.11):
  set(value):
    patch_colour_2 = value
    _sync_material()
@export var patch_colour_3 : Color = Color(0.41, 0.53, 0.18):
  set(value):
    patch_colour_3 = value
    _sync_material()
@export var accent_colour_1 : Color = Color(0.58, 0.79, 0.14):
  set(value):
    accent_colour_1 = value
    _sync_material()
@export var accent_colour_2 : Color = Color(0.31, 0.44, 0.06):
  set(value):
    accent_colour_2 = value
    _sync_material()

@export_group("Accents")
@export_range(0.0, 0.05, 0.0001) var accent_frequency_1 : float = 0.001:
  set(value):
    accent_frequency_1 = value
    _sync_material()
@export_range(0.0, 2.0, 0.001) var accent_scale_1 : float = 1.0:
  set(value):
    accent_scale_1 = value
    _sync_material()
@export_range(0.0, 1.0, 0.001) var accent_height_1 : float = 0.5:
  set(value):
    accent_height_1 = value
    _sync_material()
@export_range(0.0, 0.05, 0.0001) var accent_frequency_2 : float = 0.1:
  set(value):
    accent_frequency_2 = value
    _sync_material()
@export_range(0.0, 2.0, 0.001) var accent_scale_2 : float = 1.0:
  set(value):
    accent_scale_2 = value
    _sync_material()
@export_range(0.0, 1.0, 0.001) var accent_height_2 : float = 0.5:
  set(value):
    accent_height_2 = value
    _sync_material()

@export_group("Wind")
@export_range(0.0, 20.0, 0.1) var wind_sway_pixels : float = 5.0:
  set(value):
    wind_sway_pixels = value
    _sync_material()
@export var wind_direction : Vector2 = Vector2(0.0, 1.0):
  set(value):
    wind_direction = value
    _sync_material()
@export_range(0.0, 0.2, 0.001) var wind_speed : float = 0.025:
  set(value):
    wind_speed = value
    _sync_material()
@export_range(-0.15, 0.6, 0.001) var fake_perspective : float = 0.3:
  set(value):
    fake_perspective = value
    _sync_material()


static func _resolve_texture(tex : Texture2D) -> Array:
  if tex is AtlasTexture:
    var atlas_tex := tex as AtlasTexture
    var r : Rect2 = atlas_tex.region
    return [atlas_tex.atlas, Vector4(r.position.x, r.position.y, r.size.x, r.size.y)]
  elif tex != null:
    return [tex, Vector4(0, 0, 0, 0)]
  else:
    return [null, Vector4(0, 0, 0, 0)]


func _sync_material() -> void:
  var mat := material as ShaderMaterial
  if not mat or not is_node_ready():
    return

  # Textures — only override if assigned (keeps material defaults otherwise)
  if grass_texture:
    var resolved := _resolve_texture(grass_texture)
    mat.set_shader_parameter("albedo_texture", resolved[0])
    mat.set_shader_parameter("albedo_texture_region", resolved[1])

  if accent_texture_1:
    var resolved := _resolve_texture(accent_texture_1)
    mat.set_shader_parameter("accent_texture1", resolved[0])
    mat.set_shader_parameter("accent_texture1_region", resolved[1])

  if accent_texture_2:
    var resolved := _resolve_texture(accent_texture_2)
    mat.set_shader_parameter("accent_texture2", resolved[0])
    mat.set_shader_parameter("accent_texture2_region", resolved[1])

  # Colours
  mat.set_shader_parameter("albedo1", grass_colour)
  mat.set_shader_parameter("albedo2", patch_colour_2)
  mat.set_shader_parameter("albedo3", patch_colour_3)
  mat.set_shader_parameter("accent_albedo1", accent_colour_1)
  mat.set_shader_parameter("accent_albedo2", accent_colour_2)

  # Accents
  mat.set_shader_parameter("accent_frequency1", accent_frequency_1)
  mat.set_shader_parameter("accent_scale1", accent_scale_1)
  mat.set_shader_parameter("accent_height1", accent_height_1)
  mat.set_shader_parameter("accent_probability2", accent_frequency_2)
  mat.set_shader_parameter("accent_scale2", accent_scale_2)
  mat.set_shader_parameter("accent_height2", accent_height_2)

  # Wind
  mat.set_shader_parameter("wind_sway_pixels", wind_sway_pixels)
  mat.set_shader_parameter("wind_noise_direction", wind_direction)
  mat.set_shader_parameter("wind_noise_speed", wind_speed)
  mat.set_shader_parameter("fake_perspective_scale", fake_perspective)


func _ready() -> void:
  _sync_material()


func _get_configuration_warnings() -> PackedStringArray:
  var warnings := PackedStringArray()
  if not (material is ShaderMaterial):
    warnings.append("Assign a ShaderMaterial with Grass2D.gdshader to the material property.")
  return warnings


func _spawn_grass() -> void:
  if not tile_map:
    tile_map = get_parent().find_child("TileMapLayer", false) as TileMapLayer
  if not tile_map or not tile_map.tile_set:
    push_warning("GrassSpawner: No TileMapLayer found")
    return

  var tile_size : Vector2i = tile_map.tile_set.tile_size

  # Collect cells marked as grass via custom data
  var grass_cells : Array[Vector2i] = []
  for cell in tile_map.get_used_cells():
    var data := tile_map.get_cell_tile_data(cell)
    if data and data.get_custom_data("is_grass"):
      grass_cells.append(cell)

  var total : int = grass_cells.size() * density
  if total == 0:
    multimesh = null
    return

  var mm := MultiMesh.new()
  mm.transform_format = MultiMesh.TRANSFORM_2D
  mm.use_custom_data = true
  mm.instance_count = total
  mm.mesh = QuadMesh.new()
  mm.mesh.size = grass_sprite_size

  var idx : int = 0
  for cell in grass_cells:
    # Deterministic RNG per cell
    var rng := RandomNumberGenerator.new()
    rng.seed = hash(cell)

    var cell_center : Vector2 = tile_map.map_to_local(cell)
    var scatter_range : Vector2 = Vector2(tile_size) * 0.9

    for i in range(density):
      var offset := Vector2(
        rng.randf_range(-scatter_range.x / 2.0, scatter_range.x / 2.0),
        rng.randf_range(-scatter_range.y / 2.0, scatter_range.y / 2.0)
      )
      var pos : Vector2 = cell_center + offset
      pos.y -= grass_sprite_size.y / 2.0 # Bottom-anchor

      mm.set_instance_transform_2d(idx, Transform2D(0, pos))
      mm.set_instance_custom_data(idx, Color(rng.randf(), rng.randf(), 0.0, 0.0))
      idx += 1

  multimesh = mm
