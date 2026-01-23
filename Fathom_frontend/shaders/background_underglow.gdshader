shader_type canvas_item;

uniform sampler2D noise_a : source_color, repeat_enable; // 256–512px tiling noise
uniform sampler2D noise_b : source_color, repeat_enable;

uniform float time = 0.0;
uniform float scroll_y = 0.0;
uniform float parallax = 0.0008;

/* Theme */
uniform vec3 base_color = vec3(0.020, 0.025, 0.032);  // near-black
uniform vec3 glow_color = vec3(0.26, 0.42, 0.78);     // cool blue underglow
uniform float vignette  = 0.28;                       // 0..1 edge darken

/* Underglow field */
uniform float glow_amount  = 0.55;  // overall intensity
uniform float glow_scale   = 0.85;  // bigger shapes < 1.0
uniform float flow_x       = 0.015; // slow drift
uniform float flow_y       = -0.010;
uniform float glow_power   = 2.2;   // raises contrast of blobs
uniform float pulse_amp    = 0.12;  // gentle breathing
uniform float pulse_hz     = 0.06;  // very slow

/* Optional: subtle underglow under card bottoms */
const int MAX_LINES = 8;
uniform bool  use_card_underglow = false;
uniform int   line_count = 0;
uniform float line_y[MAX_LINES];  // UV.y positions, 0..1
uniform float line_width = 0.035; // thickness of the band
uniform float line_strength = 0.22;

/* For cheap gradients (set from script if you can) */
uniform vec2 texel = vec2(0.00390625, 0.00390625); // 1/256

void fragment() {
    // Parallax so the glow “sticks” a touch while scrolling
    vec2 uv0 = UV;
    vec2 uv  = uv0 * glow_scale + vec2(0.0, scroll_y * parallax) + vec2(time * flow_x, time * flow_y);

    // Two blended noises → soft blob field (0..1)
    float a = texture(noise_a, uv).r;
    float b = texture(noise_b, uv * 0.67 + vec2(12.3, -7.1)).r;
    float f = a * 0.6 + b * 0.4;
    float blobs = smoothstep(0.30, 0.78, f);

    // Gentle breathing (regionally desynced by b)
    float pulse = 1.0 + pulse_amp * sin(6.2831853 * pulse_hz * time + b * 6.2831853);
    float glow = pow(blobs * pulse, glow_power) * glow_amount;

    // Optional: soft horizontal glow bands under cards
    if (use_card_underglow && line_count > 0) {
        float band_acc = 0.0;
        for (int i = 0; i < MAX_LINES; i++) {
            if (i >= line_count) break;
            float dy = abs(uv0.y - line_y[i]);
            band_acc = max(band_acc, smoothstep(line_width, 0.0, dy));
        }
        glow += band_acc * line_strength;
    }

    // Compose
    vec3 col = base_color + glow * glow_color;

    // Vignette
    vec2 c = uv0 - 0.5;
    float vig = 1.0 - vignette * dot(c, c) * 2.0;
    col *= clamp(vig, 0.0, 1.0);

    COLOR = vec4(col, 1.0);
}
