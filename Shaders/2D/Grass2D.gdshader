// MIT License.
// Made by Dylearn
// 2D adaptation of Grass.gdshader for use with MultiMeshInstance2D

shader_type canvas_item;

// Cloud uniforms declared here as local uniforms for clouds2d.gdshaderinc
group_uniforms clouds;
uniform bool cloud_shadows_enabled = true; // Toggle cloud shadow effect
uniform sampler2D cloud_noise : repeat_enable; // Noise for cloud simulation
uniform float cloud_scale = 2000.0; // Scale of cloud noise (pixel-space — ~50x larger than 3D equivalent)
uniform float cloud_speed = 0.01; // Speed of cloud movement (UV-space scroll rate, matches 3D)
uniform float cloud_contrast = 3.845; // Steepness of noise pattern
uniform float cloud_threshold = 0.27; // Brightness of noise pattern
uniform vec2 cloud_direction = vec2(1.0, 0.0); // Direction of cloud movement
uniform float cloud_shadow_min : hint_range(0.0, 1.0, 0.001) = 0.2; // Minimum light value clouds can cast
uniform float cloud_diverge_angle : hint_range(0.0, 45.0, 0.001) = 10.0; // Angle at which the two noises split from each other

#include "res://Shaders/2D/clouds2d.gdshaderinc"

group_uniforms colours_and_textures;
uniform sampler2D albedo_texture : source_color, filter_nearest; // Sprite for main grass quad
uniform vec4 albedo_texture_region; // Atlas region (x, y, w, h) in pixels; (0,0,0,0) = full texture
uniform vec4 albedo1 : source_color = vec4(1.0); // Colour for main grass quad

	group_uniforms colours_and_textures.albedo2;
uniform vec4 albedo2 : source_color = vec4(1.0); // Colour for grass patch 2
uniform float albedo2_scale : hint_range(0.0, 1.0, 0.001) = 0.005; // Scale for grass patch 2 noise
uniform float albedo2_threshold : hint_range(0.0, 1.0, 0.001) = 0.604; // Threshold for grass patch 2 noise
uniform sampler2D albedo2_noise : repeat_enable; // Noise pattern for grass patch 2

	group_uniforms colours_and_textures.albedo3;
uniform vec4 albedo3 : source_color = vec4(1.0); // Colour for grass patch 3
uniform float albedo3_scale : hint_range(0.0, 0.1, 0.001) = 0.003; // Scale for grass patch 3 noise
uniform float albedo3_threshold : hint_range(0.0, 1.0, 0.001) = 0.661; // Threshold for grass patch 3 noise
uniform sampler2D albedo3_noise : repeat_enable; // Noise pattern for grass patch 3

	group_uniforms colours_and_textures.accent1;
uniform float accent_frequency1 : hint_range(0.0, 0.05, 0.0001) = 0.001; // Frequency of accent grass 1
uniform sampler2D accent_texture1 : source_color, filter_nearest; // Sprite for accent grass 1
uniform vec4 accent_texture1_region; // Atlas region (x, y, w, h) in pixels; (0,0,0,0) = full texture
uniform vec4 accent_albedo1 : source_color = vec4(1.0); // Colour for accent grass 1
uniform float accent_height1 : hint_range(0.0, 1.0, 0.001) = 0.5; // Height for accent grass 1
uniform float accent_scale1 : hint_range(0.0, 2.0, 0.001) = 1.0; // Scale (xy) for accent grass 1

	group_uniforms colours_and_textures.accent2;
uniform float accent_probability2 : hint_range(0.0, 0.05, 0.0001) = 0.1; // Frequency of accent grass 2
uniform sampler2D accent_texture2 : source_color, filter_nearest; // Sprite for accent grass 2
uniform vec4 accent_texture2_region; // Atlas region (x, y, w, h) in pixels; (0,0,0,0) = full texture
uniform vec4 accent_albedo2 : source_color = vec4(1.0); // Colour for accent grass 2
uniform float accent_height2 : hint_range(0.0, 1.0, 0.001) = 0.5; // Height for accent grass 2
uniform float accent_scale2 : hint_range(0.0, 2.0, 0.001) = 1.0; // Scale (xy) for accent grass 2


group_uniforms animation;
uniform float framerate = 5.0; // Framerate for worldspace and viewspace grass animation
uniform bool quantised = true; // Toggle quantised framerate
uniform float world_scale = 96.0; // Divides world position to normalize pixel coords for noise sampling
	group_uniforms animation.world_space;
