# PRD: Camera-Adaptive 2D Grass Spawning

## Context

The 2D grass system (see `PRD-2D-Grass-System.md`) currently spawns **all** grass instances at startup into a single `MultiMeshInstance2D`. This works for the demo scene but doesn't scale: a large tilemap would create hundreds of thousands of off-screen instances, wasting GPU and memory. Moving the camera reveals no new grass because everything is already spawned.

We need the grass system to be **camera-adaptive**: only spawn grass visible to the camera (plus a buffer), dynamically activate/deactivate grass as the camera moves, and handle teleports without any visible pop-in.

## Scope

**v1 (this PRD):**
- Chunked MultiMesh pool that streams grass in/out based on camera viewport
- Pre-computed per-chunk transform buffers for instant activation
- Camera-relative displacement viewport (DisplacementManager2D follows camera)
- Zero pop-in on teleport
- Limited zoom range support

**Out of scope:** LOD / density scaling at different zoom levels, procedural placement beyond tilemap, runtime tilemap modification.

---

## Constraints

- **World size**: Large but bounded tilemap — many screens of content, defined edges
- **Camera movement**: Smooth scrolling with occasional teleports (scene transitions, fast travel)
- **Zoom**: Limited range (e.g., 0.5x–2.0x)
- **Placement**: TileMap-driven via `is_grass` custom data layer (unchanged from current system)
- **Grass density**: ~60–80% of tiles have grass
- **Persistence**: Returning to an area must show identical grass — 100% deterministic
- **Performance**: No visible stutter during scrolling or teleport

---

## Architecture Overview

```
Demo2D (Node2D)
├── Camera2D
├── TileMapLayer
├── GrassChunkManager2D (Node2D)            # NEW — replaces GrassSpawner
│   ├── PooledMMI_0 (MultiMeshInstance2D)    # Created at runtime by pool
│   ├── PooledMMI_1 (MultiMeshInstance2D)
│   └── ...
│
├── DisplacementManager2D (Node)             # MODIFIED — camera-relative
│   └── DisplacementViewport (SubViewport)
│       ├── DisplacementCamera (Camera2D)    # Tracks game camera
│       └── [mirror sprites]
│
└── Character
    └── GrassDisplacer2D
```

### Data Flow

1. **Startup**: `GrassChunkManager2D` scans the TileMapLayer, buckets grass cells into chunks, and pre-computes a `PackedFloat32Array` transform buffer per chunk. Creates a pool of `MultiMeshInstance2D` nodes.
2. **Each frame**: Manager computes which chunks intersect the camera viewport + buffer zone. Activates entering chunks (copies pre-computed buffer to a pooled MMI). Deactivates exiting chunks (hides MMI, returns to pool).
3. **Teleport**: Same activation path — all visible chunks activated synchronously within a single `_process()` call, before the frame renders.
4. **Displacement**: `DisplacementManager2D` updates its internal camera to match the game camera each frame. Shader reads displacement from camera-relative bounds via the existing `terrain_bounds` uniform.

---

## Chunk Data Structure

A **chunk** is a rectangular region of `CHUNK_SIZE x CHUNK_SIZE` tile coordinates. A chunk at grid position `(cx, cy)` covers tiles `[cx*CHUNK_SIZE .. (cx+1)*CHUNK_SIZE - 1]` in both axes.

```gdscript
class ChunkData:
    var grid_pos: Vector2i              # Chunk grid coordinate
    var grass_cells: Array[Vector2i]    # Tile coords with is_grass=true
    var instance_count: int             # grass_cells.size() * density
    var buffer: PackedFloat32Array      # Pre-computed MultiMesh buffer
    var assigned_pool_idx: int = -1     # Pool index, or -1 if inactive
```

### Startup Scan (`_build_chunk_map()`)

```gdscript
for cell in tile_map.get_used_cells():
    var data := tile_map.get_cell_tile_data(cell)
    if data and data.get_custom_data("is_grass"):
        # Floor division for negative coords
        var cx := floori(float(cell.x) / chunk_size)
        var cy := floori(float(cell.y) / chunk_size)
        var key := Vector2i(cx, cy)
        if key not in _chunk_map:
            _chunk_map[key] = ChunkData.new()
            _chunk_map[key].grid_pos = key
        _chunk_map[key].grass_cells.append(cell)
```

After scan, compute `instance_count = grass_cells.size() * density` per chunk.

