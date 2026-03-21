# MIT License.
# Made by Dylearn

# Camera-adaptive grass system that streams grass chunks in/out based on
# camera visibility.  Replaces GrassSpawner for large tilemaps.
# At startup, scans the TileMapLayer and pre-computes per-chunk MultiMesh
# buffers.  At runtime, a pool of MultiMeshInstance2D nodes is assigned to
# visible chunks.  Teleport is handled synchronously — zero pop-in.

@tool
extends Node2D


# -- Chunk data ----------------------------------------------------------

class ChunkData:
  var grid_pos: Vector2i
  var grass_cells: Array[Vector2i] = []
  var instance_count: int = 0
  var buffer: PackedFloat32Array
  var assigned_pool_idx: int = -1
  var mask_mesh: ArrayMesh


# -- Exports: placement --------------------------------------------------

@export var tile_map: TileMapLayer
@export var density: int = 6
@export var grass_sprite_size: Vector2 = Vector2(16, 24)
@export var regenerate: bool = false:
  set(value):
    if value:
      _rebuild()
    regenerate = false

@export_group("Material")
@export var grass_material: ShaderMaterial:
  set(value):
    grass_material = value
    _shared_material = value
    _sync_material()

@export_group("Textures")
@export var grass_texture: Texture2D:
  set(value):
    grass_texture = value
    _sync_material()
@export var accent_texture_1: Texture2D:
  set(value):
    accent_texture_1 = value
    _sync_material()
@export var accent_texture_2: Texture2D:
  set(value):
    accent_texture_2 = value
    _sync_material()

@export_group("Colours")
@export var grass_colour: Color = Color(0.85, 1.0, 0.47):
  set(value):
    grass_colour = value
    _sync_material()
@export var patch_colour_2: Color = Color(0.67, 0.88, 0.11):
  set(value):
    patch_colour_2 = value
    _sync_material()
@export var patch_colour_3: Color = Color(0.41, 0.53, 0.18):
  set(value):
    patch_colour_3 = value
    _sync_material()
@export var accent_colour_1: Color = Color(0.58, 0.79, 0.14):
  set(value):
    accent_colour_1 = value
    _sync_material()
@export var accent_colour_2: Color = Color(0.31, 0.44, 0.06):
  set(value):
    accent_colour_2 = value
    _sync_material()

@export_group("Accents")
@export_range(0.0, 0.05, 0.0001) var accent_frequency_1: float = 0.001:
  set(value):
    accent_frequency_1 = value
    _sync_material()
@export_range(0.0, 2.0, 0.001) var accent_scale_1: float = 1.0:
  set(value):
    accent_scale_1 = value
    _sync_material()
@export_range(0.0, 1.0, 0.001) var accent_height_1: float = 0.5:
  set(value):
    accent_height_1 = value
    _sync_material()
@export_range(0.0, 0.05, 0.0001) var accent_frequency_2: float = 0.1:
  set(value):
    accent_frequency_2 = value
    _sync_material()
@export_range(0.0, 2.0, 0.001) var accent_scale_2: float = 1.0:
  set(value):
    accent_scale_2 = value
    _sync_material()
@export_range(0.0, 1.0, 0.001) var accent_height_2: float = 0.5:
  set(value):
    accent_height_2 = value
    _sync_material()

@export_group("Wind")
@export_range(0.0, 20.0, 0.1) var wind_sway_pixels: float = 5.0:
  set(value):
    wind_sway_pixels = value
    _sync_material()
@export var wind_direction: Vector2 = Vector2(0.0, 1.0):
  set(value):
    wind_direction = value
    _sync_material()
@export_range(0.0, 0.2, 0.001) var wind_speed: float = 0.025:
  set(value):
    wind_speed = value
    _sync_material()
@export_range(-0.15, 0.6, 0.001) var fake_perspective: float = 0.3:
  set(value):
    fake_perspective = value
    _sync_material()

@export_group("Chunking")
@export var chunk_size: int = 16
@export var buffer_pixels: float = 256.0
@export var min_zoom: float = 0.5
@export var pool_size_override: int = 0

@export var grass_nav_layer: int = 0

@export_group("Debug")
@export var debug_overlay: bool = false
@export var debug_show_terrain: bool = false


# -- Internal state -------------------------------------------------------

