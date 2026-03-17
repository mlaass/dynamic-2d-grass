# PRD: Terrain Data Texture System (2D Grass Displacement)

## Context

The 2D grass system (see `PRD-2D-Grass-System.md`) currently has wind animation, cloud shadows, and color variation but **no character displacement**. We need objects (characters, projectiles, explosions, etc.) to shear grass away from them in real time.

Rather than porting the 3D uniform-array approach (`vec4[64]`), we're building a **texture-based terrain data system** where a single RGBA texture encodes per-pixel world information. This is more flexible: arbitrary displacer count (O(1) per grass blade), and future channels for grass density and foliage type selection.

## Scope

**v1 (this PRD):** Displacement channel only — characters shear grass away via SubViewport-rendered influence texture.

**Future:** Grass density (G channel), foliage type selection (B channel).

---

## Architecture Overview

```
Demo2D (Node2D)
├── Camera2D
├── TileMapLayer
├── GrassSpawner (MultiMeshInstance2D)
│   └── ShaderMaterial (Grass2D.gdshader)
│       └── samples terrain_data_texture
│
├── DisplacementManager2D (Node)                # NEW — manages viewport, bounds, material binding
│   └── DisplacementViewport (SubViewport)      # NEW — owned by manager
│       ├── DisplacementCamera (Camera2D)       # NEW — covers grass bounds
│       └── [mirror sprites created by manager] # Sprite2D per displacer, additive blend
│
├── Character (CharacterBody2D, group: "grass_displacers")
│   └── exposes grass_displacement_radius: float
│
└── ... other displacers (group: "grass_displacers")
```

### Data Flow

1. DisplacementManager2D finds all nodes in the `"grass_displacers"` group at `_ready()`
2. For each displacer, the manager creates a **mirror Sprite2D** inside the SubViewport — a radial gradient with **additive blend mode** (`CanvasItemMaterial`, `blend_mode = Add`)
3. Each frame (`_process()`), the manager syncs each mirror sprite's position and scale to its source displacer
4. The SubViewport produces a texture where bright pixels = "something is pushing here"; overlapping displacers **add** their contributions
5. **Grass2D.gdshader** samples this texture at each blade's world position
6. The shader derives push **direction** from the texture gradient (finite differences)
7. The shader applies **shear** to `VERTEX.x` (and slight Y compression), anchored at the blade base

---

## Texture Channel Layout (RGBA)

| Channel | v1 Usage | Future Usage | Range |
|---------|----------|--------------|-------|
| **R** | Displacement strength | Displacement strength | 0.0 (none) – 1.0 (full) |
| **G** | Unused (0.0) | Grass density | 0.0 (bare) – 1.0 (dense) |
| **B** | Unused (0.0) | Foliage type selector | 0.0–1.0 mapped to type index |
| **A** | Unused (1.0) | Reserved | — |

The displacement sprites render **white** (R=1) at their center, fading to **black** (R=0) at the edge. G, B, A are untouched (black/transparent) for now.

---

## SubViewport Setup

### Configuration

```gdscript
# DisplacementManager2D.gd creates and configures the viewport:
var viewport := SubViewport.new()
viewport.size = Vector2i(512, 512)              # Configurable resolution
viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
viewport.transparent_bg = true                  # Black background = no displacement
# No canvas_cull_mask needed — only mirror sprites live in this SubViewport's tree
```

### Resolution

The viewport doesn't need pixel-perfect resolution — displacement is a smooth effect. A 512x512 texture covering a 4800x4800 pixel world area gives ~9.4 px/texel, which is plenty for smooth radial falloff.

Export `viewport_resolution: Vector2i` on DisplacementManager2D for tuning.

### Camera2D

A dedicated Camera2D inside the SubViewport, positioned and zoomed to cover the grass bounds:

```gdscript
var cam := Camera2D.new()
cam.position = grass_bounds.get_center()
# Zoom so the viewport covers exactly the grass bounds
cam.zoom = Vector2(viewport.size) / grass_bounds.size
```

