extends ColorRect

@export var noise_a: Texture2D
@export var noise_b: Texture2D
@export var scroll_container: ScrollContainer
@export var enable_idle_pause: bool = true
@export var animate_on_start: bool = true

@onready var mat: ShaderMaterial = material as ShaderMaterial

var u_time: float = 0.0
var _acc: float = 0.0
const STEP := 1.0 / 30.0
var animate_until: float = 0.0

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	if not mat:
		push_warning("StarfieldBG: assign the StarryCrawl shader material to this node.")
		return

	mat.set_shader_parameter("noise_a", noise_a)
	mat.set_shader_parameter("noise_b", noise_b)

	if animate_on_start or not enable_idle_pause:
		_wake_for(2.5)

	if scroll_container:
		scroll_container.gui_input.connect(_on_gui_input)

func _process(delta: float) -> void:
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

func _wake_for(seconds: float) -> void:
	var now: float = Time.get_ticks_msec() * 0.001
	animate_until = max(animate_until, now + seconds)