var _shared_material: ShaderMaterial
var _quad_mesh: QuadMesh
var _tile_size: Vector2i
var _chunk_map: Dictionary = {}           # Vector2i -> ChunkData
var _pool: Array[MultiMeshInstance2D] = []
var _pool_free: Array[int] = []
var _active_chunks: Dictionary = {}       # Vector2i -> pool_idx
var _last_chunk_range: Rect2i = Rect2i()
var _editor_preview_mmi: MultiMeshInstance2D = null
var _debug_terrain_sprite: Sprite2D

# Debug
var _debug_canvas: CanvasLayer
var _debug_control: Control
var _debug_timing: PackedFloat64Array
var _debug_timing_idx: int = 0
const _DEBUG_HISTORY := 600


# -- Texture helpers -------------------------------------------------------

static func _resolve_texture(tex: Texture2D) -> Array:
  if tex is AtlasTexture:
    var atlas_tex := tex as AtlasTexture
    var r: Rect2 = atlas_tex.region
    return [atlas_tex.atlas, Vector4(r.position.x, r.position.y, r.size.x, r.size.y)]
  elif tex != null:
    return [tex, Vector4(0, 0, 0, 0)]
  else:
    return [null, Vector4(0, 0, 0, 0)]


func _sync_material() -> void:
  if not _shared_material or not is_node_ready():
    return

  if grass_texture:
    var resolved := _resolve_texture(grass_texture)
    _shared_material.set_shader_parameter("albedo_texture", resolved[0])
    _shared_material.set_shader_parameter("albedo_texture_region", resolved[1])

  if accent_texture_1:
    var resolved := _resolve_texture(accent_texture_1)
    _shared_material.set_shader_parameter("accent_texture1", resolved[0])
    _shared_material.set_shader_parameter("accent_texture1_region", resolved[1])

  if accent_texture_2:
    var resolved := _resolve_texture(accent_texture_2)
    _shared_material.set_shader_parameter("accent_texture2", resolved[0])
    _shared_material.set_shader_parameter("accent_texture2_region", resolved[1])

  _shared_material.set_shader_parameter("albedo1", grass_colour)
  _shared_material.set_shader_parameter("albedo2", patch_colour_2)
  _shared_material.set_shader_parameter("albedo3", patch_colour_3)
  _shared_material.set_shader_parameter("accent_albedo1", accent_colour_1)
  _shared_material.set_shader_parameter("accent_albedo2", accent_colour_2)

  _shared_material.set_shader_parameter("accent_frequency1", accent_frequency_1)
  _shared_material.set_shader_parameter("accent_scale1", accent_scale_1)
  _shared_material.set_shader_parameter("accent_height1", accent_height_1)
  _shared_material.set_shader_parameter("accent_probability2", accent_frequency_2)
  _shared_material.set_shader_parameter("accent_scale2", accent_scale_2)
  _shared_material.set_shader_parameter("accent_height2", accent_height_2)

  _shared_material.set_shader_parameter("wind_sway_pixels", wind_sway_pixels)
  _shared_material.set_shader_parameter("wind_noise_direction", wind_direction)
  _shared_material.set_shader_parameter("wind_noise_speed", wind_speed)
  _shared_material.set_shader_parameter("fake_perspective_scale", fake_perspective)


# -- Lifecycle -------------------------------------------------------------

func _ready() -> void:
  _shared_material = grass_material
  _sync_material()
  _rebuild()
  if not Engine.is_editor_hint():
    _debug_terrain_sprite = Sprite2D.new()
    _debug_terrain_sprite.modulate = Color(1, 1, 1, 0.8)
    _debug_terrain_sprite.visible = false
    add_child(_debug_terrain_sprite)
    if debug_overlay:
      _create_debug_overlay()


func _process(_delta: float) -> void:
  if Engine.is_editor_hint():
    return
  var t0 := Time.get_ticks_usec()
  _update_visible_chunks()
  if debug_overlay and _debug_control:
    var elapsed := Time.get_ticks_usec() - t0
    _debug_timing[_debug_timing_idx] = float(elapsed)
    _debug_timing_idx = (_debug_timing_idx + 1) % _DEBUG_HISTORY
    _debug_control.queue_redraw()

  # Debug terrain texture overlay
  if debug_show_terrain and _shared_material and _debug_terrain_sprite:
    var tex_param = _shared_material.get_shader_parameter("terrain_data_texture")
    var bounds_param = _shared_material.get_shader_parameter("terrain_bounds")
    if tex_param is Texture2D and bounds_param is Vector4:
      for key in _active_chunks:
        _pool[_active_chunks[key]].visible = false
      var tex: Texture2D = tex_param
      var bounds: Vector4 = bounds_param
      _debug_terrain_sprite.texture = tex
      _debug_terrain_sprite.position = Vector2(
        (bounds.x + bounds.z) / 2.0, (bounds.y + bounds.w) / 2.0)
      var tex_size := Vector2(tex.get_size())
      _debug_terrain_sprite.scale = Vector2(
        (bounds.z - bounds.x) / tex_size.x,
        (bounds.w - bounds.y) / tex_size.y)
      _debug_terrain_sprite.visible = true
    else:
      _debug_terrain_sprite.visible = false
  elif _debug_terrain_sprite:
    _debug_terrain_sprite.visible = false