**Recommended `CHUNK_SIZE`**: 16 tiles (configurable via export). With 16px tiles this gives 256×256 pixel chunks; with larger tiles the world-space size scales proportionally. The chunk size should balance pool node count (fewer = more instances per chunk) against activation granularity (smaller = tighter culling).

---

## Pre-Computed Transform Buffers

The key to zero-lag activation: compute all instance transforms and custom data once at startup and store as a flat `PackedFloat32Array`. Activating a chunk is then a single buffer assignment.

### MultiMesh Buffer Layout (TRANSFORM_2D + custom_data)

Each instance occupies 12 floats:

| Offset | Content |
|--------|---------|
| 0–7 | Transform2D as column-major: `[x.x, y.x, pad, origin.x, x.y, y.y, pad, origin.y]` |
| 8–11 | Custom data as RGBA floats |

### Buffer Pre-Computation

```gdscript
func _precompute_chunk_buffer(chunk: ChunkData) -> void:
    var buf := PackedFloat32Array()
    buf.resize(chunk.instance_count * 12)
    var write_idx := 0

    for cell in chunk.grass_cells:
        var rng := RandomNumberGenerator.new()
        rng.seed = hash(cell)  # Same deterministic seed as current GrassSpawner

        var cell_center := tile_map.map_to_local(cell)
        var scatter := Vector2(_tile_size) * 0.9

        for i in range(density):
            var offset := Vector2(
                rng.randf_range(-scatter.x / 2.0, scatter.x / 2.0),
                rng.randf_range(-scatter.y / 2.0, scatter.y / 2.0)
            )
            var pos := cell_center + offset
            pos.y -= grass_sprite_size.y / 2.0  # Bottom-anchor

            # Transform2D identity + translation
            buf[write_idx + 0] = 1.0   # x.x
            buf[write_idx + 1] = 0.0   # y.x
            buf[write_idx + 2] = 0.0   # pad
            buf[write_idx + 3] = pos.x # origin.x
            buf[write_idx + 4] = 0.0   # x.y
            buf[write_idx + 5] = 1.0   # y.y
            buf[write_idx + 6] = 0.0   # pad
            buf[write_idx + 7] = pos.y # origin.y

            # Custom data (accent seeds)
            buf[write_idx + 8]  = rng.randf()
            buf[write_idx + 9]  = rng.randf()
            buf[write_idx + 10] = 0.0
            buf[write_idx + 11] = 0.0
            write_idx += 12

    chunk.buffer = buf
```

This preserves the exact same RNG sequence as the current `GrassSpawner._spawn_grass()` — identical `hash(cell)` seed, identical `randf_range` calls in the same order.

### Memory Cost

Per chunk (16×16 tiles, density 6, ~75% grass): `~1152 instances × 48 bytes = ~55 KB`.
For a map with ~100 chunks: **~5.5 MB**. Negligible.

---

## Pool Management

### Pool Creation

At startup, pre-allocate `pool_size` `MultiMeshInstance2D` nodes. Each gets a pre-allocated `MultiMesh` sized to the maximum instances any chunk can hold.

```gdscript
var _pool: Array[MultiMeshInstance2D] = []
var _pool_free: Array[int] = []         # Indices of unused entries
var _active_chunks: Dictionary = {}      # Vector2i -> pool_idx

func _create_pool() -> void:
    var max_per_chunk := chunk_size * chunk_size * density
    for i in pool_size:
        var mmi := MultiMeshInstance2D.new()
        mmi.material = _shared_material
        var mm := MultiMesh.new()
        mm.transform_format = MultiMesh.TRANSFORM_2D
        mm.use_custom_data = true
        mm.mesh = _quad_mesh  # Shared QuadMesh, size = grass_sprite_size
        mm.instance_count = max_per_chunk
        mm.visible_instance_count = 0  # Render none until activated
        mmi.multimesh = mm
        mmi.visible = false
        add_child(mmi)
        _pool.append(mmi)
        _pool_free.append(i)
```

**`visible_instance_count`** controls how many instances render without re-allocating the internal buffer. Setting `instance_count` once at pool creation avoids all allocation during gameplay.

### Pool Sizing

Auto-calculated from viewport size, chunk dimensions, buffer zone, and minimum zoom:

```gdscript
func _compute_pool_size() -> int:
    var viewport_size := get_viewport().get_visible_rect().size
    var chunk_world := Vector2(_tile_size * chunk_size)
    var effective_size := viewport_size / min_zoom  # Worst-case visible area
    var chunks_x := ceili(effective_size.x / chunk_world.x) + 3  # +3: partial overlap + buffer
    var chunks_y := ceili(effective_size.y / chunk_world.y) + 3
    return chunks_x * chunks_y
```

