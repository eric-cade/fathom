shader_type canvas_item;

uniform sampler2D noise_a : source_color, repeat_enable;
uniform sampler2D noise_b : source_color, repeat_enable;
uniform sampler2D matcap_tex : source_color, repeat_disable;
uniform bool   use_matcap = true;

/* --- Mercury look & motion --- */
uniform float scale = 0.95;
uniform float speed_a = 0.16;
uniform float speed_b = -0.09;
uniform float distortion = 0.28;
uniform float normal_strength = 3.6;
uniform float ripple_amp = 0.13;
uniform float pulse_amp = 0.32;
uniform float pulse_hz = 0.35;

/* --- Shading --- */
uniform vec3  tint_color = vec3(0.86, 0.88, 0.92);
uniform float spec_power = 18.0;
uniform float spec_intensity = 2.0;
uniform float contrast = 1.12;
uniform float brightness = 0.01;

/* --- Perf helpers --- */
uniform vec2 texel = vec2(0.00390625, 0.00390625); // 1/256

/* --- Animation & parallax --- */
uniform float time = 0.0;
uniform float scroll_y = 0.0;
uniform float parallax = 0.0015;

/* --- Card-edge glints --- */
const int MAX_LINES = 8;
uniform bool use_card_glints = true;
uniform int  line_count = 0;
uniform float line_y[MAX_LINES];
uniform float line_width = 0.02;
uniform float glint_strength = 0.55;
uniform float glint_freq = 22.0;

/* --- Ripples (analytic, cheap) --- */
const int MAX_RIPPLES = 4;
uniform int   ripple_count = 0;                    // 0..MAX_RIPPLES
uniform vec2  ripple_pos[MAX_RIPPLES];            // UV space (0..1)
uniform float ripple_t[MAX_RIPPLES];              // start time (seconds)
uniform float ripple_life = 2.6;                  // sec
uniform float ripple_disp = 0.06;                 // UV displacement amplitude
uniform float ripple_wave = 0.35;                 // wavelength in UV units
uniform float ripple_speed = 1.6;                 // cycles/sec
uniform float ripple_decay = 2.2;                 // spatial decay
uniform float ripple_highlight = 0.18;            // add brightness on ring
uniform float ripple_highlight_decay = 3.2;       // how local the highlight is

vec3 get_normal(vec2 uv) {
	float hC1 = texture(noise_a, uv).r;
	float hX1 = texture(noise_a, uv + vec2(texel.x, 0.0)).r;
	float hY1 = texture(noise_a, uv + vec2(0.0, texel.y)).r;

	float hC2 = texture(noise_b, uv).r;
	float hX2 = texture(noise_b, uv + vec2(texel.x, 0.0)).r;
	float hY2 = texture(noise_b, uv + vec2(0.0, texel.y)).r;

	float hC = mix(hC1, hC2, distortion);
	float dx = mix(hX1 - hC1, hX2 - hC2, distortion);
	float dy = mix(hY1 - hC1, hY2 - hC2, distortion);

	return normalize(vec3(-dx * normal_strength, -dy * normal_strength, 0.5));
}

float glint_mask(vec2 uv) {
	if (!use_card_glints || line_count <= 0) return 0.0;
	float m = 0.0;
	for (int i = 0; i < MAX_LINES; i++) {
		if (i >= line_count) break;
		float dy = abs(uv.y - line_y[i]);
		float band = smoothstep(line_width, 0.0, dy);
		float shimmer = 0.6 + 0.4 * sin(glint_freq * uv.x + time * 2.2);
		m = max(m, band * shimmer);
	}
	return m;
}

/* Radial ripple offset + highlight contribution (sum of up to MAX_RIPPLES) */
vec3 ripple_effect(vec2 uv_base) {
	vec2 off = vec2(0.0);
	float hilite = 0.0;
	for (int i = 0; i < MAX_RIPPLES; i++) {
		if (i >= ripple_count) break;
		float t = time - ripple_t[i];
		if (t < 0.0 || t > ripple_life) continue;

		float life = 1.0 - (t / ripple_life);             // fades out
		vec2  dvec = uv_base - ripple_pos[i];
		float d = length(dvec) + 1e-5;
		vec2  dir = dvec / d;

		// wave phase: outward moving ring
		float phase = 6.2831853 * (d / ripple_wave - ripple_speed * t);
		float env = life * exp(-d * ripple_decay);
		float a = ripple_disp * env * sin(phase);

		off += dir * a;

		// small brightness kick near the crest
		float crest = max(0.0, cos(phase)); // 1 at crest
		hilite = max(hilite, crest * env * exp(-d * ripple_highlight_decay));
	}
	return vec3(off, hilite);
}

void fragment() {
	// Base UV & parallax (UV is 0..1 across the rect)
	vec2 uv0 = UV;
	vec2 uv = uv0 * scale + vec2(0.0, scroll_y * parallax);

	// Flow fields
	vec2 uv_a = uv + vec2(time * speed_a, 0.0);
	vec2 uv_b = uv + vec2(0.0, time * speed_b);

	float pulse = 1.0 + pulse_amp * sin(6.2831853 * pulse_hz * time);
	float w = texture(noise_b, uv_b).r;
	uv_a += (w - 0.5) * ripple_amp * pulse;

	// Ripples (operate in unscaled UV space, then apply to flow UVs)
	vec3 rip = ripple_effect(uv0);
	uv_a += rip.xy;

	vec3 N = get_normal(uv_a);
	vec3 base = tint_color;

	// Fresnel accent for chrome
	float fresnel = pow(1.0 - clamp(N.z, 0.0, 1.0), 1.6);

	vec3 color;
	if (use_matcap) {
		vec2 mUV = N.xy * 0.5 + 0.5;
		vec3 mc = texture(matcap_tex, mUV).rgb;
		vec3 chrome = mc * (0.85 + 0.15 * fresnel);
		color = mix(base, chrome, 0.92);
	} else {
		vec3 L = normalize(vec3(0.4, 0.55, 0.7));
		float ndl = max(dot(N, L), 0.0);
		float spec = pow(max(dot(reflect(-L, N), vec3(0.0, 0.0, 1.0)), 0.0), spec_power) * spec_intensity;
		color = base * (0.25 + 0.75 * ndl) + spec;
	}

	// Card-edge glints + ripple highlight
	float gl = glint_mask(uv0);
	color += gl * glint_strength + rip.z * ripple_highlight;

	color = (color - 0.5) * contrast + 0.5 + brightness;
	COLOR = vec4(color, 1.0);
}
