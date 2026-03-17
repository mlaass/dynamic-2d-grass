# MIT License.
# Made by Dylearn

# Add as a child of any Node2D to make it displace grass.
# Provide a displacement_texture (red-channel gradient) for custom shapes,
# or leave empty for a default radial falloff.

@tool
extends Node2D

@export var displacement_texture: Texture2D
@export var displacement_radius: float = 64.0

func _ready() -> void:
	add_to_group("grass_displacers")