The camera is static (set once from grass bounds). If the grass area is fixed (TileMap-defined), bounds are computed at `_ready()`.

### Coordinate Mapping (World → UV)

The grass shader needs to convert `world_origin` (pixel coordinates) to a UV on the displacement texture:

```glsl
uniform sampler2D terrain_data_texture : repeat_enable;
uniform vec4 terrain_bounds;  // (min_x, min_y, max_x, max_y) in world pixels

vec2 terrain_uv = (world_origin - terrain_bounds.xy) / (terrain_bounds.zw - terrain_bounds.xy);
```

`terrain_bounds` is set by DisplacementManager2D from the computed grass bounds.

---

## Displacement Sprites

DisplacementManager2D creates a mirror sprite inside the SubViewport for each displacer.

### Sprite Design

A **radial gradient texture** — white center fading to black edge. This can be:
- A pre-authored PNG (e.g. 64x64 soft circle)
- A simple shader on a quad that computes `1.0 - smoothstep(0.0, 1.0, length(UV - 0.5) * 2.0)`

The sprite's **scale** controls the displacement radius. A character with a wide stance scales it larger; a small projectile keeps it small.

### Rendering into SubViewport (Mirror-Sprite Approach)

SubViewports in Godot only render nodes that are **in their own scene tree** — visibility layers and cull masks cannot pull nodes from the main scene tree into a SubViewport. Therefore, displacement sprites must live inside the SubViewport as children.

DisplacementManager2D creates a **mirror Sprite2D** inside the SubViewport for each displacer found in the `"grass_displacers"` group. Each frame, the manager syncs the mirror sprite's `position` and `scale` to match its source node. This keeps the displacement sprites invisible in the main viewport (they exist only in the SubViewport's tree) while tracking the displacers accurately.

### Additive Blend Mode

Godot's default blend mode is **alpha blend (mix)**, which means overlapping displacement sprites would **occlude** each other instead of combining. Each mirror sprite must use a `CanvasItemMaterial` with `blend_mode = Add` so overlapping displacers sum their contributions. This ensures two nearby characters produce a combined displacement field, not one hiding the other.

```gdscript
var mat := CanvasItemMaterial.new()
mat.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD
mirror_sprite.material = mat
```

### Displacer Properties

Each displacer exposes:
- `grass_displacement_radius: float` — controls mirror sprite scale (world pixels)
- Sprite intensity can be modulated by adjusting the mirror sprite's `self_modulate.a` for partial displacement

Displacers **must** be in the `"grass_displacers"` group — the manager discovers displacers via this group at `_ready()` and creates mirror sprites for them.

---

## Shader Changes (`Shaders/2D/Grass2D.gdshader`)

### New Uniforms

```glsl
group_uniforms displacement;
uniform bool displacement_enabled = false;
uniform sampler2D terrain_data_texture : repeat_enable;  // SubViewport texture — repeat_enable prevents edge clamping artifacts in finite difference samples
uniform vec4 terrain_bounds;                     // (min_x, min_y, max_x, max_y)
uniform float displacement_pixels : hint_range(0.0, 30.0, 0.1) = 12.0;  // Max shear in pixels
uniform float displacement_y_factor : hint_range(0.0, 1.0, 0.01) = 0.3; // Vertical squish ratio
```

### Vertex Shader Logic

Inserted after the existing view-space sway block, before closing `vertex()`:

