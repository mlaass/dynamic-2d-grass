# PRD: Partial Grass Coverage via Navigation Polygons

## Context

The 2D grass system (see `PRD-Camera-Adaptive-Grass.md`) currently spawns grass on a tile-by-tile basis: a tile either has grass (`is_grass=true`) or doesn't. This creates hard edges at tile boundaries — paths, cliff edges, shorelines, and other terrain transitions can't have grass that partially covers a tile.

We need per-tile partial grass coverage. The approach: repurpose a TileSet **navigation layer** as a "grass coverage polygon" that defines where grass grows within each tile. The polygon data is rendered into the terrain data texture's **G channel** (reserved for this purpose since `PRD-Terrain-Data-Texture.md`), and the shader scales blade vertices based on G value.

## Scope

**v1 (this PRD):** Navigation polygon grass masks rendered into G channel, blade scale controlled by shader.

**Out of scope:** Smooth density gradients (G is binary — inside/outside polygon), foliage type selection (B channel), procedural edge feathering.

---

## Architecture Overview

```
TileSet
├── Custom Data Layer 0: "is_grass" (bool)
├── Navigation Layer 0: standard pathfinding (if any)
└── Navigation Layer 0: "grass coverage" polygons     # NEW — defines where grass grows

Demo2D (Node2D)
├── Camera2D
├── TileMapLayer (tile data includes navigation polygons)
├── GrassChunkManager2D (Node2D)
│   └── pool of MultiMeshInstance2D
│
├── DisplacementManager2D (Node)                       # MODIFIED
│   └── SubViewport
│       ├── Camera2D (tracks game camera)
│       ├── GrassMaskControl (Control)                 # NEW — draws nav polygons as green fills
│       └── [mirror sprites for displacement — red, additive]
│
└── Character
    └── GrassDisplacer2D
```

### Data Flow

1. At startup, `DisplacementManager2D` reads navigation polygons from the TileMapLayer for all grass tiles
2. Each frame, `GrassMaskControl._draw()` renders the visible navigation polygons as green filled triangles into the SubViewport
3. Displacement sprites render on top with additive blend (red channel only)
4. Result texture: **R = displacement strength, G = grass coverage**
5. `Grass2D.gdshader` samples G at each blade's world position and scales `VERTEX` accordingly

### Why This Works with the Existing SubViewport

The displacement SubViewport renders per-frame with `transparent_bg = true` (clears to RGBA 0,0,0,0):

1. **GrassMaskControl** draws green filled polygons → pixels become **(0, 1, 0, 1)** inside polygons
2. **Displacement sprites** draw red gradients with `blend_add` → pixels become **(R, 1, 0, 1)**

Displacement sprites use additive blending and write **only to R** (green component = 0 in the sprite textures). The G channel from the grass mask is preserved. Single texture, single UV system — no second viewport needed.

---

## TileSet Configuration

### Adding the Navigation Layer

Add a **Navigation Layer** to the TileSet dedicated to grass coverage. The layer index is configurable (default 0). If the project also uses navigation for pathfinding, use separate layer indices.

The layer index is configurable via an export on DisplacementManager2D:

```gdscript
@export var grass_nav_layer: int = 0  # Navigation layer index used for grass coverage
```

### Per-Tile Polygon Editing

In the TileSet editor:
1. Select a grass tile
2. Switch to the Navigation tab, select the grass coverage layer
3. Draw a polygon defining where grass grows within that tile
4. The polygon uses the same editor UI as standard navigation polygons — click to add vertices, drag to adjust

### Default Full-Tile Coverage

Tiles with `is_grass=true` but **no navigation polygon** on the grass coverage layer default to **full-tile coverage** — the runtime generates a full-tile rectangle automatically. This means existing tilemaps work unchanged; partial coverage is opt-in per tile.

---

## Rendering into G Channel

### Chunked ArrayMesh Approach

Each chunk gets one pre-built `ArrayMesh` containing all grass coverage triangles for its cells — merged into a single surface. A pool of `MeshInstance2D` nodes inside the SubViewport activates/deactivates alongside the grass chunks. This gives ~16 draw calls total (one per active chunk).

### Mesh Pre-Computation

At startup, `GrassChunkManager2D` pre-builds a mask `ArrayMesh` per chunk alongside the grass MultiMesh buffer:

