# LiquidMetalBG.gd — slim "mercury" BG with subtle, random ripples + optional card glints
extends ColorRect

# --- Textures & look ---
@export var noise_a: Texture2D
@export var noise_b: Texture2D
@export var matcap_tex: Texture2D
@export var use_matcap: bool = true

# --- Behavior ---
@export var enable_idle_pause: bool = true
@export var animate_on_start: bool = true

# Optional: if you want parallax on scroll_y (not required)
@export var scroll_container: ScrollContainer

# Optional: to draw glints under card bottoms (keep if you like the effect)
@export var items_container: Control  # VBoxContainer that holds your cards
@export var use_card_glints: bool = true
@export_range(0.005, 0.08, 0.001) var line_width: float = 0.02
@export_range(0.0, 1.5, 0.01) var glint_strength: float = 0.45
@export_range(2.0, 60.0, 0.5) var glint_freq: float = 20.0

# --- Ripple controls (subtle defaults) ---
@export var ripples_enabled: bool = true
@export_range(0.6, 8.0, 0.1) var ripple_spawn_interval: float = 3.2
@export_range(0.2, 8.0, 0.1) var ripple_life: float = 2.4
@export_range(0.00, 0.20, 0.005) var ripple_disp: float = 0.045
@export_range(0.10, 0.80, 0.01) var ripple_wave: float = 0.52
@export_range(0.4, 3.0, 0.1) var ripple_speed: float = 1.2
@export_range(0.3, 6.0, 0.1) var ripple_decay: float = 2.0
@export_range(0.0, 0.6, 0.02) var ripple_highlight: float = 0.14
@export_range(1.0, 8.0, 0.1) var ripple_highlight_decay: float = 3.0

# Where to spawn (simple & predictable)
# - gutter_bias: 0 = anywhere; 1 = only gutters. 0.6 gives a nice “most in gutters” feel.
@export_range(0.0, 1.0, 0.05) var gutter_bias: float = 0.6
# - gutter_hint: normalized width (%) of each side gutter if we can’t infer from items_container
@export_range(0.0, 0.45, 0.01) var gutter_hint: float = 0.12
# - y range to spawn within (0..1 of this ColorRect)
@export_range(0.0, 1.0, 0.01) var ripple_y_min: float = 0.0
@export_range(0.0, 1.0, 0.01) var ripple_y_max: float = 1.0

# --- Internals ---
@onready var mat: ShaderMaterial = material as ShaderMaterial

const MAX_RIPPLES := 4
var _ripple_pos: PackedVector2Array = PackedVector2Array()
var _ripple_t: PackedFloat32Array = PackedFloat32Array()
var _ripple_write_idx: int = 0
var _ripple_next_spawn_at: float = 0.0

var u_time: float = 0.0
var _acc: float = 0.0
const STEP := 1.0 / 30.0  # ~30 fps

var animate_until: float = 0.0
var _line_acc: float = 0.0
const LINE_STEP := 0.25    # glints update cadence
const MAX_LINES := 8       # must match shader

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	if not mat:
		push_warning("LiquidMetalBG: Assign a ShaderMaterial with the mercury shader to this node's Material.")
		return

	# Bind textures & look
	mat.set_shader_parameter("noise_a", noise_a)
	mat.set_shader_parameter("noise_b", noise_b)
	mat.set_shader_parameter("matcap_tex", matcap_tex)
	mat.set_shader_parameter("use_matcap", use_matcap)

	# Subtle ripple defaults
	mat.set_shader_parameter("ripple_life", ripple_life)
	mat.set_shader_parameter("ripple_disp", ripple_disp)
	mat.set_shader_parameter("ripple_wave", ripple_wave)
	mat.set_shader_parameter("ripple_speed", ripple_speed)
	mat.set_shader_parameter("ripple_decay", ripple_decay)
	mat.set_shader_parameter("ripple_highlight", ripple_highlight)
	mat.set_shader_parameter("ripple_highlight_decay", ripple_highlight_decay)

	# Texel size (keeps normal map sampling stable)
	var tex_sz: Vector2i
	if noise_a: tex_sz = noise_a.get_size()
	elif noise_b: tex_sz = noise_b.get_size()
	if tex_sz.x > 0 and tex_sz.y > 0:
		mat.set_shader_parameter("texel", Vector2(1.0 / float(tex_sz.x), 1.0 / float(tex_sz.y)))

	# Card-edge glints (optional)
	mat.set_shader_parameter("use_card_glints", use_card_glints)
	mat.set_shader_parameter("line_width", line_width)
	mat.set_shader_parameter("glint_strength", glint_strength)
	mat.set_shader_parameter("glint_freq", glint_freq)

	# Wake briefly so motion is visible on start
	if animate_on_start or not enable_idle_pause:
		_wake_for(2.5)

	# Optional click-to-spawn if you want it (cheap)
	if scroll_container:
		scroll_container.gui_input.connect(_on_feed_gui_input)

func _process(delta: float) -> void:
	# Glints refresh (cheap)
	_line_acc += delta
	if _line_acc >= LINE_STEP:
		_update_card_edge_lines()
		_line_acc = 0.0

	var now: float = Time.get_ticks_msec() * 0.001

	# Spawn before idle gate; ripples wake us when they appear
	if ripples_enabled and mat:
		if _ripple_next_spawn_at == 0.0:
			_ripple_next_spawn_at = now + _jittered_interval()
		elif now >= _ripple_next_spawn_at:
			_spawn_random_ripple()
			_ripple_next_spawn_at = now + _jittered_interval()

	# Feed current ripples (cheap); uses u_time basis
	_feed_ripples_to_shader()

	# Idle pause: skip heavy updates if sleeping
	if enable_idle_pause and now > animate_until:
		return

	# Battery-friendly time stepping
	_acc += delta
	if _acc >= STEP:
		u_time += _acc
		mat.set_shader_parameter("time", u_time)
		if scroll_container:
			var sy: float = float(scroll_container.get_v_scroll_bar().value)
			mat.set_shader_parameter("scroll_y", sy)
		_acc = 0.0