```glsl
if (displacement_enabled) {
    // Map world position to terrain texture UV
    vec2 bounds_min = terrain_bounds.xy;
    vec2 bounds_size = terrain_bounds.zw - terrain_bounds.xy;
    vec2 terrain_uv = (world_origin - bounds_min) / bounds_size;

    // Only displace if within texture bounds
    if (terrain_uv.x >= 0.0 && terrain_uv.x <= 1.0 &&
        terrain_uv.y >= 0.0 && terrain_uv.y <= 1.0) {

        // Sample displacement strength
        float strength = texture(terrain_data_texture, terrain_uv).r;

        if (strength > 0.01) {
            // Derive direction via finite differences (gradient of the strength field)
            vec2 texel_size = 1.0 / vec2(textureSize(terrain_data_texture, 0));
            float dx = texture(terrain_data_texture, terrain_uv + vec2(texel_size.x, 0.0)).r
                      - texture(terrain_data_texture, terrain_uv - vec2(texel_size.x, 0.0)).r;
            float dy = texture(terrain_data_texture, terrain_uv + vec2(0.0, texel_size.y)).r
                      - texture(terrain_data_texture, terrain_uv - vec2(0.0, texel_size.y)).r;

            // Gradient points toward the center of the displacer (uphill).
            // We want to push AWAY from center, so negate.
            vec2 push_dir = -normalize(vec2(dx, dy) + vec2(0.0001)); // epsilon avoids div-by-zero

            // Apply shear: base stays anchored, tip moves most
            VERTEX.x += push_dir.x * strength * displacement_pixels * height_factor;
            // Slight vertical squish when displaced (grass bends = appears shorter)
            VERTEX.y += abs(push_dir.x) * strength * displacement_pixels * displacement_y_factor * height_factor;
        }
    }
}
```

### Why Vertex Shader?

Displacement moves the grass blade geometry — this must happen in `vertex()`. The texture is sampled in vertex using the instance's `world_origin`, so each blade gets one sample (not per-pixel). This is efficient: one texture fetch + two finite-difference fetches = 3 samples per blade.

### Why Finite Differences for Direction?

With only a single channel (R = strength), we derive the push direction from the **gradient** of the strength field:
- `dx` = how much strength changes moving right
- `dy` = how much strength changes moving down
- The gradient vector `(dx, dy)` points **toward** the displacer center (uphill on the strength map)
- Negating it gives the **push-away** direction

This works because the displacement sprites are radial gradients — the strength field naturally forms a cone whose gradient points inward.

**Tradeoff:** At the exact center of a displacer (where gradient ≈ 0), direction is undefined. This is acceptable — at the center, strength is maximum and the grass is fully flattened anyway, so direction matters less. The epsilon (`0.0001`) prevents NaN.

---

## DisplacementManager2D Script (`Scripts/2D/DisplacementManager2D.gd`)

New `@tool` script that orchestrates the SubViewport system.

### Exports

```gdscript
@export var grass_spawner: MultiMeshInstance2D   # Reference to GrassSpawner
@export var viewport_resolution: Vector2i = Vector2i(512, 512)
@export var bounds_padding: float = 96.0         # Extra padding around grass bounds (pixels)
@export var displacement_gradient: Texture2D     # Radial gradient texture for mirror sprites
```

### Responsibilities

1. **Compute grass bounds** from the GrassSpawner's TileMapLayer (reuse existing cell iteration logic)
2. **Create SubViewport** with Camera2D at runtime (`_ready()`)
3. **Find all `"grass_displacers"`** and create a mirror Sprite2D inside the SubViewport for each, with additive blend material
4. **Sync mirror sprite positions** each frame in `_process()`
5. **Bind viewport texture** to the grass ShaderMaterial as `terrain_data_texture`
6. **Set `terrain_bounds`** uniform on the grass material
7. **Enable `displacement_enabled`** on the grass material

### Bounds Computation

```gdscript
func _compute_grass_bounds() -> Rect2:
    var tile_map: TileMapLayer = grass_spawner.tile_map  # Access spawner's tile_map export
    var cells = tile_map.get_used_cells()
    var min_pos = Vector2(INF, INF)
    var max_pos = Vector2(-INF, -INF)
    for cell in cells:
        var world_pos = tile_map.map_to_local(cell)
        min_pos = min_pos.min(world_pos)
        max_pos = max_pos.max(world_pos)
    var tile_size = Vector2(tile_map.tile_set.tile_size)
    min_pos -= tile_size / 2.0 + Vector2(bounds_padding, bounds_padding)
    max_pos += tile_size / 2.0 + Vector2(bounds_padding, bounds_padding)
    return Rect2(min_pos, max_pos - min_pos)
```

