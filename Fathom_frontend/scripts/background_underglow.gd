extends ColorRect

@export var noise_a: Texture2D
@export var noise_b: Texture2D
@export var scroll_container: ScrollContainer          # optional (parallax)
@export var items_container: Control                   # optional (for under-card glow)
@export var use_card_underglow: bool = false          # toggle in Inspector
@export var enable_idle_pause: bool = true
@export var animate_on_start: bool = true

@onready var mat: ShaderMaterial = material as ShaderMaterial

var u_time: float = 0.0
var _acc: float = 0.0
const STEP := 1.0 / 30.0
var animate_until: float = 0.0

# Low-frequency update for card glow lines
var _line_acc: float = 0.0
const LINE_STEP := 0.25
const MAX_LINES := 8

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	if not mat:
		push_warning("UnderGlowBG: assign the UnderGlow.shader material to this node.")
		return

	mat.set_shader_parameter("noise_a", noise_a)
	mat.set_shader_parameter("noise_b", noise_b)
	mat.set_shader_parameter("use_card_underglow", use_card_underglow)

	# Set texel based on whichever noise exists (shader has a safe default)
	var sz: Vector2i
	if noise_a: sz = noise_a.get_size()
	elif noise_b: sz = noise_b.get_size()
	if sz.x > 0 and sz.y > 0:
		mat.set_shader_parameter("texel", Vector2(1.0 / float(sz.x), 1.0 / float(sz.y)))

	if animate_on_start or not enable_idle_pause:
		_wake_for(2.5)

	if scroll_container:
		scroll_container.gui_input.connect(_on_gui_input)

func _process(delta: float) -> void:
	# Optional: refresh under-card glow lines
	_line_acc += delta
	if _line_acc >= LINE_STEP:
		_update_card_lines()
		_line_acc = 0.0

	var now: float = Time.get_ticks_msec() * 0.001
	if enable_idle_pause and now > animate_until:
		return

	_acc += delta
	if _acc >= STEP:
		u_time += _acc
		mat.set_shader_parameter("time", u_time)
		if scroll_container:
			var sy: float = float(scroll_container.get_v_scroll_bar().value)
			mat.set_shader_parameter("scroll_y", sy)
		_acc = 0.0

func _on_gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.pressed: _wake_for(0.8)
	elif event is InputEventMouseMotion \
	or event is InputEventScreenDrag \
	or event is InputEventPanGesture \
	or event is InputEventMagnifyGesture:
		_wake_for(0.8)

func _update_card_lines() -> void:
	if not (use_card_underglow and mat and scroll_container and items_container):
		return

	var vbar := scroll_container.get_v_scroll_bar()
	var top: float = float(vbar.value)
	var view_h: float = scroll_container.size.y
	if view_h < 1.0: view_h = 1.0

	var ys := PackedFloat32Array()
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

func _wake_for(seconds: float) -> void:
	var now: float = Time.get_ticks_msec() * 0.001
	animate_until = max(animate_until, now + seconds)
