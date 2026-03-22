# MIT License.
# Made by Dylearn

# Full-screen cloud shadow overlay.  Place as a ColorRect inside a
# CanvasLayer and assign the cloud overlay ShaderMaterial.  Syncs
# camera position, zoom, and terrain data each frame.

@tool
extends ColorRect

@export var camera: Camera2D
@export var effect_manager: Node


func _ready() -> void:
  mouse_filter = Control.MOUSE_FILTER_IGNORE
  set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)


func _process(_delta: float) -> void:
  var mat: ShaderMaterial = material as ShaderMaterial
  if not camera or not mat:
    return

  mat.set_shader_parameter("camera_position", camera.global_position)
  mat.set_shader_parameter("camera_zoom", camera.zoom)
  mat.set_shader_parameter("viewport_size", get_viewport().get_visible_rect().size)

  if effect_manager and "get_terrain_texture" in effect_manager:
    var tex: Variant = effect_manager.get_terrain_texture()
    if tex:
      mat.set_shader_parameter("terrain_data_texture", tex)

  if effect_manager and "chunk_manager" in effect_manager:
    var cm: Node = effect_manager.chunk_manager
    if cm and "grass_material" in cm and cm.grass_material:
      var bounds: Variant = cm.grass_material.get_shader_parameter("terrain_bounds")
      if bounds:
        mat.set_shader_parameter("terrain_bounds", bounds)
