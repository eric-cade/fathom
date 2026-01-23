shader_type canvas_item;

uniform sampler2D noise_a : source_color, repeat_enable; // small tiling noise (e.g., 256x256)
uniform sampler2D noise_b : source_color, repeat_enable; // second noise (can reuse noise_a)

uniform float time     = 0.0;   // driven from script (u_time)
uniform float scroll_y = 0.0;   // optional parallax with feed
uniform float parallax = 0.0006;

/* --- Palette / theme --- */
uniform vec3 base_color   = vec3(0.035, 0.040, 0.055); // near-black blue
uniform vec3 star_color   = vec3(0.85, 0.90, 1.0);
uniform vec3 nebula_color = vec3(0.15, 0.20, 0.35);
uniform float vignette    = 0.35;   // 0..1 edge falloff

/* --- Nebula (very subtle) --- */
uniform float nebula_amp   = 0.20;  // 0..1 amount
uniform float nebula_scale = 0.65;  // tiling

/* --- Star field (static seeds + animated sparkle) --- */
uniform float star_scale   = 3.2;   // tiling (higher = denser field)
uniform float star_density = 0.12;  // 0..1 (typical 0.08–0.18)
uniform float star_sharp   = 8.0;   // bigger = smaller, crisper specks

/* --- Sparkle / crawl --- */
uniform float sparkle_speed = 0.40; // Hz
uniform float sparkle_amp   = 0.35; // blend between noise field & per-star sine
uniform float twinkle_scale = 1.8;  // tiling of the twinkle field
uniform float drift_x       = 0.02; // subtle field crawl
uniform float drift_y       = -0.015;

void fragment() {
	// Parallax hint so background “sticks” a touch while scrolling
	float vp = scroll_y * parallax;

	// --- Nebula base ---
	vec2 n_uv = UV * nebula_scale + vec2(0.0, vp) + vec2(time * drift_x * 0.2, time * drift_y * 0.2);
	float n1 = texture(noise_a, n_uv).r;
	float n2 = texture(noise_b, n_uv * 0.7 + vec2(0.0, 23.1)).r;
	float fog = smoothstep(0.2, 0.8, n1 * 0.6 + n2 * 0.4);
	vec3 color = mix(base_color, nebula_color, fog * nebula_amp);

	// --- Star seeds (static positions) ---
	vec2 s_uv = UV * star_scale + vec2(0.0, vp);
	float seed = texture(noise_a, s_uv).r;

	// Density → threshold
	float thresh = 1.0 - star_density;         // higher density => lower threshold
	float core = smoothstep(thresh, thresh + 0.02, seed); // soft step near threshold

	// --- Twinkle (animated, organic) ---
	// Per-star phase desync
	float phase = seed * 6.2831853;
	// Field that crawls slowly
	vec2 t_uv = UV * twinkle_scale + vec2(time * drift_x, time * drift_y);
	float tfield = texture(noise_b, t_uv).r;
	float psine  = 0.5 + 0.5 * sin(phase + time * 6.2831853 * sparkle_speed);
	// Blend: mostly the field, a bit of per-star sine
	float twinkle = mix(tfield, psine, sparkle_amp);
	// Gate sparkle so only specks flicker (keeps it subtle)
	float sparkle = smoothstep(0.78, 0.97, twinkle);

	// Tiny, crisp specks
	float star = pow(core, star_sharp) * sparkle;
	color += star_color * star;

	// --- Vignette ---
	vec2 c = UV - 0.5;
	float vig = 1.0 - vignette * dot(c, c) * 2.2;
	color *= clamp(vig, 0.0, 1.0);

	COLOR = vec4(color, 1.0);
}