func _get_configuration_warnings() -> PackedStringArray:
  var warnings := PackedStringArray()
  if not grass_material:
    warnings.append("Assign a ShaderMaterial with Grass2D.gdshader to the grass_material property.")
  if not tile_map:
    warnings.append("Assign a TileMapLayer to the tile_map property.")
  return warnings


# -- Build / rebuild -------------------------------------------------------

func _rebuild() -> void:
  _cleanup()
  _chunk_map.clear()
  _active_chunks.clear()
  _last_chunk_range = Rect2i()

  if not tile_map:
    tile_map = get_parent().find_child("TileMapLayer", false) as TileMapLayer
  if not tile_map or not tile_map.tile_set:
    push_warning("GrassChunkManager2D: No TileMapLayer found")
    return

  _tile_size = tile_map.tile_set.tile_size
  _quad_mesh = QuadMesh.new()
  _quad_mesh.size = grass_sprite_size

  _build_chunk_map()
  _precompute_all_buffers()

  if Engine.is_editor_hint():
    _build_editor_preview()
  else:
    _create_pool()


func _build_chunk_map() -> void:
  for cell in tile_map.get_used_cells():
    var data := tile_map.get_cell_tile_data(cell)
    if data and data.get_custom_data("is_grass"):
      var cx := floori(float(cell.x) / chunk_size)
      var cy := floori(float(cell.y) / chunk_size)
      var key := Vector2i(cx, cy)
      if key not in _chunk_map:
        var cd := ChunkData.new()
        cd.grid_pos = key
        _chunk_map[key] = cd
      _chunk_map[key].grass_cells.append(cell)

  for key in _chunk_map:
    # Sort for deterministic iteration order
    _chunk_map[key].grass_cells.sort()
    _chunk_map[key].instance_count = _chunk_map[key].grass_cells.size() * density


func _precompute_all_buffers() -> void:
  for key in _chunk_map:
    _precompute_chunk_buffer(_chunk_map[key])
    _precompute_chunk_mask(_chunk_map[key])


func _precompute_chunk_buffer(chunk: ChunkData) -> void:
  var count := chunk.instance_count
  if count == 0:
    chunk.buffer = PackedFloat32Array()
    return

  var buf := PackedFloat32Array()
  buf.resize(count * 12)
  var scatter := Vector2(_tile_size) * 0.9
  var write_idx := 0

  for cell in chunk.grass_cells:
    var rng := RandomNumberGenerator.new()
    rng.seed = hash(cell)

    var cell_center := tile_map.map_to_local(cell)

    for i in range(density):
      var offset := Vector2(
        rng.randf_range(-scatter.x / 2.0, scatter.x / 2.0),
        rng.randf_range(-scatter.y / 2.0, scatter.y / 2.0)
      )
      var pos := cell_center + offset
      pos.y -= grass_sprite_size.y / 2.0

      # Transform2D column-major: [col0.x, col1.x, 0, origin.x,
      #                             col0.y, col1.y, 0, origin.y]
      buf[write_idx + 0] = 1.0
      buf[write_idx + 1] = 0.0
      buf[write_idx + 2] = 0.0
      buf[write_idx + 3] = pos.x
      buf[write_idx + 4] = 0.0
      buf[write_idx + 5] = 1.0
      buf[write_idx + 6] = 0.0
      buf[write_idx + 7] = pos.y
      # Custom data (accent seeds)
      buf[write_idx + 8]  = rng.randf()
      buf[write_idx + 9]  = rng.randf()
      buf[write_idx + 10] = 0.0
      buf[write_idx + 11] = 0.0
      write_idx += 12

  chunk.buffer = buf


