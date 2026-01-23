extends PanelContainer
# postcard.gd

@export var title: String
@export var author: String
@export var content: String

@onready var learned_anim: AnimatedSprite2D = $knowledge_anim
@onready var surprised_anim: AnimatedSprite2D = $shock_anim
@onready var power_anim: AnimatedSprite2D = $power_anim 

@onready var title_lbl: RichTextLabel = get_node_or_null("HSplitContainer/VSplitContainer/label_title")
@onready var author_lbl: Label = get_node_or_null("label_author")
@onready var content_lbl: RichTextLabel = get_node_or_null("MarginContainer/label_content")
@onready var score_lbl: Label = %approval_rating_container/approval_rating

@onready var power_lbl: Label = $power_container/power_value
@onready var learned_lbl: Label = $knowledge_container/knowledge_value
@onready var surprised_lbl: Label = $surprise_container/surprise_value

@onready var open_button: Button = %Button
@onready var up_btn: Button = %approval_anim/Button
@onready var down_btn: Button = %disapproval_anim/Button
@onready var surprised_btn: Button = %shock_anim/Button
@onready var learned_btn: Button = %knowledge_anim/Button
@onready var power_btn: Button = %power_anim/Button

@onready var avatar: AnimatedSprite2D = %avatar
@onready var feed_container: VBoxContainer = $CanvasLayer/feed_scroll/feed_container

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

var bean_dale_personality = ""
var card_mode = true

var approval_pressed = false
var disapproval_pressed = false
var comment_pressed = false
var knowledge_pressed = false
var shock_pressed = false
var power_pressed = false
 
signal spawn_expanded_card
signal vote_requested(post_id: int, value: int)  # 1, 0, -1
signal expand_requested(post_id: int, topic: String, brief: String)
signal react_requested(post_id: int, kind: String, value: bool)
signal power_requested(post_id: int, enabled: bool)


func _ready() -> void:
	if is_instance_valid(title_lbl): title_lbl.text = title
	if is_instance_valid(author_lbl): author_lbl.text = "by " + author
	if is_instance_valid(content_lbl): content_lbl.text = content

	$Button.connect("pressed", Callable(self, "button_pressed_postcard"))
	$approval_anim/Button.connect("pressed", Callable(self, "button_pressed_approval"))
	$disapproval_anim/Button.connect("pressed", Callable(self, "button_pressed_disapproval"))

	$knowledge_anim/Button.connect("pressed", Callable(self, "button_pressed_knowledge"))
	$shock_anim/Button.connect("pressed", Callable(self, "button_pressed_shock"))
	$power_anim/Button.connect("pressed", Callable(self, "button_pressed_power"))
	_update_reaction_ui()
	_update_power_ui()

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
	var anim = $approval_anim
	if _my_vote == 1:
		_emit_vote(0)   # clear upvote
	elif _my_vote == -1:
		_emit_vote(1)   # switch from downvote to upvote
	else:
		_emit_vote(1)   # set upvote

func button_pressed_disapproval():
	var anim = $disapproval_anim
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
	emit_signal("react_requested", _post_id, "learned", next)

func button_pressed_shock():
	print("shock pressed")
	var next := not _surprised
	_surprised = next
	_surprised_count += 1 if next else -1
	_surprised_count = max(0, _surprised_count)
	_update_reaction_ui()
	emit_signal("react_requested", _post_id, "surprised", next)

func button_pressed_power() -> void:
	print("[power] pre local _powered=", _powered)
	if _post_id == -1:
		return

	# Decide what we want to send based on the latest known server state
	var want_enable := not _powered

	# Optional: show a pending visual (spinner/alpha), but don't change counts yet
	_set_power_pending(true)  # make this a no-op if you don't have it

	print("[power] emitting with enabled=", want_enable)
	emit_signal("power_requested", _post_id, want_enable)

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

	_update_power_ui()
	_update_reaction_ui()
	_update_vote_ui()
	_assign_avatar_from_topic(_topic)

func _emit_vote(requested: int) -> void:
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

func _update_vote_ui() -> void:
	# Score
	var score_lbl: Label = $approval_rating_container/approval_rating
	if score_lbl:
		score_lbl.text = str(_score)

	# Animations (use whatever nodes you already have)
	var up_anim   = $approval_anim
	var down_anim = $disapproval_anim

	if up_anim:
		up_anim.animation = "filled" if _my_vote == 1 else "blank"
		up_anim.play()
	if down_anim:
		down_anim.animation = "filled" if _my_vote == -1 else "blank"
		down_anim.play()

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

func apply_vote_result(new_score: int, my_vote: int) -> void:
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

func _assign_avatar_from_topic(topic: String) -> void:
	if not avatar:
		return
	var t := topic.to_lower()
	match t:
		"space":         bean_dale_personality = "Ozlo"
		"cooking":       bean_dale_personality = "Thao"
		"biology":       bean_dale_personality = "Frank"
		"octopuses":     bean_dale_personality = "Frank"
		"neuroscience":  bean_dale_personality = "Mitch"
		"art":           bean_dale_personality = "Dakota"
		"history":       bean_dale_personality = "Frank"
		"computers":     bean_dale_personality = "Frank"
		"energy":        bean_dale_personality = "Guillermo"
		_:
			bean_dale_personality = ""
	if bean_dale_personality != "":
		pass

func assign_name():
	if title == "@space":
		bean_dale_personality = "Ozlo"
	elif title == "@cooking":
		bean_dale_personality = "Thao"
	elif title == "@biology":
		bean_dale_personality = "Frank"
	elif title == "@octopuses":
		bean_dale_personality = "Frank"
	elif title == "@neuroscience":
		bean_dale_personality = "Mitch"
	elif title == "@art":
		bean_dale_personality = "Dakota"
	elif title == "@history":
		bean_dale_personality = "Frank"
	elif title == "@computers":
		bean_dale_personality = "Frank"
	elif title == "@energy":
		bean_dale_personality = "Guillermo"
		print("anim name", bean_dale_personality)

	else:
		print("title: ", title)
		print("anim name", bean_dale_personality)
		print("anim name assignment failed")
	set_avatar_by_name(bean_dale_personality)

func set_avatar_by_name(bean_dale_personality):
	var anim = bean_dale_personality
	avatar.animation = anim
	avatar.play()