```gdscript
func _precompute_chunk_mask(chunk: ChunkData) -> void:
    var verts := PackedVector2Array()
    var tile_size := Vector2(_tile_size)
    var half_tile := tile_size / 2.0

    for cell in chunk.grass_cells:
        var data := tile_map.get_cell_tile_data(cell)
        if not data:
            continue
        var world_pos := tile_map.map_to_local(cell)
        var nav_poly: NavigationPolygon = data.get_navigation_polygon(grass_nav_layer)

        if nav_poly and nav_poly.get_polygon_count() > 0:
            # Triangulated nav polygon — append each triangle's 3 vertices
            var nav_verts := nav_poly.get_vertices()
            for poly_idx in nav_poly.get_polygon_count():
                var indices := nav_poly.get_polygon(poly_idx)
                for idx_i in indices.size():
                    var vi: int = indices[idx_i]
                    verts.append(nav_verts[vi] + world_pos)
        else:
            # Full-tile quad → 2 triangles
            var tl := world_pos + Vector2(-half_tile.x, -half_tile.y)
            var tr := world_pos + Vector2( half_tile.x, -half_tile.y)
            var br := world_pos + Vector2( half_tile.x,  half_tile.y)
            var bl := world_pos + Vector2(-half_tile.x,  half_tile.y)
            verts.append_array(PackedVector2Array([tl, tr, br, tl, br, bl]))

    if verts.is_empty():
        return

    # Build ArrayMesh with one triangle surface
    var arrays := []
    arrays.resize(Mesh.ARRAY_MAX)
    # Convert 2D vertices to 3D (z=0) for ArrayMesh
    var v3 := PackedVector3Array()
    v3.resize(verts.size())
    for i in verts.size():
        v3[i] = Vector3(verts[i].x, verts[i].y, 0.0)
    arrays[Mesh.ARRAY_VERTEX] = v3
    chunk.mask_mesh = ArrayMesh.new()
    chunk.mask_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
```

### Pool Management

`DisplacementManager2D` maintains a pool of `MeshInstance2D` nodes inside the SubViewport. When a grass chunk activates, the corresponding mask `MeshInstance2D` is assigned the chunk's pre-built `ArrayMesh`. When it deactivates, the `MeshInstance2D` is hidden and returned to the pool.

The mask pool mirrors the grass pool: same chunk keys, same activation/deactivation timing. `DisplacementManager2D` detects chunk changes by comparing active chunk keys each frame.

```gdscript
# Pool of MeshInstance2D in the SubViewport
var _mask_pool: Array[MeshInstance2D] = []
var _mask_pool_free: Array[int] = []
var _mask_active: Dictionary = {}  # chunk_key -> pool_idx
```

Each `MeshInstance2D` in the pool has:
- Green modulate: `Color(0, 1, 0, 1)`
- No material needed (just flat green vertex color via modulate)
- Added as child of the SubViewport, before displacement sprites in tree order

### Activation / Deactivation

```gdscript
func _activate_mask_chunk(chunk_key: Vector2i) -> void:
    var chunk = chunk_manager.get_chunk_map()[chunk_key]
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
```

### Chunk Change Detection

In `_process()`, compare active grass chunks against active mask chunks:

```gdscript
var current_keys := chunk_manager.get_active_chunk_keys()
# Deactivate mask chunks no longer active
for key in _mask_active.keys():
    if key not in current_keys:
        _deactivate_mask_chunk(key)
# Activate new mask chunks
for key in current_keys:
    if key not in _mask_active:
        _activate_mask_chunk(key)
```

---

## Shader Changes

### Grass2D.gdshader — Vertex Shader

Inside the existing `if (displacement_enabled)` block, after the R channel displacement code (line 193) and still within the terrain UV bounds check, add G channel sampling:

```glsl
// Inside the existing displacement block, after the push_dir displacement code:

// G channel: grass coverage mask
float grass_density = texture(terrain_data_texture, terrain_uv).g;
VERTEX *= grass_density;  // Scale entire blade — 0 = invisible, 1 = full size
```

Add an `else` clause to the existing bounds check to hide blades outside the terrain data texture coverage:

```glsl
} else {
    // Outside terrain bounds — no coverage data available, hide blade
    VERTEX *= 0.0;
}
```

This reuses the already-computed `terrain_uv` from the displacement block — no duplicated UV computation.

**Key design choice: blade scale only.** All grass instances still spawn (chunk buffers unchanged). The G channel controls vertex scale:
- `G = 0.0` → blade collapsed to a point (invisible)
- `G = 1.0` → blade at full size
- Intermediate values produce smooth size transitions at polygon edges (due to texture filtering)

This keeps the chunk system completely unchanged — no buffer recomputation when the mask changes. The mask is purely a real-time shader effect.

