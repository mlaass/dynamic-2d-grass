# MIT License.
# Made by Dylearn

# Add as a child of any Node2D to affect grass in the SubViewport.
# Set the Sprite2D texture for the effect shape and use the node's
# transform (position, scale, rotation) to control placement and size.
# target_channel selects which RGBA channel to write to.
# blend_operation selects ADD (accumulate) or SUB (erase).

@tool
extends Sprite2D

@export_enum("R:0", "G:1", "B:2", "A:3") var source_channel: int = 0
@export_enum("R:0", "G:1", "B:2", "A:3") var target_channel: int = 0
@export_enum("ADD:0", "SUB:1") var blend_operation: int = 0

func _ready() -> void:
	add_to_group("grass_effectors")
	if not Engine.is_editor_hint():
		visible = false