# ---------- RIPPLE SPAWN (simple & subtle) ----------

func _jittered_interval() -> float:
	# +/- 35% jitter so spawns feel organic
	return ripple_spawn_interval * randf_range(0.65, 1.35)

func _spawn_random_ripple() -> void:
	var uv := _random_uv_including_gutters()
	_spawn_ripple_uv(uv)

func _random_uv_including_gutters() -> Vector2:
	# U: either in gutters (weighted by gutter_bias) or anywhere
	var u: float
	var use_gutter: bool = randf() < gutter_bias
	if use_gutter:
		# Try infer gutters from items_container; else use gutter_hint
		var left_u_end: float = gutter_hint
		var right_u_start: float = 1.0 - gutter_hint
		if items_container:
			var inv: Transform2D = get_global_transform().affine_inverse()
			var gr: Rect2 = items_container.get_global_rect()
			var tl_local: Vector2 = inv * gr.position
			var br_local: Vector2 = inv * (gr.position + gr.size)
			if size.x > 1.0:
				left_u_end = clamp(tl_local.x / size.x, 0.0, 1.0)
				right_u_start = clamp(br_local.x / size.x, 0.0, 1.0)
		var left_w: float = left_u_end
		var right_w: float = 1.0 - right_u_start
		if left_w < 0.005 and right_w < 0.005:
			u = randf()  # no gutters, fall back
		elif randf() < (left_w / max(left_w + right_w, 0.0001)):
			u = randf_range(0.0, left_u_end)
		else:
			u = randf_range(right_u_start, 1.0)
	else:
		u = randf()

	# V: uniform (adjustable via y_min/y_max)
	var v_min: float = min(ripple_y_min, ripple_y_max)
	var v_max: float = max(ripple_y_min, ripple_y_max)
	var v: float = randf_range(v_min, v_max)
	return Vector2(u, v)

func _spawn_ripple_uv(uv: Vector2) -> void:
	# Store in u_time space so shader ages correctly
	var t: float = u_time
	if _ripple_pos.size() < MAX_RIPPLES:
		_ripple_pos.append(uv)
		_ripple_t.append(t)
	else:
		_ripple_pos[_ripple_write_idx] = uv
		_ripple_t[_ripple_write_idx] = t
		_ripple_write_idx = (_ripple_write_idx + 1) % MAX_RIPPLES
	_wake_for(1.0)

func _feed_ripples_to_shader() -> void:
	if not mat:
		return
	var kept_pos := PackedVector2Array()
	var kept_t := PackedFloat32Array()
	for i in _ripple_t.size():
		var age: float = u_time - _ripple_t[i]
		if age >= 0.0 and age <= ripple_life:
			kept_pos.append(_ripple_pos[i])
			kept_t.append(_ripple_t[i])
			if kept_t.size() >= MAX_RIPPLES:
				break
	# Pad to fixed size
	while kept_pos.size() < MAX_RIPPLES:
		kept_pos.append(Vector2(-10.0, -10.0))
		kept_t.append(-99999.0)
	var count: int = 0
	for i in kept_t.size():
		if kept_t[i] < 0.0: break
		count += 1
	mat.set_shader_parameter("ripple_count", count)
	mat.set_shader_parameter("ripple_pos", kept_pos)
	mat.set_shader_parameter("ripple_t", kept_t)

# ---------- OPTIONAL: click-to-spawn at pointer ----------
func _on_feed_gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.pressed:
			_wake_for(0.8)
			# Map from ScrollContainer local -> global -> this ColorRect local
			var global_pt: Vector2 = scroll_container.get_global_transform() * mb.position
			var local: Vector2 = get_global_transform().affine_inverse() * global_pt
			var u: float = clampf(local.x / max(size.x, 1.0), 0.0, 1.0)
			var v: float = clampf(local.y / max(size.y, 1.0), 0.0, 1.0)
			_spawn_ripple_uv(Vector2(u, v))

# ---------- OPTIONAL: card-edge glints ----------
func _update_card_edge_lines() -> void:
	if not (mat and scroll_container and items_container and use_card_glints):
		return
	var vbar := scroll_container.get_v_scroll_bar()
	var top: float = float(vbar.value)
	var view_h: float = max(scroll_container.size.y, 1.0)
	var ys: PackedFloat32Array = PackedFloat32Array()
	for child in items_container.get_children():
		var c := child as Control
		if c == null or not c.visible: continue
		var bottom: float = c.position.y + c.size.y
		if bottom >= top and bottom <= top + view_h:
			var norm: float = (bottom - top) / view_h
			if norm < 0.0: norm = 0.0
			elif norm > 1.0: norm = 1.0
			ys.append(norm)
			if ys.size() >= MAX_LINES: break
	mat.set_shader_parameter("line_count", ys.size())
	if ys.size() > 0:
		mat.set_shader_parameter("line_y", ys)

# ---------- tiny util ----------
func _wake_for(seconds: float) -> void:
	var now: float = Time.get_ticks_msec() * 0.001
	animate_until = max(animate_until, now + seconds)
