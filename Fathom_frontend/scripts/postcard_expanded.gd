extends PanelContainer
# postcard_expanded.gd

# ////////////////////////// General references ////////////////////////////////////
@export var title: String
@export var author: String
@export var content: String

# //////////////////////// Label references /////////////////////////////////////////////////
@onready var title_lbl: RichTextLabel = $HSplitContainer/label_title
@onready var author_lbl: Label = $label_author
@onready var content_lbl: RichTextLabel = $CanvasLayer/ScrollContainer/label_content
@onready var score_lbl: Label = $CanvasLayer2/VSplitContainer/PanelContainer/approval_rating_container/approval_rating

@onready var power_lbl: Label = $CanvasLayer2/VSplitContainer/PanelContainer/power_container/power_value
@onready var learned_lbl: Label = $CanvasLayer2/VSplitContainer/PanelContainer/knowledge_container/knowledge_value
@onready var surprised_lbl: Label = $CanvasLayer2/VSplitContainer/PanelContainer/surprise_container/surprise_value

# /////////////////////// Animation references ///////////////////////////////////////////
@onready var learned_anim: AnimatedSprite2D = $CanvasLayer/knowledge_anim
@onready var surprised_anim: AnimatedSprite2D = $CanvasLayer/shock_anim
@onready var power_anim: AnimatedSprite2D = $power_anim 
@onready var upvote_anim: AnimatedSprite2D = $CanvasLayer/approval_anim
@onready var downvote_anim: AnimatedSprite2D = $CanvasLayer/disapproval_anim

# //////////////////////// button references ////////////////////////////////////////
@onready var open_button: Button = %Button
@onready var up_btn: Button = $CanvasLayer/approval_anim/Button
@onready var down_btn: Button = $CanvasLayer/disapproval_anim/Button
@onready var learned_btn: Button = $CanvasLayer/knowledge_anim/Button
@onready var surprised_btn: Button = $CanvasLayer/shock_anim/Button
@onready var power_btn: Button = %power_anim/Button # broken reference not currently used

@onready var feed_container: VBoxContainer = $CanvasLayer/feed_scroll/feed_container
@onready var expanded_card: PanelContainer = $CanvasLayer/expanded_card

var _post_id: int = -1
var _topic: String = ""
var _brief: String = ""

var _learned := false
var _surprised := false
var _learned_count := 0
var _surprised_count := 0
var _my_vote: int = 0 # -1, 0, 1
var _score: int = 0
var _powered: bool = false
var _power_count: int = 0
var _power_threshold: int = 1  # server can override

var card_mode = true
var symbol := "@" 
var approval_pressed = false
var disapproval_pressed = false
var comment_pressed = false
var knowledge_pressed = false
var shock_pressed = false
var power_pressed = false

signal vote_requested(post_id: int, value: int)  # 1, 0, -1
signal expand_requested(post_id: int, topic: String, brief: String)
signal react_requested(post_id: int, kind: String, value: bool)
signal power_requested(post_id: int, enabled: bool)



func _ready() -> void:
	if is_instance_valid(title_lbl): title_lbl.text = title
	if is_instance_valid(author_lbl): author_lbl.text = "by " + author
	if is_instance_valid(content_lbl): content_lbl.text = content
	$CanvasLayer/approval_anim/Button.connect("pressed", Callable(self, "button_pressed_approval"))
	$CanvasLayer/disapproval_anim/Button.connect("pressed", Callable(self, "button_pressed_disapproval"))

	$CanvasLayer/knowledge_anim/Button.connect("pressed", Callable(self, "button_pressed_knowledge"))
	$CanvasLayer/shock_anim/Button.connect("pressed", Callable(self, "button_pressed_shock"))

	$CanvasLayer2/Button.connect("pressed", Callable(self, "button_pressed_expanded_postcard"))

	_update_vote_ui()
	_update_reaction_ui()

func button_pressed_postcard():
	print("postcard button pressed")
	if GlobalVariables.card_expanded:
		pass
	else:
		GlobalVariables.card_expanded = true
		if _post_id == -1: 
			return
		emit_signal("expand_requested", _post_id, _topic, _brief)
		print("expand requested", _post_id, _topic, _brief )

func button_pressed_approval():
	if _my_vote == 1:
		_emit_vote(0)   # clear upvote
	elif _my_vote == -1:
		_emit_vote(1)   # switch from downvote to upvote
	else:
		_emit_vote(1)   # set upvote

func button_pressed_disapproval():
	if _my_vote == -1:
		_emit_vote(0)   # clear downvote
	elif _my_vote == 1:
		_emit_vote(-1)  # switch from upvote to downvote
	else:
		_emit_vote(-1)  # set downvote