### Why Not Discard in Fragment?

Scaling `VERTEX` to zero in the vertex shader is more efficient than `discard` in fragment:
- No fragment shader execution for invisible blades
- No alpha testing overhead
- Smooth transitions via texture filtering on the G channel boundary

---

## DisplacementManager2D Changes

### New Exports

```gdscript
@export var grass_nav_layer: int = 0  # Navigation layer index for grass coverage polygons
```

### Modified `_ready()`

After creating the SubViewport and internal camera, create the `GrassMaskControl` **before** the displacement mirror sprites:

```gdscript
# Create grass mask control (renders nav polygons as green fills)
_create_grass_mask()

# Then create displacement mirror sprites (render red gradients with additive blend)
for displacer in get_tree().get_nodes_in_group("grass_displacers"):
    _add_mirror(displacer)
```

### Modified `_process()`

Add `queue_redraw()` for the mask control (alongside existing mirror sync):

```gdscript
if _mask_control:
    _mask_control.queue_redraw()
```

---

## Navigation Polygon Coordinate Space

Navigation polygon vertices from `TileData.get_navigation_polygon()` are in **tile-local space** — relative to the tile's origin (center). To convert to world space for rendering:

```gdscript
var world_vertex := nav_poly_vertex + tile_map.map_to_local(cell)
```

The SubViewport's Camera2D maps world coordinates to viewport pixels, so world-space vertices render at the correct positions automatically.

---

## Editor Workflow

### Setting Up Partial Grass

1. Open the TileSet in the inspector
2. Add a Navigation Layer (if not already present)
3. For each tile that needs partial grass:
   - Select the tile in the TileSet atlas
   - Switch to the Navigation panel
   - Select the grass coverage navigation layer
   - Draw a polygon defining the grass area
4. Tiles without a polygon default to full coverage — no action needed for fully-grassed tiles

### Visual Feedback

In the editor, the navigation polygon is visible as an overlay on the tile. This gives immediate visual feedback about grass coverage while editing the TileSet.

At runtime with `debug_overlay` enabled on `GrassChunkManager2D`, the grass mask polygons are implicitly visible through the grass density changes.

---

## Performance

### Rendering Cost

- **Draw calls**: ~16 per frame (one `MeshInstance2D` per active chunk) — same as the grass system
- **Triangles**: ~200-300 total across all chunks (2 per full-tile cell, more for nav polygon cells)
- **Pre-computed**: All `ArrayMesh` geometry is built once at startup; activation is just assigning a mesh reference
- **No per-frame computation**: No polygon drawing, no TileData lookups, no array allocation at runtime
- **Already in SubViewport**: No additional render passes; the displacement viewport already re-renders every frame

### Shader Cost

- **One additional texture sample** per blade: `texture(terrain_data_texture, terrain_uv).g`
- Already sampling R for displacement — the G read is essentially free (same texel fetch, different swizzle)
- `VERTEX *= grass_density` is one multiply — negligible

---

## Edge Cases

### Tiles with `is_grass=false`

These tiles don't generate grass instances in `GrassChunkManager2D`, so no mask polygon is drawn. The G channel stays 0 for these areas, but no blades exist to sample it.

### Tiles at Map Edges

The SubViewport's Camera2D covers the viewport + `displacement_buffer` padding. Tiles partially within this area still have their polygons drawn. Tiles entirely outside are skipped by the visible cell iteration.

### Smooth Transitions at Polygon Edges

The G channel boundary between inside (1.0) and outside (0.0) is razor-sharp at the mesh edge. However, the SubViewport texture is sampled with bilinear filtering, so blades near the polygon edge will see intermediate G values (0.0–1.0), producing a natural fade-out. The viewport resolution (512×512) controls how many world pixels this transition spans.

### Multiple Polygons per Tile

Navigation polygons support multiple outlines and are triangulated via `make_polygons_from_outlines()`. Complex shapes (holes, concave polygons) are handled automatically by Godot's polygon triangulation.

### Displacement + Density Interaction

A blade at the edge of a displacement zone AND at the edge of a grass coverage polygon receives both effects: it scales down from G channel AND shears from R channel. This produces natural-looking results — partially-hidden blades that also lean away from displacers.

### Displacement Texture Convention

Displacement textures (both `displace.png` and the procedural `displacement_gradient.gdshader`) must only write to the **R channel** (G=0, B=0). The existing textures already follow this. Custom displacement textures with non-zero green would corrupt the grass mask by adding to the G channel via additive blend.

### `displacement_enabled` Guards Both Features

