# MIT License.
# Made by Dylearn

# Add as a child of any Node2D to affect grass in the SubViewport.
# Provide an effect_texture for custom shapes, or leave empty for a
# default radial falloff.  Set blend_mode to control how the texture
# composites (ADD for displacement, SUB for destruction, etc.).

@tool
extends Node2D

@export var effect_texture: Texture2D
@export var effect_radius: float = 64.0
@export var blend_mode: CanvasItemMaterial.BlendMode = CanvasItemMaterial.BLEND_MODE_ADD

func _ready() -> void:
	add_to_group("grass_effectors")