func _precompute_chunk_mask(chunk: ChunkData) -> void:
  var verts := PackedVector2Array()
  var tile_size_v := Vector2(_tile_size)
  var half_tile := tile_size_v / 2.0

  for cell in chunk.grass_cells:
    var data := tile_map.get_cell_tile_data(cell)
    if not data:
      continue
    var world_pos := tile_map.map_to_local(cell)
    var nav_poly: NavigationPolygon = data.get_navigation_polygon(grass_nav_layer)

    if nav_poly and nav_poly.get_polygon_count() > 0:
      var nav_verts := nav_poly.get_vertices()
      for poly_idx in nav_poly.get_polygon_count():
        var indices := nav_poly.get_polygon(poly_idx)
        for idx_i in indices.size():
          var vi: int = indices[idx_i]
          verts.append((nav_verts[vi] + world_pos).round())
    else:
      # Snap full-tile quad vertices to integer pixel positions
      var tl := (world_pos + Vector2(-half_tile.x, -half_tile.y)).round()
      var tr := (world_pos + Vector2( half_tile.x, -half_tile.y)).round()
      var br := (world_pos + Vector2( half_tile.x,  half_tile.y)).round()
      var bl := (world_pos + Vector2(-half_tile.x,  half_tile.y)).round()
      verts.append_array(PackedVector2Array([tl, tr, br, tl, br, bl]))

  if verts.is_empty():
    return

  var arrays: Array = []
  arrays.resize(Mesh.ARRAY_MAX)
  var v3 := PackedVector3Array()
  v3.resize(verts.size())
  for i in verts.size():
    v3[i] = Vector3(verts[i].x, verts[i].y, 0.0)
  arrays[Mesh.ARRAY_VERTEX] = v3
  chunk.mask_mesh = ArrayMesh.new()
  chunk.mask_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)


# -- Pool management -------------------------------------------------------

func _compute_pool_size() -> int:
  if pool_size_override > 0:
    return pool_size_override
  var viewport_size := get_viewport().get_visible_rect().size
  var chunk_world := Vector2(_tile_size.x * chunk_size, _tile_size.y * chunk_size)
  var effective_size := viewport_size / min_zoom
  var chunks_x := ceili(effective_size.x / chunk_world.x) + 3
  var chunks_y := ceili(effective_size.y / chunk_world.y) + 3
  return chunks_x * chunks_y


func _create_pool() -> void:
  var pool_count := _compute_pool_size()
  var max_per_chunk := chunk_size * chunk_size * density

  for i in pool_count:
    var mmi := MultiMeshInstance2D.new()
    mmi.material = _shared_material
    var mm := MultiMesh.new()
    mm.transform_format = MultiMesh.TRANSFORM_2D
    mm.use_custom_data = true
    mm.mesh = _quad_mesh
    mm.instance_count = max_per_chunk
    mm.visible_instance_count = 0
    mmi.multimesh = mm
    mmi.visible = false
    add_child(mmi)
    _pool.append(mmi)
    _pool_free.append(i)


# -- Visibility ------------------------------------------------------------

func _get_active_zone() -> Rect2:
  var canvas_xform := get_viewport().get_canvas_transform()
  var viewport_size := get_viewport().get_visible_rect().size
  var inv := canvas_xform.affine_inverse()
  var top_left := inv * Vector2.ZERO
  var bottom_right := inv * viewport_size
  var view_rect := Rect2(top_left, bottom_right - top_left).abs()
  return view_rect.grow(buffer_pixels)


func _chunks_in_rect(rect: Rect2) -> Array[Vector2i]:
  var chunk_world_x := float(_tile_size.x * chunk_size)
  var chunk_world_y := float(_tile_size.y * chunk_size)
  var min_cx := floori(rect.position.x / chunk_world_x)
  var min_cy := floori(rect.position.y / chunk_world_y)
  var max_cx := floori(rect.end.x / chunk_world_x)
  var max_cy := floori(rect.end.y / chunk_world_y)
  var result: Array[Vector2i] = []
  for cx in range(min_cx, max_cx + 1):
    for cy in range(min_cy, max_cy + 1):
      var key := Vector2i(cx, cy)
      if key in _chunk_map:
        result.append(key)
  return result