Export `pool_size_override: int = 0` allows manual override (0 = auto).

### Material Sharing

All pool nodes share a single `ShaderMaterial`. The manager creates it by duplicating the material from the scene (or constructing one with `Grass2D.gdshader`). `_sync_material()` from the current `GrassSpawner` is preserved to push export values to this shared material.

---

## Visibility Determination

Each frame in `_process()`, compute which chunks the camera can see.

### Active Zone

```gdscript
func _get_active_zone() -> Rect2:
    var canvas_xform := get_viewport().get_canvas_transform()
    var viewport_size := get_viewport().get_visible_rect().size
    var inv := canvas_xform.affine_inverse()
    var top_left := inv * Vector2.ZERO
    var bottom_right := inv * viewport_size
    var view_rect := Rect2(top_left, bottom_right - top_left).abs()
    return view_rect.grow(buffer_pixels)
```

`buffer_pixels` (export, default: one chunk width) ensures chunks activate before scrolling into view.

### Chunk Range from Rect

```gdscript
func _chunks_in_rect(rect: Rect2) -> Array[Vector2i]:
    var chunk_world := Vector2(_tile_size * chunk_size)
    var min_chunk := Vector2i(floori(rect.position.x / chunk_world.x),
                              floori(rect.position.y / chunk_world.y))
    var max_chunk := Vector2i(floori(rect.end.x / chunk_world.x),
                              floori(rect.end.y / chunk_world.y))
    var result: Array[Vector2i] = []
    for cx in range(min_chunk.x, max_chunk.x + 1):
        for cy in range(min_chunk.y, max_chunk.y + 1):
            var key := Vector2i(cx, cy)
            if key in _chunk_map:
                result.append(key)
    return result
```

### Diff Optimization

Track `_last_chunk_range: Rect2i`. Skip the full diff if the chunk range hasn't changed since last frame:

```gdscript
var current_range := Rect2i(min_chunk, max_chunk - min_chunk + Vector2i.ONE)
if current_range == _last_chunk_range:
    return
_last_chunk_range = current_range
```

---

## Activation / Deactivation Lifecycle

### Activation

```gdscript
func _activate_chunk(chunk_key: Vector2i) -> void:
    if _pool_free.is_empty():
        push_warning("GrassChunkManager2D: Pool exhausted")
        return
    var pool_idx := _pool_free.pop_back()
    var chunk := _chunk_map[chunk_key]
    var mmi := _pool[pool_idx]
    var mm := mmi.multimesh
    # Copy pre-computed buffer (single memcpy)
    mm.instance_count = chunk.instance_count
    mm.buffer = chunk.buffer
    mmi.visible = true
    _active_chunks[chunk_key] = pool_idx
    chunk.assigned_pool_idx = pool_idx
```

Setting `mm.instance_count` then `mm.buffer` populates all transforms and custom data in one operation.

### Deactivation

```gdscript
func _deactivate_chunk(chunk_key: Vector2i) -> void:
    var pool_idx: int = _active_chunks[chunk_key]
    _pool[pool_idx].multimesh.visible_instance_count = 0
    _pool[pool_idx].visible = false
    _pool_free.append(pool_idx)
    _active_chunks.erase(chunk_key)
    _chunk_map[chunk_key].assigned_pool_idx = -1
```

No buffer clearing needed — `visible = false` prevents rendering, and the buffer is overwritten on next activation.

### Update Loop

```gdscript
func _update_visible_chunks() -> void:
    var needed := _chunks_in_rect(_get_active_zone())
    var needed_set: Dictionary = {}
    for key in needed:
        needed_set[key] = true

    # Deactivate chunks no longer needed
    for key in _active_chunks.keys():
        if key not in needed_set:
            _deactivate_chunk(key)

    # Activate new chunks
    for key in needed:
        if key not in _active_chunks:
            _activate_chunk(key)
```

---

## Teleport Handling

Zero pop-in is guaranteed by design:

1. `_update_visible_chunks()` runs in `_process()`, which executes **before** rendering each frame
2. On a teleport frame, the camera position jumps. The next `_process()` computes the new active zone, deactivates old chunks, activates new ones — all synchronously
3. Activation copies a pre-computed `PackedFloat32Array` via `mm.buffer = chunk.buffer` — this is a single contiguous memory copy