func button_pressed_knowledge():
	print("knowledge pressed")
	var next := not _learned
	# optimistic update
	_learned = next
	_learned_count += 1 if next else -1
	_learned_count = max(0, _learned_count)
	_update_reaction_ui()
	# tell main.gd to POST
	if _post_id == -1:
		push_warning("ExpandedCard: reaction without valid _post_id (did show_post(data) run?)")
		return
	emit_signal("react_requested", _post_id, "learned", next)

func button_pressed_shock():
	print("shock pressed")
	var next := not _surprised
	_surprised = next
	_surprised_count += 1 if next else -1
	_surprised_count = max(0, _surprised_count)
	_update_reaction_ui()
	if _post_id == -1:
		push_warning("ExpandedCard: reaction without valid _post_id (did show_post(data) run?)")
		return
	emit_signal("react_requested", _post_id, "surprised", next)

func button_pressed_expanded_postcard():
	print("expanded_postcard button pressed")
	if GlobalVariables.card_expanded:
		GlobalVariables.card_expanded = false
		self.visible = false
	else:
		pass

func _set_power_pending(pending: bool) -> void:
	if power_btn:
		power_btn.disabled = pending

func get_post_id() -> int:
	return _post_id

func apply_reaction_result(learned_count: int, surprised_count: int, my_learned: bool, my_surprised: bool) -> void:
	_learned_count = learned_count
	_surprised_count = surprised_count
	_learned = my_learned
	_surprised = my_surprised
	_update_reaction_ui()

func set_post_data(post: Dictionary) -> void:
	_post_id = int(post.get("id", -1))
	_topic = str(post.get("topic", ""))
	_brief = str(post.get("text", ""))  # already cleaned in main.gd

	var v_score = post.get("score", 0)
	_score = (v_score if v_score != null else 0) as int

	var v_vote = post.get("my_vote", 0)
	if v_vote == null:
		_my_vote = 0
	else:
		_my_vote = int(v_vote)  

	# Update visuals (guard against nulls)
	if title_lbl:
		title_lbl.text = _topic
	if content_lbl:
		content_lbl.bbcode_enabled = false
		content_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD
		content_lbl.text = _brief
	if author_lbl:
		author_lbl.text = "by @" + _topic

	var lc = post.get("learned_count", 0)
	_learned_count = (lc if lc != null else 0) as int
	var sc = post.get("surprised_count", 0)
	_surprised_count = (sc if sc != null else 0) as int

	var ml = post.get("my_learned", null)
	_learned = (ml == true)
	var ms = post.get("my_surprised", null)
	_surprised = (ms == true)

	var pc = post.get("power_count", 0)
	_power_count = (pc if pc != null else 0) as int
	_powered = post.get("my_powered", false) == true
	if post.has("power_threshold"):
		var t = post.get("power_threshold")
		if t != null:
			_power_threshold = int(t)


	_update_reaction_ui()
	_update_vote_ui()

func _emit_vote(requested: int) -> void:
	print("beginning emit vote")
	if _post_id == -1:
		return
	# Optimistic preview
	var prev_my := _my_vote
	var prev_score := _score
	var next_my := requested
	if requested == 0 and prev_my == 1:
		_score = prev_score - 1
	elif requested == 0 and prev_my == -1:
		_score = prev_score + 1
	elif requested == 1 and prev_my == -1:
		_score = prev_score + 2
	elif requested == 1 and prev_my == 0:
		_score = prev_score + 1
	elif requested == -1 and prev_my == 1:
		_score = prev_score - 2
	elif requested == -1 and prev_my == 0:
		_score = prev_score - 1
	_my_vote = next_my
	_update_vote_ui()

	# Tell main.gd to POST; when the server replies, apply_vote_result() will reconcile
	emit_signal("vote_requested", _post_id, requested)
	print("vote emitted")

func _update_vote_ui() -> void:
	# Score
	if score_lbl:
		score_lbl.text = str(_score)
	if upvote_anim:
		upvote_anim.animation = "filled" if _my_vote == 1 else "blank"
		upvote_anim.play()
	if downvote_anim:
		downvote_anim.animation = "filled" if _my_vote == -1 else "blank"
		downvote_anim.play()

func _update_reaction_ui() -> void:
	if learned_lbl:   learned_lbl.text = str(_learned_count)
	if surprised_lbl: surprised_lbl.text = str(_surprised_count)

	if learned_anim:
		learned_anim.animation = "filled" if _learned else "blank"
		learned_anim.play()
	if surprised_anim:
		surprised_anim.animation = "filled" if _surprised else "blank"
		surprised_anim.play()

func _update_power_ui() -> void:
	if power_lbl:
		power_lbl.text = "%d / %d" % [_power_count, _power_threshold]
	if power_btn:
		power_btn.modulate.a = 1.0 if _powered else 0.7
	if power_anim:
		power_anim.animation = "fill_5" if _powered else "fill_0"
		power_anim.play()

func _update_all_ui():
	_update_reaction_ui()
	_update_vote_ui()

