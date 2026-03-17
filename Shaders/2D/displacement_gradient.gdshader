shader_type canvas_item;
render_mode blend_add;

void fragment() {
	float dist = length(UV - vec2(0.5)) * 2.0;
	float strength = 1.0 - smoothstep(0.0, 1.0, dist);
	COLOR = vec4(strength, 0.0, 0.0, 1.0);
}