### Lifecycle

```gdscript
var _mirror_sprites: Array[Dictionary] = []  # [{source: Node2D, mirror: Sprite2D}]
var _viewport: SubViewport

func _ready():
    var bounds = _compute_grass_bounds()

    # Create SubViewport
    _viewport = SubViewport.new()
    _viewport.size = viewport_resolution
    _viewport.transparent_bg = true
    _viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
    add_child(_viewport)

    # Create Camera2D inside viewport
    var cam = Camera2D.new()
    cam.position = bounds.get_center()
    cam.zoom = Vector2(_viewport.size) / bounds.size
    _viewport.add_child(cam)

    # Create mirror sprites for all displacers
    var additive_mat = CanvasItemMaterial.new()
    additive_mat.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD

    for displacer in get_tree().get_nodes_in_group("grass_displacers"):
        var mirror = Sprite2D.new()
        mirror.texture = displacement_gradient
        mirror.material = additive_mat
        mirror.position = displacer.global_position
        var radius: float = displacer.grass_displacement_radius if "grass_displacement_radius" in displacer else 64.0
        mirror.scale = Vector2(radius, radius) / (displacement_gradient.get_size() / 2.0)
        _viewport.add_child(mirror)
        _mirror_sprites.append({source = displacer, mirror = mirror})

    # Bind to grass material
    var mat = grass_spawner.material as ShaderMaterial
    mat.set_shader_parameter("terrain_data_texture", _viewport.get_texture())
    mat.set_shader_parameter("terrain_bounds", Vector4(
        bounds.position.x, bounds.position.y,
        bounds.end.x, bounds.end.y
    ))
    mat.set_shader_parameter("displacement_enabled", true)

func _process(_delta: float):
    for entry in _mirror_sprites:
        var source: Node2D = entry.source
        var mirror: Sprite2D = entry.mirror
        mirror.position = source.global_position
        # Optionally update scale if radius changes at runtime
        if "grass_displacement_radius" in source:
            var radius: float = source.grass_displacement_radius
            mirror.scale = Vector2(radius, radius) / (displacement_gradient.get_size() / 2.0)
```

---

## Character Setup Guide

To make any node displace grass:

1. Add the node to the `"grass_displacers"` group
2. Expose a `grass_displacement_radius: float` property (world pixels)
3. That's it — DisplacementManager2D handles the rest (creates the mirror sprite, syncs position each frame)

No child sprites, no visibility layers, no special setup on the character side.

### Example: Adding Displacement to a Character

```gdscript
# On any CharacterBody2D or Node2D:
@export var grass_displacement_radius: float = 64.0

func _ready():
    add_to_group("grass_displacers")
```

### Radial Gradient Texture

A simple 64x64 or 128x128 PNG with:
- Center pixel: white (255, 0, 0, 255) — only R channel matters
- Edge pixel: black (0, 0, 0, 255)
- Smooth `smoothstep` falloff between

Alternatively, create it procedurally via a shader on the sprite:

```glsl
// displacement_gradient.gdshader
shader_type canvas_item;
void fragment() {
    float dist = length(UV - vec2(0.5)) * 2.0;
    float strength = 1.0 - smoothstep(0.0, 1.0, dist);
    COLOR = vec4(strength, 0.0, 0.0, 1.0);
}
```

---

## Files to Create/Modify

| File | Action | Purpose |
|------|--------|---------|
| `Shaders/2D/Grass2D.gdshader` | **Modify** | Add displacement uniforms + vertex logic |
| `Scripts/2D/DisplacementManager2D.gd` | **Create** | SubViewport orchestration + bounds computation |
| `Shaders/2D/displacement_gradient.gdshader` | **Create** | Procedural radial gradient for displacement sprites |
| `Scenes/Demo2D.tscn` | **Modify** | Add DisplacementManager2D node, add displacement sprite to test character |