func apply_vote_result(new_score: int, my_vote: int) -> void:
	print("vote result triggered")
	_score = new_score
	_my_vote = my_vote
	_update_vote_ui()

func apply_power_result(power_count: int, my_powered: bool, power_threshold: int, triggered: bool, new_post_id: int) -> void:
	_power_count = power_count
	_powered = my_powered
	if power_threshold > 0:
		_power_threshold = power_threshold
	_update_power_ui()

	if triggered:
		# Visual celebration — optional
		#if power_anim:
		#	power_anim.animation = "burst"  # if you have one
		#	power_anim.play()
		print("[power] TRIGGERED → new_post_id=", new_post_id)


#//////////////////////// externally called functions ////////////////////////////////////////

func show_post(a: Variant, b: Variant = null) -> void:
	print("show post reached")
	var topic := ""
	var body  := ""

	if typeof(a) == TYPE_DICTIONARY and b == null:
		var data: Dictionary = a

		# Make sure the expanded card knows which post it is.
		# Accept "id" or "post_id" and tolerate strings/null.
		_post_id = _as_int(data.get("id", data.get("post_id", -1)), -1)

		# Topic & body (prefer expanded_text)
		topic = str(data.get("topic", ""))
		body  = str(data.get("expanded_text", data.get("text", "")))

		# Apply votes/reactions AFTER setting _post_id
		_apply_votes_and_reactions_from_data(data)
	else:
		# Legacy two-arg style
		topic = str(a)
		body  = str(b)

	# Update labels safely
	if title_lbl:
		title_lbl.text = "%s%s" % [symbol, topic]
	if content_lbl:
		content_lbl.text = body

	# Optional: warn if we still don't have an id (helps catch wiring issues)
	if _post_id == -1:
		push_warning("ExpandedCard.show_post: missing _post_id (did you pass the full data Dictionary?)")

	show()

func _apply_votes_and_reactions_from_data(data: Dictionary) -> void:
	# Flexible keys + null-safe conversion
	var upvotes: int   = _as_int(data.get("upvotes",      data.get("upvote_count", 0)))
	var downvotes: int = _as_int(data.get("downvotes",    data.get("downvote_count", 0)))
	_my_vote = clampi(_as_int(data.get("my_vote", 0)), -1, 1)  # -1/0/+1 only

	var v_score_raw = data.get("score", null)
	var v_score: int = _as_int(v_score_raw, upvotes - downvotes)
	_score = v_score

	_power_count    = _as_int(data.get("power_count",     data.get("powered_count",  data.get("power",     0))))
	_learned_count  = _as_int(data.get("knowledge_count", data.get("learned_count",  data.get("knowledge", 0))))
	_surprised_count = _as_int(
		data.get("surprised_count", data.get("surprise_count", data.get("surprise", 0)))
	)

	_powered   = _as_bool(data.get("my_powered",   false))
	_learned   = _as_bool(data.get("my_learned",   data.get("my_knowledge", false)))
	_surprised = _as_bool(data.get("my_surprised", data.get("my_surprise",   false)))

	# Optional: bulk payload for cards that support it
	var reaction_payload := {
		"votes": {
			"upvotes": upvotes,
			"downvotes": downvotes,
			"my_vote": _my_vote,
		},
		"reactions": {
			"power":     {"count": _power_count,    "active": _powered},
			"knowledge": {"count": _learned_count,  "active": _learned},
			"surprise":  {"count": _surprised_count,"active": _surprised},
		}
	}

	# Try updater methods if they exist
	if has_method("set_votes"):
		call("set_votes", upvotes, downvotes, _my_vote)

	if has_method("set_reaction"):
		call("set_reaction", "power",     _power_count,    _powered)
		call("set_reaction", "knowledge", _learned_count,  _learned)
		call("set_reaction", "surprise",  _surprised_count,_surprised)
	elif has_method("set_reactions"):
		call("set_reactions", reaction_payload)
	elif has_method("apply_reaction_state"):
		call("apply_reaction_state", reaction_payload)

	_update_all_ui()  # keep your UI refresh

func _as_int(v, default: int = 0) -> int:
	if v == null:
		return default
	if v is int:
		return v
	if v is float:
		return int(v)
	if v is bool:
		return (1 if v else 0)
	if v is String:
		var s := (v as String).strip_edges()
		if s == "":
			return default
		if s.is_valid_int():
			return int(s)
		if s.is_valid_float():
			return int(float(s))
	return default

func _as_bool(v, default: bool = false) -> bool:
	if v == null:
		return default
	if v is bool:
		return v
	if v is int:
		return v != 0
	if v is float:
		return absf(v) > 0.0
	if v is String:
		var s := (v as String).strip_edges().to_lower()
		if s in ["1", "true", "yes", "y", "on"]:
			return true
		if s in ["0", "false", "no", "n", "off", ""]:
			return false
	return default