**Worst-case cost**: Teleporting to a fully new view — ~40 chunks deactivated, ~40 activated. Each activation is a buffer copy of ~55 KB. Total: ~2.2 MB of memcpy. Well under 1ms on any modern CPU.

---

## Zoom Handling

The `_get_active_zone()` function handles zoom automatically: `get_canvas_transform().affine_inverse()` maps screen coordinates to world space, so zooming out produces a larger world-space rect and more chunks become visible.

The pool must be sized for the most zoomed-out case. The `min_zoom` export (default 0.5) feeds into `_compute_pool_size()` to ensure enough pool entries exist.

When zooming in, fewer chunks are needed and extras return to the pool.

---

## Displacement: Camera-Relative Conversion

### Current System

`DisplacementManager2D` creates a SubViewport covering the **entire grass area**. The shader samples it with UVs derived from fixed `terrain_bounds`.

### Problem

For large maps, a fixed viewport wastes resolution — a 512×512 texture covering thousands of pixels of world gives very coarse displacement gradients.

### New System

The SubViewport follows the camera. Its internal `Camera2D` matches the game camera's position and covers the viewport area plus a buffer.

### Changes to `DisplacementManager2D.gd`

1. **Remove** `_compute_grass_bounds()` — no longer needed
2. **Add** `@export var camera: Camera2D` — reference to game camera
3. **`_ready()`**: Create SubViewport as before, but the internal Camera2D is positioned dynamically (not from grass bounds)
4. **`_process()`**: Each frame, update internal camera position/zoom to match game camera + buffer. Update `terrain_bounds` shader uniform to reflect current coverage.

```gdscript
func _process(_delta: float) -> void:
    if not camera:
        return

    var viewport_size := get_viewport().get_visible_rect().size
    var world_size := viewport_size / camera.zoom + Vector2(displacement_buffer * 2, displacement_buffer * 2)

    _internal_cam.position = camera.global_position
    _internal_cam.zoom = Vector2(viewport_resolution) / world_size

    var half_world := world_size / 2.0
    var bounds_min := camera.global_position - half_world
    var bounds_max := camera.global_position + half_world
    _grass_material.set_shader_parameter("terrain_bounds", Vector4(
        bounds_min.x, bounds_min.y, bounds_max.x, bounds_max.y
    ))

    # Update mirror sprite positions (unchanged)
    for entry in _mirror_sprites:
        # ... same as before ...
```

`displacement_buffer` (export, default 128.0 px) ensures the displacement viewport extends slightly beyond the visible area so edge blades still receive displacement.

### Material Reference

`DisplacementManager2D` needs the shared `ShaderMaterial` from `GrassChunkManager2D` to set the `terrain_bounds` uniform. Add `@export var grass_material: ShaderMaterial` or reference it via `GrassChunkManager2D`.

---

## Shader Changes

**Minimal.** The displacement UV computation in `Grass2D.gdshader` (lines 172–195) already derives UVs from `terrain_bounds`:

```glsl
vec2 bounds_min = terrain_bounds.xy;
vec2 bounds_size = terrain_bounds.zw - terrain_bounds.xy;
vec2 terrain_uv = (world_origin - bounds_min) / bounds_size;
```

This works identically whether `terrain_bounds` covers the full map or just the camera area. The bounds check at line 177 correctly skips blades outside the displacement viewport.

**One optional change**: The `terrain_data_texture` sampler (line 77) currently has `: repeat_enable`. With camera-relative bounds, repeating is no longer meaningful. Consider removing it — but the bounds check already guards against out-of-range UVs, so this is cosmetic.

---

## GrassChunkManager2D Script Structure

`GrassChunkManager2D.gd` replaces `GrassSpawner.gd`. It extends `Node2D` (since it manages multiple MMI children) and preserves all existing exports plus adds chunking configuration.

```gdscript
@tool
extends Node2D

# --- Placement (from GrassSpawner) ---
@export var tile_map: TileMapLayer
@export var density: int = 6
@export var grass_sprite_size: Vector2 = Vector2(16, 24)
@export var regenerate: bool = false:
    set(value):
        if value:
            _rebuild()
        regenerate = false

# --- Chunking (new) ---
@export_group("Chunking")
@export var chunk_size: int = 16
@export var buffer_pixels: float = 256.0
@export var min_zoom: float = 0.5
@export var pool_size_override: int = 0

# --- Textures, Colours, Accents, Wind (same as GrassSpawner) ---
# ... all existing exports with _sync_material() setters ...

# --- Internal ---
var _shared_material: ShaderMaterial
var _quad_mesh: QuadMesh
var _tile_size: Vector2i
var _chunk_map: Dictionary = {}          # Vector2i -> ChunkData
var _pool: Array[MultiMeshInstance2D] = []
var _pool_free: Array[int] = []
var _active_chunks: Dictionary = {}      # Vector2i -> pool_idx
var _last_chunk_range: Rect2i

func _ready() -> void:
    _sync_material()
    _rebuild()

func _process(_delta: float) -> void:
    if Engine.is_editor_hint():
        return  # No runtime chunking in editor
    _update_visible_chunks()
```

