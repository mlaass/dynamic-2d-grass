// MIT License.
// Made by Dylearn

// Channel-routing shader for GrassEffector2D mirrors in the terrain data
// SubViewport.  Uses blend_disabled + screen_texture to independently
// modify a single RGBA channel without affecting others.
// A BackBufferCopy node must precede each sprite using this shader so
// overlapping effectors accumulate correctly.

shader_type canvas_item;
render_mode blend_disabled;

uniform sampler2D screen_texture : hint_screen_texture, filter_nearest;
uniform int source_channel : hint_range(0, 3) = 0;
uniform int target_channel : hint_range(0, 3) = 0;
uniform bool subtract_mode = false;

void fragment() {
	vec4 screen = texture(screen_texture, SCREEN_UV);
	vec4 tex_sample = texture(TEXTURE, UV);
	float src = tex_sample.r;
	if (source_channel == 1) src = tex_sample.g;
	else if (source_channel == 2) src = tex_sample.b;
	else if (source_channel == 3) src = tex_sample.a;
	float value = src * tex_sample.a * COLOR.a;

	float delta = value;
	if (subtract_mode) delta = -value;

	if (target_channel == 0) screen.r += delta;
	else if (target_channel == 1) screen.g += delta;
	else if (target_channel == 2) screen.b += delta;
	else screen.a += delta;

	COLOR = clamp(screen, vec4(0.0), vec4(1.0));
}
