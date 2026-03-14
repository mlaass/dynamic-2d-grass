# MIT License.
# Made by Dylearn

# Reads a TileMapLayer and spawns grass instances via MultiMesh

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


func _spawn_grass() -> void:
	if not tile_map:
		tile_map = get_parent().find_child("TileMapLayer", false) as TileMapLayer
	if not tile_map or not tile_map.tile_set:
		push_warning("GrassSpawner: No TileMapLayer found")
		return

	var tile_size : Vector2i = tile_map.tile_set.tile_size

	# Check if TileSet has "is_grass" custom data layer
	var has_custom_data := false
	for i in range(tile_map.tile_set.get_custom_data_layers_count()):
		if tile_map.tile_set.get_custom_data_layer_name(i) == "is_grass":
			has_custom_data = true
			break

	# Collect grass cells — filter by is_grass if available, otherwise use all painted cells
	var grass_cells : Array[Vector2i] = []
	for cell in tile_map.get_used_cells():
		var data := tile_map.get_cell_tile_data(cell)
		if data:
			if has_custom_data:
				if data.get_custom_data("is_grass"):
					grass_cells.append(cell)
			else:
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