### Editor Preview

In editor (`Engine.is_editor_hint()`), the `regenerate` button spawns a single full `MultiMesh` using the existing `_spawn_grass()` logic from `GrassSpawner` — same as current behavior. Camera-adaptive chunking only runs at runtime.

---

## Edge Cases

### Chunk Boundaries

Grass blades scatter up to `tile_size * 0.45` beyond their cell center. Blades near a chunk border visually cross into the neighbor chunk's area. This is fine — both chunks are active simultaneously when viewing the boundary. The buffer zone ensures chunks deactivate only after their blades have scrolled off-screen (accounting for `wind_sway_pixels` overshoot).

### Partial Chunks at Map Edges

Chunks at tilemap boundaries contain fewer grass cells. `instance_count` and `buffer` size reflect the actual cell count. No special handling needed.

### Pool Exhaustion

If the camera zooms beyond `min_zoom` or the map is denser than expected, the pool may run out. The manager logs a warning and skips activation for overflow chunks. These would be at the outer edge of the buffer zone, so the user wouldn't see the gap.

### Z-Ordering

All pool MMI nodes are children of `GrassChunkManager2D`. Their rendering order doesn't matter visually since grass blades are tiny sprites scattered across the map — no meaningful overlap between chunks. The manager node's `z_index` controls grass vs. other scene elements, same as the old `GrassSpawner`.

### TileMap Changes at Runtime

For v1, the tilemap is assumed static after `_ready()`. A public `rebuild()` method is available to regenerate chunk data if the tilemap changes.

---

## Files Changed

| File | Action | Notes |
|------|--------|-------|
| `Scripts/2D/GrassChunkManager2D.gd` | **Create** | Replaces `GrassSpawner.gd` — chunk management, pool, visibility, all exports |
| `Scripts/2D/DisplacementManager2D.gd` | **Modify** | Camera-relative viewport: add `camera` export, remove `_compute_grass_bounds()`, update internal camera each frame |
| `Shaders/2D/Grass2D.gdshader` | **Modify** | Optional: remove `: repeat_enable` from `terrain_data_texture` sampler |
| `Scenes/Demo2D.tscn` | **Modify** | Replace `GrassSpawner` node with `GrassChunkManager2D`, wire `camera` export on `DisplacementManager2D` |
| `Scripts/2D/GrassSpawner.gd` | **Keep** | Retained for backward compatibility / small maps; not used in chunked mode |

---

## Implementation Sequence

1. Create `GrassChunkManager2D.gd` with `ChunkData`, exports, `_build_chunk_map()`, `_precompute_buffers()`. Verify startup scan produces correct chunk counts via logging.
2. Add pool creation and activation/deactivation. Test with a hardcoded visible range to verify transforms render correctly.
3. Add `_update_visible_chunks()` with camera-relative active zone. Test smooth scrolling — chunks stream in/out with no visual artifacts.
4. Test teleport by jumping camera to distant positions. Verify zero pop-in.
5. Modify `DisplacementManager2D.gd` for camera-relative viewport. Wire `camera` export. Verify displacement still works during scrolling.
6. Update `Demo2D.tscn` scene tree.
7. Performance test: measure frame time during teleport and smooth scroll. Tune `chunk_size` and `buffer_pixels`.
8. Editor preview: verify `regenerate` button still works for full-map preview.

## Verification

- **Smooth scroll**: Pan camera across the map. No grass pop-in at edges, no gaps, no stutter.
- **Teleport**: Jump camera to opposite corner of the map. Grass fully present on first frame.
- **Determinism**: Pan away from an area, return. Grass must be pixel-identical.
- **Displacement**: Move a character through grass. Blades shear correctly at all camera positions.
- **Zoom**: Zoom in and out. Grass density stays correct, no pool exhaustion warnings.
- **Editor**: `regenerate` button produces full-map preview. No runtime errors in editor.
- **Performance**: Profile `_process()` during fast scrolling. Target < 1ms per frame for chunk updates.