The `displacement_enabled` shader uniform controls both displacement (R channel) and grass masking (G channel). Disabling it disables both. This is intentional — the terrain data texture is an all-or-nothing system.

---

## Debug Terrain Overlay

A world-space debug toggle that shows the terrain data texture mapped onto the world, replacing grass rendering. Useful for verifying mask coverage and displacement fields.

### Configuration

```gdscript
# On GrassChunkManager2D:
@export_group("Debug")
@export var debug_show_terrain: bool = false
```

### Behaviour

When `debug_show_terrain` is enabled:
1. All grass pool `MultiMeshInstance2D` nodes are hidden
2. A `Sprite2D` renders the terrain data viewport texture mapped to world space using `terrain_bounds`
3. The sprite is semi-transparent (`modulate.a = 0.8`) so the tilemap is visible underneath
4. R channel shows as red (displacement), G channel shows as green (grass coverage)

When disabled, grass rendering resumes normally.

### Implementation

`GrassChunkManager2D` creates a `Sprite2D` at startup (hidden by default). In `_process()`, when the toggle is active:

```gdscript
if debug_show_terrain and _shared_material:
    # Hide grass
    for key in _active_chunks:
        _pool[_active_chunks[key]].visible = false

    # Update terrain debug sprite from shader parameters
    var tex: Texture2D = _shared_material.get_shader_parameter("terrain_data_texture")
    var bounds: Vector4 = _shared_material.get_shader_parameter("terrain_bounds")
    if tex and bounds:
        _debug_terrain_sprite.texture = tex
        _debug_terrain_sprite.position = Vector2(
            (bounds.x + bounds.z) / 2.0, (bounds.y + bounds.w) / 2.0)
        var tex_size := Vector2(tex.get_size())
        _debug_terrain_sprite.scale = Vector2(
            (bounds.z - bounds.x) / tex_size.x,
            (bounds.w - bounds.y) / tex_size.y)
        _debug_terrain_sprite.visible = true
```

---

## Files Changed

| File | Action | Notes |
|------|--------|-------|
| `Scripts/2D/GrassChunkManager2D.gd` | **Modify** | Add `mask_mesh` to ChunkData, pre-compute mask ArrayMeshes, add `debug_show_terrain` export + overlay, expose chunk data via public methods |
| `Scripts/2D/DisplacementManager2D.gd` | **Modify** | Add mask MeshInstance2D pool in SubViewport, `grass_nav_layer` export, chunk-driven activation/deactivation. Remove old `draw_colored_polygon` approach |
| `Shaders/2D/Grass2D.gdshader` | **Modify** | Sample G channel, scale VERTEX, add else clause for out-of-bounds |
| `Scenes/Demo2D.tscn` | **Modify** | Add navigation layer to TileSet, draw test polygons on a few tiles |

---

## Implementation Sequence

1. **GrassChunkManager2D**: Add `mask_mesh: ArrayMesh` to ChunkData. Pre-compute mask meshes during `_precompute_all_buffers()`. Add `debug_show_terrain` export and `Sprite2D` overlay.
2. **DisplacementManager2D**: Replace `_mask_control` / `draw_colored_polygon` approach with a pool of `MeshInstance2D` nodes in the SubViewport. Add `grass_nav_layer` export. Activate/deactivate mask chunks by polling active chunk keys each frame.
3. **Shader**: Add G channel sampling and `VERTEX *= grass_density` inside the existing displacement block. Add `else { VERTEX *= 0.0 }` for out-of-bounds.
4. **TileSet** (in Godot editor): Add a navigation layer. Draw test polygons on 2-3 grass tiles.
5. **Test**: Verify full-tile default coverage, partial tile coverage, displacement still works, debug overlay shows R/G channels mapped to world.

---

## Verification

1. **Partial tile**: Draw a half-tile polygon on a grass tile. Grass should appear only on the polygon half.
2. **Full tile default**: Tiles with `is_grass=true` but no polygon should have full grass (unchanged from current).
3. **No grass tile**: Tiles with `is_grass=false` should show no grass regardless of polygons.
4. **Displacement still works**: Move character through partially-grassed area. Blades still shear away.
5. **Camera scrolling**: Pan the camera. Partial grass tiles stream in/out correctly via the chunk system.
6. **Complex polygon**: Draw an L-shaped or concave polygon on a tile. Grass should respect the shape.
7. **Adjacent tiles**: Two adjacent tiles with different polygon shapes should have seamless grass at their shared edge (where both have coverage) and a clean cutoff where coverage differs.