func _update_visible_chunks() -> void:
  var active_zone := _get_active_zone()
  var chunk_world_x := float(_tile_size.x * chunk_size)
  var chunk_world_y := float(_tile_size.y * chunk_size)
  var min_cx := floori(active_zone.position.x / chunk_world_x)
  var min_cy := floori(active_zone.position.y / chunk_world_y)
  var max_cx := floori(active_zone.end.x / chunk_world_x)
  var max_cy := floori(active_zone.end.y / chunk_world_y)
  var current_range := Rect2i(
    Vector2i(min_cx, min_cy),
    Vector2i(max_cx - min_cx + 1, max_cy - min_cy + 1)
  )
  if current_range == _last_chunk_range:
    return
  _last_chunk_range = current_range

  var needed := _chunks_in_rect(active_zone)
  var needed_set: Dictionary = {}
  for key in needed:
    needed_set[key] = true

  # Deactivate chunks that left the zone
  for key in _active_chunks.keys():
    if key not in needed_set:
      _deactivate_chunk(key)

  # Activate chunks that entered the zone
  for key in needed:
    if key not in _active_chunks:
      _activate_chunk(key)


# -- Chunk activation / deactivation ---------------------------------------

func _activate_chunk(chunk_key: Vector2i) -> void:
  if _pool_free.is_empty():
    push_warning("GrassChunkManager2D: Pool exhausted (%d active)" % _active_chunks.size())
    return
  var pool_idx: int = _pool_free.pop_back()
  var chunk: ChunkData = _chunk_map[chunk_key]
  var mmi := _pool[pool_idx]
  var mm := mmi.multimesh
  mm.instance_count = chunk.instance_count
  mm.buffer = chunk.buffer
  mm.visible_instance_count = -1
  mmi.visible = true
  _active_chunks[chunk_key] = pool_idx
  chunk.assigned_pool_idx = pool_idx


func _deactivate_chunk(chunk_key: Vector2i) -> void:
  var pool_idx: int = _active_chunks[chunk_key]
  _pool[pool_idx].multimesh.visible_instance_count = 0
  _pool[pool_idx].visible = false
  _pool_free.append(pool_idx)
  _active_chunks.erase(chunk_key)
  _chunk_map[chunk_key].assigned_pool_idx = -1


func get_active_grass_cells() -> Array[Vector2i]:
  var cells: Array[Vector2i] = []
  for chunk_key in _active_chunks:
    var chunk: ChunkData = _chunk_map[chunk_key]
    cells.append_array(chunk.grass_cells)
  return cells


func get_chunk_map() -> Dictionary:
  return _chunk_map


func get_active_chunk_keys() -> Array:
  return _active_chunks.keys()


# -- Editor preview --------------------------------------------------------

func _build_editor_preview() -> void:
  _cleanup_editor_preview()

  var total := 0
  for key in _chunk_map:
    total += _chunk_map[key].instance_count
  if total == 0:
    return

  var full_buf := PackedFloat32Array()
  full_buf.resize(total * 12)
  var sorted_keys: Array = _chunk_map.keys()
  sorted_keys.sort()
  var offset := 0
  for key in sorted_keys:
    var chunk: ChunkData = _chunk_map[key]
    var src := chunk.buffer
    for j in src.size():
      full_buf[offset + j] = src[j]
    offset += src.size()

  _editor_preview_mmi = MultiMeshInstance2D.new()
  _editor_preview_mmi.material = _shared_material
  var mm := MultiMesh.new()
  mm.transform_format = MultiMesh.TRANSFORM_2D
  mm.use_custom_data = true
  mm.mesh = _quad_mesh
  mm.instance_count = total
  mm.buffer = full_buf
  _editor_preview_mmi.multimesh = mm
  add_child(_editor_preview_mmi)


# -- Debug overlay ---------------------------------------------------------

func _create_debug_overlay() -> void:
  _debug_timing = PackedFloat64Array()
  _debug_timing.resize(_DEBUG_HISTORY)
  _debug_timing.fill(0.0)
  _debug_timing_idx = 0

  _debug_canvas = CanvasLayer.new()
  _debug_canvas.layer = 100
  add_child(_debug_canvas)

  _debug_control = Control.new()
  _debug_control.set_anchors_preset(Control.PRESET_FULL_RECT)
  _debug_control.mouse_filter = Control.MOUSE_FILTER_IGNORE
  _debug_control.connect("draw", _debug_draw)
  _debug_canvas.add_child(_debug_control)


func _debug_log(msg: String) -> void:
  print("[GrassChunk] ", msg)


