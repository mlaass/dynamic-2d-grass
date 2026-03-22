// MIT License.
// Made by Dylearn

// Shader for grass coverage mask MeshInstance2D nodes.  Writes G=1 with
// alpha=0 via blend_premul_alpha so the green channel is added without
// touching the alpha channel (reserved for cloud immunity).

shader_type canvas_item;
render_mode blend_premul_alpha;

void fragment() {
	COLOR = vec4(0.0, 1.0, 0.0, 0.0);
}
