# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Godot 4.5 project (Forward Plus renderer) implementing a stylised 3D pixel-art grass system with wind animation, character-reactive displacement, hybrid toon shading, and world-space cloud shadows. Created by Dylearn.

## Running

Open in Godot 4.5+. Main scene: `Scenes/Demo.tscn`. No build system — run directly from the Godot editor.

## Architecture

### Shader Pipeline

All shaders share cloud shadow logic via `Shaders/clouds.gdshaderinc` (included with `#include`). This file defines global shader uniforms for cloud simulation and provides `get_cloud_noise()` and `rotate_vec2()` used across shaders.

- **Grass.gdshader** — Core grass shader. Billboarded MultiMesh quads with:
  - Stepped framerate animation (per-instance phase offset to avoid synchronized updates)
  - World-space wind sway via dual scrolling noise textures diverged at an angle
  - View-space oscillation sway
  - Character displacement rotation (reads `character_positions` uniform array, max 64)
  - Fake perspective UV squishing in fragment
  - Noise-based colour patches (albedo2/albedo3) and accent grass variants selected by instance ID
  - Hybrid toon shading with configurable gradient threshold
- **Floor.gdshader** — Ground plane with matching noise-based colour patches and toon shading + cloud shadows
- **ToonShader.gdshader** — Generic toon shader for 3D models with cloud shadows
- **Outline.gdshader** — Screen-space post-process outline using depth and normal edge detection

### Scripts (GDScript, all `@tool`)

- **CharacterManager.gd** — Collects positions of all nodes in the `"characters"` group (up to 64), packs them as `Vector4` (xyz + displacement size), and passes to the grass shader at a configurable framerate
- **ShaderGlobals.gd** — Exposes cloud global shader parameters as `@export` properties for editor tweaking via `RenderingServer.global_shader_parameter_set()`
- **LightDirection.gd** — Passes the DirectionalLight3D direction to the `light_direction` global shader parameter each frame
- **RandomPositionCharacter.gd** — Demo NPC that picks random visible ground points (ray-plane intersection with y=0) and moves toward them. Exposes `grass_displacement_size` for the CharacterManager

### Key Conventions

- Characters that displace grass must be in the `"characters"` global group and expose a `grass_displacement_size: float` property
- Cloud parameters are global shader uniforms defined in `project.godot` under `[shader_globals]`
- Grass uses MultiMeshInstance3D — individual blade transforms are set by Godot's MultiMesh, not by scripts
- All scripts run as `@tool` for editor preview
- Shaders use `group_uniforms` for organized inspector UI

### GDScript Typing Rules

This project treats the "inferred Variant type" warning as a **parse error**. Never use `:=` when the right-hand side returns `Variant`. Common pitfalls:

- `Array.pop_back()`, `Array.pop_front()`, `Array.back()`, `Array.front()` — always return `Variant` even on typed arrays. Use explicit type: `var x: int = arr.pop_back()`
- `Dictionary[key]` — returns `Variant`. Use explicit type: `var x: MyType = dict[key]`
- `for x in [1.0, 2.0]:` — untyped array literals make `x` Variant. Use a typed array: `var arr: Array[float] = [1.0, 2.0]` then `for x in arr:`
- `for key in dict:` / `for key in dict.keys():` — `key` is Variant. Acceptable for iteration but don't use `:=` on expressions derived from it without an explicit type annotation.
- Method chains on `Variant` return `Variant`. E.g. `chunk_manager.get_chunk_map().size()` — even though `.size()` returns `int`, the receiver is `Variant`, so the result is `Variant`. Use explicit type: `var n: int = chunk_manager.get_chunk_map().size()`

## Testing

After any GDScript or shader change, run `timeout 10 godot45 --headless --path . --scene <scene>.tscn 2>&1` to verify no parse or runtime errors. Test with the scene you're actually modifying (e.g. `Scenes/Demo2D.tscn` for 2D grass work). Check for `SCRIPT ERROR`, `Parse Error`, and `Failed to load` in the output.

## Licensing

Code (scripts/shaders): MIT. Art assets: CC BY 4.0 (credit "by Dylearn"). Waterfowl logo: all rights reserved.
