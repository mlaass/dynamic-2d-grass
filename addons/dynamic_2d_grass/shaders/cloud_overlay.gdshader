// MIT License.
// Made by Jomoho Games, based on original work by Dylearn

// Full-screen cloud shadow overlay.  Renders into a CanvasLayer ColorRect
// with blend_mul so the output (0-1 greyscale) darkens the scene.
// Reads terrain_data_texture A channel for cloud immunity and B channel
// for pseudo-3D vertical shadow offset.

shader_type canvas_item;
render_mode blend_mul;

// Cloud uniforms (same params as formerly in Grass2D.gdshader)
group_uniforms clouds;
uniform bool cloud_shadows_enabled = true;

uniform sampler2D cloud_noise : repeat_enable;
uniform sampler2D cloud_warp : repeat_enable;
uniform float cloud_warp_scale : hint_range(-50.0, 50, 0.1) = 1.0;
uniform float cloud_warp_freq : hint_range(-0.05, 0.05, 0.0001) = 0.1;

uniform sampler2D cloud_color ;
uniform float cloud_scale = 2000.0;
uniform float cloud_speed = 0.01;
uniform float cloud_contrast = 3.845;
uniform float cloud_threshold = 0.27;
uniform vec2 cloud_direction = vec2(1.0, 0.0);
uniform float cloud_shadow_min : hint_range(0.0, 1.0, 0.001) = 0.2;
uniform float cloud_diverge_angle : hint_range(0.0, 45.0, 0.001) = 10.0;

uniform float cloud_parallax : hint_range(-10.0, 10, 0.1) = 1.0;

// -- Cloud noise functions (inlined from clouds2d.gdshaderinc) ----------------

vec2 rotate_vec2(vec2 vector, float angle) {
	float angle_deg = angle * (PI / 180.0);
	float rotated_x  = (vector.x * cos(angle_deg)) - (vector.y * sin(angle_deg));
	float rotated_y  = (vector.x * sin(angle_deg)) + (vector.y * cos(angle_deg));
	return vec2 (rotated_x, rotated_y);
}

float get_cloud_noise_2d(vec2 world_pos) {
	float inv_scale = 1.0 / cloud_scale;

	// Rotate wind noise direction left and right
	vec2 cloud_direction1 = rotate_vec2(cloud_direction, cloud_diverge_angle);
	vec2 cloud_direction2 = rotate_vec2(cloud_direction, -cloud_diverge_angle);
	// Scroll noises using time
	vec2 cloud_time_direction1 = TIME * cloud_speed * normalize(cloud_direction1);
	vec2 cloud_time_direction2 = TIME * cloud_speed * normalize(cloud_direction2);
	// Sample noise value (change speed and scale of 2nd one to avoid obvious repeating of texture)
	float cloud_sample1 = texture(cloud_noise, world_pos * inv_scale + cloud_time_direction1).r;
	float cloud_sample2 = texture(cloud_noise, world_pos * (inv_scale * 0.8) + (cloud_time_direction2 * 0.89 * PI / 3.0)).r;
	// Combine noise samples
	float cloud_sample = (cloud_sample1 * cloud_sample2);
	float light_value = clamp(cloud_sample + cloud_threshold, 0.0, 1.0);

	light_value = (light_value - 0.5) * cloud_contrast + 0.5;
	light_value = clamp(light_value + cloud_threshold, cloud_shadow_min, 1.0);
	return light_value;
}

group_uniforms camera;
uniform vec2 camera_position;
uniform vec2 camera_zoom = vec2(1.0);
uniform vec2 viewport_size = vec2(1920.0, 1080.0);

group_uniforms terrain;
uniform bool debug_terrain = false;
uniform sampler2D terrain_data_texture : filter_nearest;
uniform vec4 terrain_bounds;
uniform float cloud_y_offset_scale : hint_range(0.0, 200.0, 0.1) = 50.0;

void fragment() {
	// Convert UV to world position
	vec2 world_pos = (UV - 0.5) * viewport_size / camera_zoom + camera_position;

	// Sample terrain data
	vec2 bounds_min = terrain_bounds.xy;
	vec2 bounds_size = terrain_bounds.zw - terrain_bounds.xy;
	vec2 terrain_uv = (world_pos - bounds_min) / bounds_size;

	vec4 terrain = vec4(0.0);
	if (terrain_uv.x >= 0.0 && terrain_uv.x <= 1.0 &&
		terrain_uv.y >= 0.0 && terrain_uv.y <= 1.0) {
		terrain = texture(terrain_data_texture, terrain_uv);
	}

  vec4 grad = vec4(0.0);

	if (debug_terrain) {
		// Show raw terrain data: R=displacement, G=coverage, B=y-offset, A=immunity
		// blend_mul will multiply with the scene, so output directly
		COLOR = vec4(terrain.r+terrain.a, terrain.g, terrain.b , 1.0);
	} else {
		float cloud_val = 1.0;
		if (cloud_shadows_enabled) {
			// Offset cloud sampling position for pseudo-3D
			vec2 cloud_pos = (world_pos-camera_position)+(camera_position*cloud_parallax);
			cloud_pos.y -= terrain.b * cloud_y_offset_scale;
      vec2 warpp= cloud_warp_scale * vec2(sin(cloud_pos.y*cloud_warp_freq), cos(cloud_pos.x*cloud_warp_freq));
      float inv_scale = 1.0 / cloud_scale;
      vec2 tpos = (cloud_pos+warpp) * inv_scale;
      cloud_pos+= texture(cloud_warp,tpos).r*warpp;

			// Get cloud shadow value and apply immunity
			cloud_val = get_cloud_noise_2d(cloud_pos);
      cloud_val = mix(cloud_val, 1.0,terrain.a);

		}
    grad = texture(cloud_color, vec2(cloud_val));
		COLOR = vec4(grad.rgb, 1.0);//;(1.0-cloud_val) *(1.0-terrain.a));
	}
}