uniform bool world_space_sway = true; // Toggle world space sway
uniform bool debug_noise = false; // Toggle colour debugging for world space sway
uniform float wind_sway_pixels : hint_range(0.0, 20.0, 0.1) = 5.0; // Maximum pixel offset from wind sway
uniform float fake_perspective_scale : hint_range(-0.15, 0.6, 0.001) = 0.3; // Intensity of fake perspective effect
uniform sampler2D wind_noise : repeat_enable; // Noise for world space sway
uniform float wind_noise_threshold : hint_range(-1.0, 1.0, 0.001) = 0.365; // Brightness of wind noise (see debug mode)
uniform float wind_noise_scale : hint_range(0.0, 0.1, 0.001) = 0.071; // Scale of wind noise (see debug mode)
uniform float wind_noise_speed : hint_range(0.0, 0.2, 0.001) = 0.025; // Speed of wind noise movement (see debug mode)
uniform vec2 wind_noise_direction = vec2(0.0, 1.0); // Worldspace xy direction of wind (see debug mode)
uniform float noise_diverge_angle : hint_range(0.0, 45.0, 0.001) = 10.0; // Angle at which the two noises split from each other
	group_uniforms animation.view_space;
uniform bool view_space_sway = true; // Toggle viewspace oscillation
uniform float view_sway_speed : hint_range(0.0, 5.0) = 0.1; // Speed of swaying in cycles per second
uniform float view_sway_pixels : hint_range(0.0, 10.0, 0.1) = 2.0; // Maximum pixel offset from view sway

group_uniforms displacement;
uniform bool displacement_enabled = false;
uniform sampler2D terrain_data_texture : filter_nearest;
uniform vec4 terrain_bounds;
uniform float displacement_pixels : hint_range(0.0, 30.0, 0.1) = 12.0;
uniform float displacement_y_factor : hint_range(0.0, 1.0, 0.01) = 0.3;


varying float wind_noise_sample;
varying vec2 world_origin; // Instance world position
varying float id_seed1;
varying float id_seed2;

float location_seed(vec2 location) { // Random value based on world space location
	return fract(sin(dot(location, vec2(12.9898, 78.233))) * 43758.5453123);
}

float random(float n) {
	return fract(sin(n * 12.9898) * 43758.5453);
}

vec2 atlas_uv(vec2 local_uv, vec4 region_px, sampler2D tex) {
	if (region_px.z <= 0.0) return local_uv;
	vec2 tex_size = vec2(textureSize(tex, 0));
	return (region_px.xy + local_uv * region_px.zw) / tex_size;
}

void vertex() {
	// Read accent seeds from INSTANCE_CUSTOM
	id_seed1 = INSTANCE_CUSTOM.x;
	id_seed2 = INSTANCE_CUSTOM.y;

	// Shear factor from UV — UV.y=0 at base, UV.y=1 at top (bottom stays anchored)
	float height_factor = UV.y;

	//// Accent 1
	// 2D adaptation — scale first, then offset upward (negative Y = up on screen)
	if (id_seed1 < accent_frequency1) {
		VERTEX *= accent_scale1;
		VERTEX.y -= accent_height1;
	}
	// Accent 2
	else if (id_seed2 < accent_probability2) {
		VERTEX *= accent_scale2;
		VERTEX.y -= accent_height2;
	}

	// Find origin of each grass instance in world-space (2D adaptation)
	world_origin = (MODEL_MATRIX * vec4(0.0, 0.0, 0.0, 1.0)).xy;

	// Normalize world position for noise sampling
	vec2 normalized_pos = world_origin / world_scale;

	// Generate a random seed based on the objects world position
	float seed = 10.0 * location_seed(normalized_pos);
	// Calculate time between frames
	float frametime = 1.0 / framerate;
	// Calculate randomised phase of framerate for each quad based on the world position
	// This so they don't all update on the same frame as that would just look laggy
	float phase = mod(seed, frametime);

	float time = TIME;
	if (quantised) {
		// Offset framerate update based on objects unique phase
		time += phase;
		// Quantise the time to create a stepped framerate
		time = round(time * framerate) / framerate;
	}

	// 2D adaptation — dual noise sampling using normalized_pos instead of object_origin.xz
	// Rotate wind noise direction left and right
	vec2 wind_noise_direction1 = rotate_vec2(wind_noise_direction, noise_diverge_angle);
	vec2 wind_noise_direction2 = rotate_vec2(wind_noise_direction, -noise_diverge_angle);
	// Scroll noises using time
	vec2 wind_noise_time_direction1 = time * wind_noise_speed * normalize(wind_noise_direction1);
	vec2 wind_noise_time_direction2 = time * wind_noise_speed * normalize(wind_noise_direction2);
	// Sample noise value (change speed and scale of 2nd one to avoid obvious repeating of texture)
	float wind_noise_sample1 = texture(wind_noise, normalized_pos * wind_noise_scale + wind_noise_time_direction1).r;
	float wind_noise_sample2 = texture(wind_noise, normalized_pos * (wind_noise_scale * 0.8) + (wind_noise_time_direction2 * 0.89 * PI / 3.0)).r;
	// Combine noise samples
	wind_noise_sample = (wind_noise_sample1 * wind_noise_sample2);
	wind_noise_sample = clamp(wind_noise_sample + wind_noise_threshold, 0.0, 1.0);
	// Scale noise sample between -1.0 --> 1.0
	wind_noise_sample = (wind_noise_sample - 0.5) * 2.0;

	// World-space wind sway (2D adaptation — pixel offset instead of rotation)
	if (world_space_sway) {
		VERTEX.x += wind_noise_sample * wind_sway_pixels * height_factor;
	}

	// View-space oscillation (2D adaptation — pixel offset instead of rotation)
	if (view_space_sway) {
		float model_sway = sin((time + seed) * view_sway_speed * 2.0 * PI) * view_sway_pixels;
		VERTEX.x += model_sway * height_factor;
	}

	// Character displacement via terrain data texture
	if (displacement_enabled) {
		vec2 bounds_min = terrain_bounds.xy;
		vec2 bounds_size = terrain_bounds.zw - terrain_bounds.xy;
		vec2 terrain_uv = (world_origin - bounds_min) / bounds_size;

		if (terrain_uv.x >= 0.0 && terrain_uv.x <= 1.0 &&
			terrain_uv.y >= 0.0 && terrain_uv.y <= 1.0) {

			float strength = texture(terrain_data_texture, terrain_uv).r;

			if (strength > 0.01) {
				vec2 texel_size = 1.0 / vec2(textureSize(terrain_data_texture, 0));
				float dx = texture(terrain_data_texture, terrain_uv + vec2(texel_size.x, 0.0)).r
						  - texture(terrain_data_texture, terrain_uv - vec2(texel_size.x, 0.0)).r;
				float dy = texture(terrain_data_texture, terrain_uv + vec2(0.0, texel_size.y)).r
						  - texture(terrain_data_texture, terrain_uv - vec2(0.0, texel_size.y)).r;

				vec2 push_dir = -normalize(vec2(dx, dy) + vec2(0.0001));

				VERTEX.x += push_dir.x * strength * displacement_pixels * height_factor;
				VERTEX.y += abs(push_dir.x) * strength * displacement_pixels * displacement_y_factor * height_factor;
			}

			// G channel: grass coverage mask
			float grass_density = texture(terrain_data_texture, terrain_uv).g;
			VERTEX *= grass_density;
		} else {
			// Outside terrain bounds — hide blade
			VERTEX *= 0.0;
		}
	}
}