### Reused Existing Files (no modifications)

- `Scripts/2D/GrassSpawner.gd` — bounds can be computed externally from its `tile_map` export
- `Shaders/2D/clouds2d.gdshaderinc` — unrelated, no changes

---

## Implementation Order

1. **`Shaders/2D/displacement_gradient.gdshader`** — procedural radial gradient shader for displacement sprites
2. **`Shaders/2D/Grass2D.gdshader`** — add displacement uniforms and vertex shader logic (behind `displacement_enabled` toggle, off by default)
3. **`Scripts/2D/DisplacementManager2D.gd`** — SubViewport creation, bounds computation, material binding
4. **`Scenes/Demo2D.tscn`** — wire up DisplacementManager2D, add a test character with displacement sprite
5. **Tune parameters** — `displacement_pixels`, viewport resolution, gradient falloff

---

## Performance Considerations

- **SubViewport overhead:** One extra render pass per frame, but only displacement sprites (minimal geometry). Negligible cost.
- **Shader cost:** 3 texture samples per grass blade (center + 2 finite differences). All in vertex shader, not fragment. With thousands of blades this is cheap.
- **Viewport resolution:** 512x512 is the sweet spot. Lower (256x256) is fine for large areas. Higher (1024x1024) only if precision matters.
- **Per-frame script cost:** DisplacementManager2D runs a `_process()` loop to sync mirror sprite positions — one `global_position` read + one `position` write per displacer per frame. Negligible for typical displacer counts (< 64). If profiling shows cost, the sync rate can be throttled (e.g. every 2nd frame).

---

## Known Limitations

- **Direction at displacer center:** Finite differences produce near-zero gradient at the exact center. Grass there gets maximum strength but undefined direction. Acceptable — visually the grass is fully flattened.
- **Overlapping displacers:** Mirror sprites use explicit additive blend (`CanvasItemMaterial.BLEND_MODE_ADD`). Two overlapping circles will sum their R values. If R > 1.0 after blending, the shader clamps naturally. Direction derivation still works because the gradient reflects the combined field.
- **Static bounds:** The Camera2D in the SubViewport is set once at `_ready()`. If the grass area changes at runtime (e.g. procedural generation), bounds must be recomputed.
- **Edge clamping:** Finite difference samples at terrain texture edges would normally read clamped texels, producing incorrect gradient directions (grass leaning inward at bounds edges). The `repeat_enable` sampler hint prevents this. Since the bounds include padding, displacement strength is 0.0 at the edges anyway, so the wrapped samples have no visible effect.
- **Y-sorting:** Not addressed in this system. Grass still renders as one layer. Separate future work.

---

## Verification

1. Add a CharacterBody2D to Demo2D in the `"grass_displacers"` group with `grass_displacement_radius` property
2. Add a DisplacementManager2D node and configure its `grass_spawner` and `displacement_gradient` exports
3. Move the character around — grass should **shear away** from it, leaning outward
4. Grass at the edge of the displacement radius should barely lean; grass at the center should lean fully
5. Multiple characters should blend their displacement naturally (overlapping gradients)
6. Disabling `displacement_enabled` should stop all displacement
7. Changing `displacement_pixels` should scale the shear intensity
8. Verify no displacement sprites are visible in the main viewport (only in the SubViewport)

---

## Future Extensions (Out of Scope)

- **G channel — Grass density:** A pre-authored texture controlling grass spawn density per-pixel. GrassSpawner would sample this texture during `_spawn_grass()` to vary blade count.
- **B channel — Foliage type:** Selects between grass, flowers, weeds, etc. Shader reads B value and picks albedo/accent accordingly.
- **Trail persistence:** Displacement sprites could leave a fading trail (e.g. via a feedback loop viewport) so grass stays pressed after a character passes.
- **Y-sorting via horizontal bands:** Split grass MultiMesh into Y-range buckets for proper depth ordering with characters.