func _debug_draw() -> void:
  var font: Font = ThemeDB.fallback_font
  var font_size := 13
  var small_size := 11
  var line_h := 18
  var margin := Vector2(10, 10)

  # --- Compute stats ---
  var active_inst := 0
  for key in _active_chunks:
    active_inst += _chunk_map[key].instance_count
  var total_inst := 0
  for key in _chunk_map:
    total_inst += _chunk_map[key].instance_count

  var avg := 0.0
  var peak := 0.0
  for i in _DEBUG_HISTORY:
    avg += _debug_timing[i]
    peak = maxf(peak, _debug_timing[i])
  avg /= _DEBUG_HISTORY
  var current := _debug_timing[(_debug_timing_idx - 1 + _DEBUG_HISTORY) % _DEBUG_HISTORY]

  # --- Background ---
  var bg_h := line_h * 3 + 10 + 80 + 16
  _debug_control.draw_rect(Rect2(margin.x - 4, margin.y - 4, 340, bg_h),
    Color(0, 0, 0, 0.65))

  # --- Stats text ---
  var y := margin.y + line_h
  _debug_control.draw_string(font,
    Vector2(margin.x, y), "Chunks: %d active / %d total   Pool: %d free / %d" % [
      _active_chunks.size(), _chunk_map.size(),
      _pool_free.size(), _pool.size()],
    HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, Color(0.9, 0.9, 0.9))
  y += line_h
  _debug_control.draw_string(font,
    Vector2(margin.x, y), "Instances: %s active / %s total" % [
      _fmt_num(active_inst), _fmt_num(total_inst)],
    HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, Color(0.9, 0.9, 0.9))
  y += line_h
  _debug_control.draw_string(font,
    Vector2(margin.x, y), "Update: %d us   Avg: %d us   Peak: %d us" % [
      int(current), int(avg), int(peak)],
    HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, Color(0.9, 0.9, 0.9))
  y += line_h + 6

  # --- Bar graph ---
  var graph_x := margin.x
  var graph_w := 320.0
  var graph_h := 60.0
  var bar_w := graph_w / _DEBUG_HISTORY
  var max_usec := 500.0

  _debug_control.draw_string(font,
    Vector2(graph_x, y), "Frame cost (us)",
    HORIZONTAL_ALIGNMENT_LEFT, -1, small_size, Color(0.7, 0.7, 0.7))
  y += small_size + 4

  var graph_y := y
  # Background
  _debug_control.draw_rect(Rect2(graph_x, graph_y, graph_w, graph_h),
    Color(0.1, 0.1, 0.1, 0.8))
  # Reference lines
  var _ref_levels: Array[float] = [100.0, 300.0]
  for ref_val in _ref_levels:
    var ref_y: float = graph_y + graph_h - (ref_val / max_usec) * graph_h
    _debug_control.draw_line(
      Vector2(graph_x, ref_y), Vector2(graph_x + graph_w, ref_y),
      Color(0.4, 0.4, 0.4, 0.5), 1.0)
    _debug_control.draw_string(font,
      Vector2(graph_x + graph_w + 2, ref_y + 4), "%d" % int(ref_val),
      HORIZONTAL_ALIGNMENT_LEFT, -1, 9, Color(0.5, 0.5, 0.5))

  # Bars
  for i in _DEBUG_HISTORY:
    var idx := (_debug_timing_idx + i) % _DEBUG_HISTORY
    var val: float = _debug_timing[idx]
    if val <= 0.0:
      continue
    var h := clampf(val / max_usec, 0.0, 1.0) * graph_h
    var bx := graph_x + i * bar_w
    var color: Color
    if val < 100.0:
      color = Color(0.3, 0.8, 0.3)
    elif val < 300.0:
      color = Color(0.9, 0.8, 0.2)
    else:
      color = Color(0.9, 0.3, 0.2)
    _debug_control.draw_rect(Rect2(bx, graph_y + graph_h - h, maxf(bar_w - 0.5, 1.0), h), color)


static func _fmt_num(n: int) -> String:
  var s := str(n)
  var result := ""
  var count := 0
  for i in range(s.length() - 1, -1, -1):
    if count > 0 and count % 3 == 0:
      result = "," + result
    result = s[i] + result
    count += 1
  return result


# -- Cleanup ---------------------------------------------------------------

func _cleanup() -> void:
  _cleanup_editor_preview()
  _cleanup_debug_overlay()
  for mmi in _pool:
    if is_instance_valid(mmi):
      mmi.queue_free()
  _pool.clear()
  _pool_free.clear()
  _active_chunks.clear()


func _cleanup_editor_preview() -> void:
  if _editor_preview_mmi and is_instance_valid(_editor_preview_mmi):
    _editor_preview_mmi.queue_free()
    _editor_preview_mmi = null


func _cleanup_debug_overlay() -> void:
  if _debug_canvas and is_instance_valid(_debug_canvas):
    _debug_canvas.queue_free()
    _debug_canvas = null
    _debug_control = null