void fragment() {
	// UV fake perspective (2D adaptation — no camera direction dot product)
	vec2 uv = UV;
	// Flip UV.y — canvas_item has Y=0 at top, but textures are authored for spatial (Y=0 at bottom)
	uv.y = 1.0 - uv.y;
	// Scale UV.x around centre
	uv.x -= 0.5;
	if (world_space_sway) {
		// Get noise value and scale appropriately
		float perspective = wind_noise_sample * fake_perspective_scale;
		// Scale UV.x proportionally in the vertical axis
		uv.x *= (1.0 - uv.y) * perspective + 1.0;
	}
	// Convert back to normal after scaling
	uv.x += 0.5;
	// Clamp UV to stop tiling
	uv.x = clamp(uv.x, 0.0, 1.0);

	// Sample albedo texture based on above calculation
	vec4 albedo_tex = texture(albedo_texture, atlas_uv(uv, albedo_texture_region, albedo_texture));

	// 2D adaptation — sample colour variation noise using normalized world_origin
	vec2 normalized_pos = world_origin / world_scale;
	float albedo2_noise_tex = texture(albedo2_noise, normalized_pos * albedo2_scale).r;
	float albedo3_noise_tex = texture(albedo3_noise, normalized_pos * albedo3_scale).r;

	vec3 final_color = albedo1.rgb * albedo_tex.rgb;
	if (albedo2_noise_tex > albedo2_threshold) {
		final_color = albedo2.rgb * albedo_tex.rgb;
	} if (albedo3_noise_tex > albedo3_threshold) {
		final_color = albedo3.rgb * albedo_tex.rgb;
	}

	// Accent 1
	if (id_seed1 < accent_frequency1) {
		albedo_tex = texture(accent_texture1, atlas_uv(uv, accent_texture1_region, accent_texture1));
		final_color = accent_albedo1.rgb * albedo_tex.rgb;
	}
	// Accent 2
	else if (id_seed2 < accent_probability2) {
		albedo_tex = texture(accent_texture2, atlas_uv(uv, accent_texture2_region, accent_texture2));
		final_color = accent_albedo2.rgb * albedo_tex.rgb;
	}

	COLOR = vec4(final_color, albedo_tex.a);

	// Cloud shadows (2D adaptation — applied directly to COLOR)
	if (cloud_shadows_enabled) {
		COLOR.rgb *= get_cloud_noise_2d(world_origin);
	}

	// Debug noise mode
	if (debug_noise) {
		COLOR = vec4(vec3(wind_noise_sample), 1.0);
	}
}
