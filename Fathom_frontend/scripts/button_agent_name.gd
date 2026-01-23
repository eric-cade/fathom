extends Button
# agent_name button


@export var agent_name: String
signal filter_toggled(agent_name: String, pressed: bool)

func _ready() -> void:
	toggle_mode = true
	text = agent_name
	size_flags_horizontal = SIZE_EXPAND_FILL
	print("FilterButton ready for agent:", agent_name)
	connect("toggled", Callable(self, "_on_toggled"))

func _on_toggled(pressed: bool) -> void:
	print("button pressed")
	emit_signal("filter_toggled", agent_name, pressed)
