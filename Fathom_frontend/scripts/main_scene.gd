extends Node2D
# main_scene

enum RequestKind { NONE, TOPIC, MIXED, SINGLE, MORE }
const OPENAI_ENDPOINT: String = "https://api.openai.com/v1/chat/completions"

var OPENAI_API_KEY
var PostCardScene := preload("res://UI_objects/postcard.tscn")
var FilterButtonScene := preload("res://UI_objects/button_agent_name.tscn")
var FullPostPopupScene := preload("res://UI_objects/postcard_expanded.tscn")
var _seen_ids: = {}	# Dictionary used as a set of { id: true }
var _suppress_scroll_once := false   
# child_id -> parent_id (used when a single post fetch returns)
var _insert_after_by_child_id := {}
const HALF_LIFE_H := 24.0
var _last_inserted_card: Control = null 

@onready var feed_container: VBoxContainer = $CanvasLayer/feed_scroll/feed_container
@onready var feed_scroll: ScrollContainer = $CanvasLayer/feed_scroll
@onready var ai_request: HTTPRequest = $CanvasLayer/ai_request
@onready var chat_scroll: ScrollContainer = $CanvasLayer/chat_scroll
@onready var group_chat: RichTextLabel = $CanvasLayer/chat_scroll/group_chat
@onready var agent_list: VBoxContainer = $CanvasLayer/agent_list

@onready var expand_req: HTTPRequest = $CanvasLayer/expand_request
@onready var expanded_card: PanelContainer = $CanvasLayer/expanded_card
@onready var vote_req: HTTPRequest = $CanvasLayer/vote_request
@onready var react_req: HTTPRequest = $CanvasLayer/react_request
@onready var power_req: HTTPRequest = $CanvasLayer/power_request

var _cards_by_id: Dictionary[int, Control] = {}

var _pending_expand_id: int = -1
var _last_request: int = RequestKind.NONE
var _last_topic: String = ""
var agents: Array = []
var available_names: Array = ["@/frisky_Biologist", "@/drunkMelon", "@/superbabyfoot337", "@/fiscalirresponsibility", "@/moouse", "@/elfnutz"]
var original_names := [
	"@/frisky_Biologist", "@/drunkMelon", "@/superbabyfoot337",
	"@/fiscalirresponsibility", "@/moouse", "@/elfnutz"
]
var name_pool: Array = []
var current_filter: String = ""
var message_buffer: Array = []
var research_tab_pressed = false
var topics := ["space", "cooking", "biology", "octopuses", "neuroscience", "art", "history", "computers", "energy"]
var topic_queue: Array = []
var fetching = false
var approval_pressed = false
const PAGE_SIZE := 30
const SCROLL_LOAD_THRESHOLD_PX := 200.0
var _paging_offset := 0
var _is_loading_more := false
var _end_of_feed := false



func _ready() -> void:
	GlobalVariables._ensure_device_id()
	randomize()
	topics.shuffle()
	topic_queue = topics.slice(0, 9)  # Grab 5 random topics
	_reset_name_pool()

	var vbar := feed_scroll.get_v_scroll_bar()
	if vbar and not vbar.is_connected("value_changed", Callable(self, "_on_feed_scroll_changed")):
		vbar.connect("value_changed", Callable(self, "_on_feed_scroll_changed"))

	react_req.connect("request_completed", Callable(self, "_on_ReactRequest_completed"))
	ai_request.connect("request_completed", Callable(self, "_on_RequestNode_request_completed"))
	expand_req.connect("request_completed", Callable(self, "_on_ExpandRequest_completed"))
	power_req.connect("request_completed", Callable(self, "_on_PowerRequest_completed"))
	vote_req.connect("request_completed", Callable(self, "_on_VoteRequest_completed"))

	expanded_card.connect("vote_requested", Callable(self, "_on_card_vote_requested"))
	expanded_card.connect("react_requested", Callable(self, "_on_card_react_requested"))

	fetch_mixed(20)
	#for child in $CanvasLayer.get_children():
		#if child.has_signal("said_something"):
			#_assign_agent_name(child)
			#agents.append(child)
			#child.connect("said_something", Callable(self, "_on_agent_said_something"))
			#_add_agent_button(child.agent_name)
	$CanvasLayer/button_research_tab.connect("pressed", Callable(self, "button_pressed_research_tab"))
	$CanvasLayer/button_call_AI_update.connect("pressed", Callable(self, "button_pressed_call_AI_update"))

# ////////////////////button setup /////////////////////////////////////
	$CanvasLayer/expanded_card/CanvasLayer2/Button.connect("pressed", Callable(self, "button_pressed_close_expanded_card"))

	$CanvasLayer/expanded_card/CanvasLayer/approval_anim/Button.connect("pressed", Callable(self, "button_pressed_approval"))
	$CanvasLayer/expanded_card/CanvasLayer/disapproval_anim/Button.connect("pressed", Callable(self, "button_pressed_disapproval"))

	$CanvasLayer/expanded_card/CanvasLayer/knowledge_anim/Button.connect("pressed", Callable(self, "button_pressed_knowledge"))
	$CanvasLayer/expanded_card/CanvasLayer/shock_anim/Button.connect("pressed", Callable(self, "button_pressed_shock"))

	# check to make sure expanded is off
	$CanvasLayer/expanded_card.visible = false
	$CanvasLayer/expanded_card/CanvasLayer.visible = false
	$CanvasLayer/expanded_card/CanvasLayer2.visible = false

func button_pressed_close_expanded_card():
	$CanvasLayer/expanded_card.visible = false
	$CanvasLayer/expanded_card/CanvasLayer.visible = false
	$CanvasLayer/expanded_card/CanvasLayer2.visible = false

func button_pressed_approval():
	var anim = $CanvasLayer/expanded_card/CanvasLayer/approval_anim
	if approval_pressed:
		approval_pressed = false
		anim.animation = "blank"
		anim.play()
	else:
		approval_pressed = true
		anim.animation = "filled"
		anim.play()

func button_pressed_disapproval():
	var anim = $CanvasLayer/expanded_card/CanvasLayer/disapproval_anim
	if approval_pressed:
		approval_pressed = false
		anim.animation = "blank"
		anim.play()
	else:
		approval_pressed = true
		anim.animation = "filled"
		anim.play()

func button_pressed_knowledge():
	var anim = $CanvasLayer/expanded_card/CanvasLayer/knowledge_anim
	if approval_pressed:
		approval_pressed = false
		anim.animation = "blank"
		anim.play()
	else:
		approval_pressed = true
		anim.animation = "filled"
		anim.play()

func button_pressed_shock():
	var anim = $CanvasLayer/expanded_card/CanvasLayer/shock_anim
	if approval_pressed:
		approval_pressed = false
		anim.animation = "blank"
		anim.play()
	else:
		approval_pressed = true
		anim.animation = "filled"
		anim.play()

func _on_feed_scroll_changed(value: float) -> void:
	var vbar := feed_scroll.get_v_scroll_bar()
	if vbar == null:
		return
	var distance_to_bottom := vbar.max_value - (value + vbar.page)
	if distance_to_bottom <= SCROLL_LOAD_THRESHOLD_PX:
		_maybe_fetch_more()

func _safe_int(v: Variant, default: int = 0) -> int:
	if v == null:
		return default
	if typeof(v) == TYPE_INT:
		return v
	if typeof(v) == TYPE_FLOAT:
		return int(v)
	if typeof(v) == TYPE_STRING:
		return (v as String).to_int()
	return default

func _safe_bool(v, default: bool=false) -> bool:
	if v == null: return default
	if v is bool: return v
	if v is int: return v != 0
	if v is float: return absf(float(v)) > 0.0
	if v is String:
		var s := (v as String).strip_edges().to_lower()
		if s in ["1","true","yes","y","on"]: return true
		if s in ["0","false","no","n","off",""]: return false
	return default

func _pick_int(d: Dictionary, keys: Array, default: int=-1) -> int:
	for k in keys:
		if d.has(k) and d[k] != null:
			return _safe_int(d[k], default)
	return default

func _pick_bool(d: Dictionary, keys: Array, default: bool=false) -> bool:
	for k in keys:
		if d.has(k) and d[k] != null:
			return _safe_bool(d[k], default)
	return default


func _nz(v, fallback):
	# Return fallback if the key exists but is null
	return fallback if v == null else v

func _to_int(v) -> int:
	if v == null: return 0
	# JSON numbers come back as float; coerce safely
	if typeof(v) == TYPE_FLOAT or typeof(v) == TYPE_INT:
		return int(v)
	return int(str(v)) if str(v).is_valid_int() else 0

func _rank_posts_in_place(arr: Array) -> void:
	# compute max popularity for normalization
	var pop_max := 1.0
	for p in arr:
		if typeof(p) == TYPE_DICTIONARY:
			var pop := float(p.get("score", 0)) \
				+ 0.5 * float(p.get("learned_count", 0) + p.get("surprised_count", 0)) \
				+ 0.25 * float(p.get("power_count", 0))
			if pop > pop_max: pop_max = pop

	arr.sort_custom(Callable(self, "_cmp_post_rank").bind(pop_max))

func _cmp_post_rank(a: Dictionary, b: Dictionary, pop_max: float) -> bool:
	var ra := _post_rank(a, pop_max)
	var rb := _post_rank(b, pop_max)
	# return true if a should come BEFORE b (descending rank)
	return ra > rb

func _post_rank(p: Dictionary, pop_max: float) -> float:
	# recency
	var age_h: float = _age_hours_from_iso(str(p.get("timestamp", "")))
	var recency: float = _expf(-age_h / HALF_LIFE_H)

	# popularity (normalized)
	var pop: float = float(p.get("score", 0)) \
		+ 0.5 * float(p.get("learned_count", 0) + p.get("surprised_count", 0)) \
		+ 0.25 * float(p.get("power_count", 0))
	var denom: float = max(1.0, pop_max)
	var pop_n: float = pop / denom

	# personal (nullable flags -> bool)
	var my_powered: bool   = (p.get("my_powered", null) == true)
	var my_learned: bool   = (p.get("my_learned", null) == true)
	var my_surprised: bool = (p.get("my_surprised", null) == true)

	var mv = p.get("my_vote", null)   # could be -1, 0, 1, or null
	var my_vote: int = 1 if mv == 1 else (-1 if mv == -1 else 0)

	var personal: float = (1.0 if my_powered else 0.0) \
		+ 0.5 * (1.0 if my_learned else 0.0) \
		+ 0.5 * (1.0 if my_surprised else 0.0) \
		- (1.0 if my_vote == -1 else 0.0)

	return 0.5 * recency + 0.3 * pop_n + 0.2 * personal

# --- helpers ---

func _expf(x: float) -> float:
	# Avoid relying on a global exp(); use pow instead
	return pow(2.718281828, x)

func _age_hours_from_iso(ts: String) -> float:
	if ts == "":
		return 0.0
	var unix: float = _unix_from_iso_utc(ts)
	if unix <= 0.0:
		return 0.0
	var now_sec: float = float(Time.get_unix_time_from_system())
	return max(0.0, (now_sec - unix) / 3600.0)

func _unix_from_iso_utc(ts: String) -> float:
	# Normalize common ISO 8601 forms to "YYYY-MM-DD HH:MM:SS"
	var s := ts.strip_edges()
	if s.ends_with("Z"):
		s = s.substr(0, s.length() - 1)
	s = s.replace("T", " ")
	var dot := s.find(".")
	if dot != -1:
		s = s.substr(0, dot)
	var plus := s.find("+")
	if plus != -1:
		s = s.substr(0, plus)
	# Parse as UTC
	var dt := Time.get_datetime_dict_from_datetime_string(s, true)  # (string, from_utc)
	return float(Time.get_unix_time_from_datetime_dict(dt))

func _to_bool(v) -> bool:
	return false if v == null else bool(v)

func _normalize_post(p: Dictionary) -> Dictionary:
	var d := {}
	d["id"] = _to_int(p.get("id"))
	d["topic"] = str(p.get("topic", ""))
	d["text"] = str(p.get("text", ""))

	# voting
	d["score"] = _to_int(p.get("score"))
	d["upvotes"] = _to_int(p.get("upvotes"))
	d["downvotes"] = _to_int(p.get("downvotes"))
	# my_vote can be -1/0/1 OR null → default 0
	var mv = p.get("my_vote")
	d["my_vote"] = 0 if mv == null else _to_int(mv)

	# reactions
	d["learned_count"] = _to_int(p.get("learned_count"))
	d["surprised_count"] = _to_int(p.get("surprised_count"))
	d["my_learned"] = _to_bool(_nz(p.get("my_learned"), false))
	d["my_surprised"] = _to_bool(_nz(p.get("my_surprised"), false))

	# power
	d["power_count"] = _to_int(p.get("power_count"))
	d["my_powered"] = _to_bool(_nz(p.get("my_powered"), false))

	# expanded
	d["expanded_text"] = p.get("expanded_text")  # can be null; keep as-is
	d["expanded_at"] = p.get("expanded_at")      # can be null; keep as-is

	# timestamp (string) — keep raw unless you parse it later
	d["timestamp"] = str(p.get("timestamp", ""))

	return d

func _reset_name_pool():
	name_pool = original_names.duplicate()
	name_pool.shuffle()

func fetch_next_topic():
	if topic_queue.size() > 0:
		var next_topic = topic_queue.pop_front()
		fetching = true
		fetch_posts_for_topic(next_topic)
	else:
		print("✅ All topics fetched.")

func fetch_posts_for_topic(topic: String) -> void:
	if ai_request.get_http_client_status() != HTTPClient.STATUS_DISCONNECTED:
		print("⚠️ Skipping topic fetch; request already in-flight")
		return
	_last_request = RequestKind.TOPIC
	_last_topic = topic
	var url := "%s/posts?topic=%s" % [GlobalVariables.API_BASE, topic]
	print("🔗 GET", url)

	var headers_arr := GlobalVariables.api_headers()
	var headers := PackedStringArray()
	for h in headers_arr:
		headers.append(str(h))
	headers.append("Accept: application/json")

	var err := ai_request.request(url, headers, HTTPClient.METHOD_GET)
	if err != OK:
		print("Request failed to start: ", err)

func fetch_mixed(count: int = 20) -> void:
	if ai_request.get_http_client_status() != HTTPClient.STATUS_DISCONNECTED:
		print("⚠️ Skipping mixed fetch; request already in-flight")
		return
	_last_request = RequestKind.MIXED
	_last_topic = ""
	var url := "%s/posts/mixed?count=%d" % [GlobalVariables.API_BASE, count]
	print("🔗 GET", url)
	
	var headers_arr := GlobalVariables.api_headers()
	var headers := PackedStringArray()
	for h in headers_arr:
		headers.append(str(h))
	headers.append("Accept: application/json")

	var err := ai_request.request(url, headers, HTTPClient.METHOD_GET)
	if err != OK:
		print("Request failed to start: ", err)

func _maybe_fetch_more() -> void:
	if _is_loading_more or _end_of_feed:
		return
	# Make sure offset starts from how many cards we actually have
	if _paging_offset <= 0:
		_paging_offset = max(_paging_offset, $CanvasLayer/feed_scroll/feed_container.get_child_count())
	fetch_more()

func fetch_more() -> void:
	if ai_request.get_http_client_status() != HTTPClient.STATUS_DISCONNECTED:
		return
	_is_loading_more = true
	_last_request = RequestKind.MORE
	_suppress_scroll_once = true  # don’t jump to top on append

	var url := ""
	if _last_topic != "" and _last_topic != null:
		url = "%s/posts?topic=%s&limit=%d&offset=%d" % [GlobalVariables.API_BASE, _last_topic, PAGE_SIZE, _paging_offset]
	else:
		url = "%s/posts?limit=%d&offset=%d" % [GlobalVariables.API_BASE, PAGE_SIZE, _paging_offset]
	print("🔗 GET more ", url)

	var headers_arr := GlobalVariables.api_headers()
	var headers := PackedStringArray()
	for h in headers_arr:
		headers.append(str(h))
	headers.append("Accept: application/json")

	var err := ai_request.request(url, headers, HTTPClient.METHOD_GET)
	if err != OK:
		print("Request failed to start: ", err)
		_is_loading_more = false

func _on_RequestNode_request_completed(result: int, response_code: int, headers: Array, body: PackedByteArray) -> void:
	print("HTTP status:", response_code, "result:", result)

	# -------- decode body safely --------
	var json_string := body.get_string_from_utf8()
	if json_string.begins_with("\uFEFF"):
		json_string = json_string.substr(1)
	json_string = json_string.strip_edges()
	print("Body (first 400):", json_string.left(400))

	# -------- HTTP error guard --------
	if response_code != 200:
		print("Request failed with code:", response_code)
		if _last_request == RequestKind.MORE:
			_is_loading_more = false
		_last_request = RequestKind.NONE
		return

	# -------- parse JSON --------
	var parsed: Variant = JSON.parse_string(json_string)
	if parsed == null:
		# Extra diagnostics to find sneaky characters
		for i in range(min(json_string.length(), 200)):
			var c := json_string.unicode_at(i)
			if c < 32 and c not in [9, 10, 13]: # control char that isn't TAB/LF/CR
				print("⚠️ Control char at idx", i, " code:", c)
				break
		print("JSON parse failed")
		if _last_request == RequestKind.MORE:
			_is_loading_more = false
		_last_request = RequestKind.NONE
		return

	# We'll use this to detect end-of-feed for paging
	var returned_len := 0

	# -------- handle payload --------
	match typeof(parsed):
		TYPE_ARRAY:
			var arr: Array = parsed
			returned_len = arr.size()
			_rank_posts_in_place(arr)
			for post in arr:
				if typeof(post) == TYPE_DICTIONARY and post.has("id") and post.has("text") and post.has("topic"):
					var norm := _normalize_post(post)
					var id_val := int(norm.get("id", -1))
					if id_val == -1:
						continue
					var id_str := str(id_val)
					# skip duplicates we've already shown
					if _seen_ids.has(id_str):
						continue
					_seen_ids[id_str] = true

					# insert under parent if this was a spawned child
					if _insert_after_by_child_id.has(id_val):
						_insert_post_below(_insert_after_by_child_id[id_val], norm)
						_insert_after_by_child_id.erase(id_val)
					else:
						_add_feed_card(norm)

		TYPE_DICTIONARY:
			returned_len = 1
			var d: Dictionary = parsed
			if d.has("id") and d.has("text") and d.has("topic"):
				var norm := _normalize_post(d)
				var id_val := int(norm.get("id", -1))
				if id_val != -1:
					var id_str := str(id_val)
					if not _seen_ids.has(id_str):
						_seen_ids[id_str] = true
						if _insert_after_by_child_id.has(id_val):
							_insert_post_below(_insert_after_by_child_id[id_val], norm)
							_insert_after_by_child_id.erase(id_val)
						else:
							_add_feed_card(norm)
			else:
				print("Unexpected dict keys: ", d.keys())

		_:
			print("Unexpected JSON root type: ", typeof(parsed))

	# -------- paging bookkeeping (for /posts?limit=&offset=) --------
	if _last_request == RequestKind.MORE:
		_paging_offset += PAGE_SIZE
		_is_loading_more = false
		if returned_len < PAGE_SIZE:
			_end_of_feed = true

	# -------- conditional scroll behavior --------
	var should_scroll_top := false
	match _last_request:
		RequestKind.MIXED, RequestKind.TOPIC:
			should_scroll_top = not _suppress_scroll_once
		RequestKind.SINGLE, RequestKind.MORE:
			should_scroll_top = false
		_:
			should_scroll_top = false

	_suppress_scroll_once = false
	_last_request = RequestKind.NONE

	if should_scroll_top:
		await _scroll_to_top_deferred()
	else:
		print("[feed] skip scroll_to_top")

func _on_card_expand_requested(post_id: int, topic: String, brief: String) -> void:
	print("expanding card")
	$CanvasLayer/expanded_card.visible = true
	$CanvasLayer/expanded_card/CanvasLayer.visible = true
	$CanvasLayer/expanded_card/CanvasLayer2.visible = true
	_pending_expand_id = post_id
	# optimistic UI: show modal immediately
	expanded_card.call("show_post", topic, "Loading…")

	# POST /posts/{id}/expand (server caches expanded_text)
	var url := "%s/posts/%d/expand" % [GlobalVariables.API_BASE, post_id]
	var headers := GlobalVariables.api_headers()
	var body := JSON.stringify({})	# {} or {"force":true} to regenerate
	var err := expand_req.request(url, headers, HTTPClient.METHOD_POST, body)
	if err != OK:
		push_error("Expand request failed to start: %s" % err)
		expanded_card.call("show_post", "Error", "Failed to start request")

func _on_ExpandRequest_completed(_result: int, response_code: int, _headers: Array, raw: PackedByteArray) -> void:
	var s: String = raw.get_string_from_utf8()

	if response_code != 200:
		expanded_card.show_post("Error", "Failed to load: %d\n%s" % [response_code, s])
		_pending_expand_id = -1
		return

	var parsed: Variant = JSON.parse_string(s)
	if parsed == null or typeof(parsed) != TYPE_DICTIONARY:
		expanded_card.show_post("Error", "Bad response")
		_pending_expand_id = -1
		return

	# Cast to Dictionary after we’ve validated it’s a dictionary
	var data := parsed as Dictionary

	# Prefer expanded_text; fallback to text
	var expanded_text := str(data.get("expanded_text", ""))
	if expanded_text.is_empty():
		expanded_text = str(data.get("text", ""))
	data["expanded_text"] = expanded_text

	# Expanded card is already in the scene; just tell it to render & sync UI
	expanded_card.show_post(data)

	_pending_expand_id = -1

func _on_card_vote_requested(post_id: int, value: int) -> void:
	var url := "%s/posts/%d/vote" % [GlobalVariables.API_BASE, post_id]
	var headers := GlobalVariables.api_headers()  # MUST include X-User-Id
	var body := JSON.stringify({"value": value})

	# cancel previous if busy to avoid ERR_BUSY
	if vote_req.get_http_client_status() != HTTPClient.STATUS_DISCONNECTED:
		print("[vote] cancel previous; status=", vote_req.get_http_client_status())
		vote_req.cancel_request()

	print("[vote] POST ", url)
	print("[vote] headers=", headers)
	print("[vote] body=", body)

	var err := vote_req.request(url, headers, HTTPClient.METHOD_POST, body)
	print("[vote] err=", err)

func _on_VoteRequest_completed(result: int, response_code: int, headers: Array, raw: PackedByteArray) -> void:
	var s := raw.get_string_from_utf8()
	print("[vote] completed result=%d code=%d bytes=%d" % [result, response_code, raw.size()])
	print("[vote] response first 400=", s.left(400))

	if response_code != 200:
		print("[vote] error body=", s)
		return

	var parsed: Variant = JSON.parse_string(s)
	if parsed == null or typeof(parsed) != TYPE_DICTIONARY:
		print("[vote] bad JSON")
		return
	var data: Dictionary = parsed

	var post_id := _safe_int(data.get("id", -1), -1)
	var new_score := _safe_int(data.get("score", 0), 0)
	var my_vote := _safe_int(data.get("my_vote", 0), 0)

	print("[vote] parsed id=", post_id, " score=", new_score, " my_vote=", my_vote)

	var card: Control = _cards_by_id.get(post_id) as Control
	if card and card.has_method("apply_vote_result"):
		card.call("apply_vote_result", new_score, my_vote)
	

	expanded_card.call("apply_vote_result", new_score, my_vote)

func _on_card_react_requested(post_id: int, kind: String, value: bool) -> void:
	var url := "%s/posts/%d/react" % [GlobalVariables.API_BASE, post_id]
	var headers := GlobalVariables.api_headers()
	var payload := {"learned": value} if kind == "learned" else {"surprised": value}
	var body := JSON.stringify(payload)

	# avoid ERR_BUSY
	if react_req.get_http_client_status() != HTTPClient.STATUS_DISCONNECTED:
		react_req.cancel_request()

	var err := react_req.request(url, headers, HTTPClient.METHOD_POST, body)
	if err != OK:
		push_error("react request failed to start: %s" % err)

func _on_ReactRequest_completed(result: int, response_code: int, headers: Array, raw: PackedByteArray) -> void:
	var s := raw.get_string_from_utf8()
	print("[react] completed result=%d code=%d bytes=%d" % [result, response_code, raw.size()])
	print("[react] response first 400=", s.left(400))

	if response_code != 200:
		print("[react] error body=", s)
		return

	var parsed: Variant = JSON.parse_string(s)
	if parsed == null or typeof(parsed) != TYPE_DICTIONARY:
		print("[react] bad JSON")
		return
	var data: Dictionary = parsed

	# ---- Parse basics ----
	var post_id := _safe_int(data.get("id", data.get("post_id", -1)), -1)
	if post_id == -1:
		print("[react] missing post id in response")
		return

	# Counts (accept multiple possible keys)
	var power_count      := _pick_int(data, ["power_count", "powered_count", "power"], -1)
	var learned_count    := _pick_int(data, ["learned_count", "knowledge_count", "knowledge", "learned"], -1)
	var surprised_count  := _pick_int(data, ["surprised_count", "surprise_count", "surprise"], -1)

	# My state
	var my_powered       := _pick_bool(data, ["my_powered"], false)
	var my_learned       := _pick_bool(data, ["my_learned", "my_knowledge"], false)
	var my_surprised     := _pick_bool(data, ["my_surprised", "my_surprise"], false)

	print("[react] id=", post_id, " power=", power_count, " my_powered=", my_powered,
		  " learned=", learned_count, " my_learned=", my_learned,
		  " surprised=", surprised_count, " my_surprised=", my_surprised)

	# Build a payload (handy for apply_reaction_state/set_reactions)
	var reaction_payload := {
		"reactions": {
			"power":     {"count": (power_count     if power_count     >= 0 else null), "active": my_powered},
			"knowledge": {"count": (learned_count   if learned_count   >= 0 else null), "active": my_learned},
			"surprise":  {"count": (surprised_count if surprised_count >= 0 else null), "active": my_surprised},
		}
	}

	# ---- Update the small card (if present) ----
	var card: Control = _cards_by_id.get(post_id) as Control
	if card:
		_apply_reaction_result_to_card(card, power_count, my_powered, learned_count, my_learned, surprised_count, my_surprised, reaction_payload)

	# ---- Update the expanded card ----
	if expanded_card:
		_apply_reaction_result_to_card(expanded_card, power_count, my_powered, learned_count, my_learned, surprised_count, my_surprised, reaction_payload)

func _get_method_arity(obj: Object, method_name: String) -> int:
	var methods: Array[Dictionary] = obj.get_method_list()
	for m in methods:
		if not (m is Dictionary):
			continue
		var name: String = (m.get("name", "") as String)
		if name == method_name:
			# NOTE: m.get(...) returns Variant, so cast to Array explicitly
			var args: Array = (m.get("args", []) as Array)
			return args.size()
	return -1



func _call_apply_reaction_result(card: Object, kind: String, count: int, active: bool) -> bool:
	if not card.has_method("apply_reaction_result"):
		return false
	var arity: int = _get_method_arity(card, "apply_reaction_result")
	match arity:
		4:
			card.call("apply_reaction_result", kind, count, active, true)  # (kind, count, active, from_server)
			return true
		3:
			card.call("apply_reaction_result", kind, count, active)
			return true
		2:
			card.call("apply_reaction_result", kind, active)
			return true
		_:
			return false

func _apply_reaction_result_to_card(
	card: Control,
	power_count: int, my_powered: bool,
	learned_count: int, my_learned: bool,
	surprised_count: int, my_surprised: bool,
	reaction_payload: Dictionary
) -> void:
	# Prefer postcard bulk API when available and we have both counts.
	if _card_accepts_bulk_react(card) and learned_count >= 0 and surprised_count >= 0:
		card.call("apply_reaction_result", learned_count, surprised_count, my_learned, my_surprised)
		# postcard doesn't handle "power" — set it separately if the card supports it
		if power_count >= 0 and card.has_method("set_reaction"):
			card.call("set_reaction", "power", power_count, my_powered)
		return

	# Fallbacks for per-kind APIs
	if card.has_method("set_reaction"):
		if power_count     >= 0: card.call("set_reaction", "power",     power_count,     my_powered)
		if learned_count   >= 0: card.call("set_reaction", "knowledge", learned_count,   my_learned)
		if surprised_count >= 0: card.call("set_reaction", "surprise",  surprised_count, my_surprised)
		return

	if card.has_method("set_reactions"):
		card.call("set_reactions", reaction_payload); return

	if card.has_method("apply_reaction_state"):
		card.call("apply_reaction_state", reaction_payload)


func _get_method_args(obj: Object, method_name: String) -> Array[Dictionary]:
	var methods: Array[Dictionary] = obj.get_method_list()
	for m in methods:
		if (m.get("name", "") as String) == method_name:
			return (m.get("args", []) as Array) as Array[Dictionary]
	return []

func _card_accepts_bulk_react(card: Object) -> bool:
	if not card.has_method("apply_reaction_result"):
		return false
	var args := _get_method_args(card, "apply_reaction_result")
	if args.size() != 4: return false
	return int(args[0].get("type", TYPE_NIL)) == TYPE_INT \
		and int(args[1].get("type", TYPE_NIL)) == TYPE_INT \
		and int(args[2].get("type", TYPE_NIL)) == TYPE_BOOL \
		and int(args[3].get("type", TYPE_NIL)) == TYPE_BOOL

func _on_card_power_requested(post_id: int, enabled: bool) -> void:
	print("[power] sending enabled=", enabled, " (pre-toggle _powered state is handled inside the card)")
	var url := "%s/posts/%d/power" % [GlobalVariables.API_BASE, post_id]
	var headers := GlobalVariables.api_headers()
	var body := JSON.stringify({"enabled": enabled})

	if power_req.get_http_client_status() != HTTPClient.STATUS_DISCONNECTED:
		power_req.cancel_request()

	var err := power_req.request(url, headers, HTTPClient.METHOD_POST, body)
	print("[power] POST ", url, " err=", err, " body=", body)

func _on_PowerRequest_completed(result: int, response_code: int, headers: Array, body: PackedByteArray) -> void:
	print("[power] completed code=%d bytes=%d" % [response_code, body.size()])

	# --- decode body safely ---
	var json_string = body.get_string_from_utf8()
	if json_string.begins_with("\uFEFF"):
		json_string = json_string.substr(1)
	json_string = json_string.strip_edges()
	print("[power] body_first200=", json_string.left(200))

	# --- HTTP error guard ---
	if response_code != 200:
		print("[power] HTTP error:", response_code, " result:", result)
		return

	# --- parse JSON ---
	var parsed = JSON.parse_string(json_string)
	if parsed == null or typeof(parsed) != TYPE_DICTIONARY:
		print("[power] JSON parse failed or unexpected shape")
		return
	var d: Dictionary = parsed

	# --- extras from server (may be absent if backend not updated) ---
	var power_threshold = int(d.get("power_threshold", 0))
	var power_triggered = bool(d.get("power_triggered", false))
	var new_post_id = int(d.get("new_post_id", -1))

	# --- normalize post fields you need for UI ---
	var norm: Dictionary = {}
	if has_method("_normalize_post"):
		norm = _normalize_post(d)
	else:
		# minimal fallback if _normalize_post isn't available here
		norm["id"] = int(d.get("id", -1))
		norm["power_count"] = int(d.get("power_count", 0))
		norm["my_powered"] = bool(d.get("my_powered", false))

	var pid = int(norm.get("id", -1))
	var pcount = int(norm.get("power_count", 0))
	var mypow = bool(norm.get("my_powered", false))

	print("[power] parsed id=%s count=%d my_powered=%s threshold=%d triggered=%s new_post_id=%d" % [
		str(pid), pcount, str(mypow), power_threshold, str(power_triggered), new_post_id
	])

	# --- update the specific card UI via your card API ---
	var card: Node = null
	if has_method("_find_card_by_id"):
		card = _find_card_by_id(pid)
	if card and card.has_method("apply_power_result"):
		card.apply_power_result(pcount, mypow, power_threshold, power_triggered, new_post_id)
		if card.has_method("_set_power_pending"):
			card._set_power_pending(false)
	else:
		# Fallback: if you have a global updater, call it; otherwise warn.
		if has_method("_update_card_after_power"):
			_update_card_after_power(norm)  # if you implemented this elsewhere
		else:
			print("[power] warn: card not found/updater missing for id=", pid)

	# --- if threshold hit, fetch the newly created post right away ---
	if power_triggered and new_post_id > 0:
		print("[power] threshold hit! fetching new post id=", new_post_id)
		if has_method("_fetch_single_post"):
			_insert_after_by_child_id[new_post_id] = int(norm.get("id", -1))  # remember parent
			_fetch_single_post(new_post_id)
		else:
			# inline fetch fallback using ai_request (only if idle)
			if ai_request.get_http_client_status() == HTTPClient.STATUS_DISCONNECTED:
				var url = "%s/posts/%d" % [GlobalVariables.API_BASE, new_post_id]
				var headers2 = GlobalVariables.api_headers()
				var err = ai_request.request(url, headers2, HTTPClient.METHOD_GET)
				if err != OK:
					print("[power] inline single fetch failed to start: ", err)
	else:
		print("[power] no fetch (triggered=%s, new_post_id=%d)" % [str(power_triggered), new_post_id])

func _update_card_after_power(post: Dictionary) -> void:
	# Update the UI for that specific post id (powered state, counts, etc.)
	# Example:
	# var card = _find_card_by_id(post["id"])
	# if card: card.update_power(post["my_powered"], post["power_count"])
	pass

func _find_card_by_id(post_id: int) -> Node:
	for child in $CanvasLayer/feed_scroll/feed_container.get_children():
		if child.has_method("get_post_id") and child.get_post_id() == post_id:
			return child
		elif " _post_id" in child and child._post_id == post_id:
			return child
	return null

func _insert_post_below(parent_id: int, post: Dictionary) -> void:
	# First, add the card the usual way (it will append)

	_add_feed_card(post)

	# Then move it under the parent
	var card := _find_card_by_id(int(post["id"]))
	var parent_card := _find_card_by_id(parent_id)
	if not card or not parent_card:
		return

	var idx := $CanvasLayer/feed_scroll/feed_container.get_children().find(parent_card)
	if idx == -1:
		return

	# Move on the next frame to avoid any container layout “locked” warnings
	$CanvasLayer/feed_scroll/feed_container.call_deferred("move_child", card, idx + 1)
	_last_inserted_card = card
	call_deferred("_ensure_card_visible", card)

func _ensure_card_visible(card: Control) -> void:
	await get_tree().process_frame
	await get_tree().process_frame
	if is_instance_valid(feed_scroll) and is_instance_valid(card):
		feed_scroll.ensure_control_visible(card)

func _fetch_single_post(post_id: int) -> void:
	if ai_request.get_http_client_status() != HTTPClient.STATUS_DISCONNECTED:
		print("⚠️ Skipping single fetch; request already in-flight")
		return

	_last_request = RequestKind.SINGLE  # or make a distinct enum if you prefer
	_last_topic = ""
	_suppress_scroll_once = true

	var url := "%s/posts/%d" % [GlobalVariables.API_BASE, post_id]
	var headers_arr := GlobalVariables.api_headers()
	var headers := PackedStringArray()
	for h in headers_arr: headers.append(str(h))
	headers.append("Accept: application/json")

	print("🔗 GET", url)
	var err := ai_request.request(url, headers, HTTPClient.METHOD_GET)
	if err != OK:
		print("[power] single fetch failed to start: ", err)

func _scroll_to_top_deferred() -> void:
	# wait for layout
	await get_tree().process_frame
	await get_tree().process_frame
	# force both properties (some themes need both)
	feed_scroll.scroll_vertical = 0
	feed_scroll.get_v_scroll_bar().value = 0

func set_subject_filter(subject: String) -> void:
	current_filter = subject
	_clear_feed()

	if subject == "" or subject.strip_edges() == "":
		# mixed default
		fetch_mixed(20)
	else:
		# specific subject
		fetch_posts_for_topic(subject)

func _clear_feed() -> void:
	for child in feed_container.get_children():
		child.queue_free()

func _build_subject_buttons(subjects: Array) -> void:
	# add "All"
	var all_btn := Button.new()
	all_btn.text = "All"
	all_btn.pressed.connect(func():
		set_subject_filter("")
	)
	$CanvasLayer/Buttons.add_child(all_btn)

	for row in subjects:
		var s := str(row.get("subject", ""))
		if s == "":
			continue
		var btn := Button.new()
		btn.text = s
		btn.pressed.connect(func (subject := s):
			set_subject_filter(subject)
		)
		$CanvasLayer/Buttons.add_child(btn)

func _add_feed_card(post: Dictionary) -> void:
	print("[feed] post id=", post.get("id"), " my_powered=", post.get("my_powered"))
	var topic := str(post.get("topic", ""))
	var body  := str(post.get("text", ""))

	# 2) If body accidentally contains a bold header like [b]Topic[/b]:\n..., strip it
	var extracted := _maybe_strip_bold_header(body)
	if extracted.header != "" and topic == "":
		topic = extracted.header  # fallback if topic missing (shouldn’t happen)
	body = extracted.body
	var symbol := "@" 

	var card := PostCardScene.instantiate()
	card.call("set_post_data", post) 
	card.title = "%s%s" % [symbol, topic]
	card.author = "%s%s" % [symbol, topic]
	card.content = body
	_cards_by_id[post.get("id", -1) as int] = card
	feed_container.add_child(card)
	card.connect("expand_requested", Callable(self, "_on_card_expand_requested"))
	card.connect("vote_requested", Callable(self, "_on_card_vote_requested"))
	card.connect("react_requested", Callable(self, "_on_card_react_requested"))   # NEW
	card.connect("power_requested",  Callable(self, "_on_card_power_requested"))

func _fetch_and_insert_post(post_id: int, below_post_id: int) -> void:
	print("fetching new post")
	var url: String = "%s/posts/%d" % [GlobalVariables.API_BASE, post_id]
	var headers: PackedStringArray = GlobalVariables.api_headers()

	var tmp := HTTPRequest.new()
	add_child(tmp)
	tmp.set_meta("below_post_id", below_post_id)

	# Connect to a typed handler, passing `tmp` via bind so we can read its meta
	tmp.request_completed.connect(_on_new_post_fetched.bind(tmp))

	var err: int = tmp.request(url, headers, HTTPClient.METHOD_GET)
	if err != OK:
		push_error("fetch new post failed to start: %s" % err)

func _on_new_post_fetched(result: int, response_code: int, _headers: Array, body: PackedByteArray, tmp: HTTPRequest) -> void:
	var s: String = body.get_string_from_utf8()
	if response_code != 200:
		print("[power] fetch new post HTTP ", response_code, ": ", s)
		tmp.queue_free()
		return

	var parsed: Variant = JSON.parse_string(s)
	if parsed == null or typeof(parsed) != TYPE_DICTIONARY:
		print("[power] bad JSON for new post: ", s.left(200))
		tmp.queue_free()
		return

	var d: Dictionary = parsed
	var new_id: int = (d.get("id", -1) if d.has("id") else -1) as int
	if new_id <= 0:
		print("[power] missing id in new post")
		tmp.queue_free()
		return

	# Instance and wire the card
	var card: Control = PostCardScene.instantiate()
	card.call("set_post_data", d)
	card.connect("expand_requested", Callable(self, "_on_card_expand_requested"))
	card.connect("vote_requested",   Callable(self, "_on_card_vote_requested"))
	card.connect("react_requested",  Callable(self, "_on_card_react_requested"))
	card.connect("power_requested",  Callable(self, "_on_card_power_requested"))

	feed_container.add_child(card)
	_cards_by_id[new_id] = card

	# Insert directly below the original
	var orig_id: int = int(tmp.get_meta("below_post_id"))
	var orig_card: Control = _cards_by_id.get(orig_id) as Control
	if orig_card:
		var idx: int = feed_container.get_child_index(orig_card)
		var new_idx: int = min(idx + 1, feed_container.get_child_count() - 1)
		feed_container.move_child(card, new_idx)

	tmp.queue_free()


#///////////////////////////////////// probably defunct code :( /////////////////////////////////////////////
func check_health() -> void:
	var url := "%s/healthz" % GlobalVariables.API_BASE
	var err := ai_request.request(url, GlobalVariables.api_headers(), HTTPClient.METHOD_GET)
	if err != OK:
		print("Health request failed to start: ", err)

func get_next_name() -> String:
	if name_pool.is_empty():
		_reset_name_pool()
	return name_pool.pop_back()

func _on_ai_response(result: int, response_code: int, headers: Array, body) -> void:
	if response_code != 200:
		print("Request failed with code: ", response_code)
		return

	var parser = JSON.new()
	if parser.parse(body.get_string_from_utf8()) != OK:
		print("JSON parse error: ", parser.get_error_message())
		return

	var parsed = parser.get_data()

	# FastAPI Response
	if typeof(parsed) == TYPE_ARRAY:
		if parsed.is_empty():
			print("No posts found.")
			return

		var seen_texts := {}  # This is a Set

		for post in parsed:
			if post.has("text") and post.has("topic"):
				var content = post["text"].strip_edges()
				if seen_texts.has(content):
					continue  # Skip duplicate
				seen_texts[content] = true

				var formatted_post = "[b]%s[/b]:\n%s" % [post["topic"], content]
				_add_feed_post(formatted_post)

		return

	# OpenAI Response (fallback structure)
	if typeof(parsed) == TYPE_DICTIONARY and parsed.has("choices"):
		var content = parsed.choices[0]["message"]["content"]
		_add_feed_post("AI: " + content)

func button_pressed_call_AI_update():
	print("call AI update pressed")
	request_ai_fact("biology")

func request_ai_fact(topic: String) -> void:
	var prompt := "Give me a concise, interesting fact about %s." % topic
	var payload := {
		"model": "gpt-4o-mini",
		"messages": [{"role": "user", "content": prompt}],
		"max_tokens": 60
	}
	# Serialize to JSON
	var json_out := JSON.new()
	var body := json_out.stringify(payload)
	# Prepare headers
	var headers := [
		"Content-Type: application/json",
		"Authorization: Bearer %s" % OPENAI_API_KEY
	]
	# Send POST: URL, headers, method=POST, body string
	ai_request.request(
		OPENAI_ENDPOINT,
		headers,
		HTTPClient.METHOD_POST,
		body
	)

func request_from_fastapi(topic: String):
	fetch_posts_for_topic(topic)

func _add_feed_post(text: String) -> void:
	var name := get_next_name()  
	print("Creating card for:", name)

	var card := PostCardScene.instantiate()
	card.title = name
	card.author = name
	card.content = text
	feed_container.add_child(card)
	card.connect("spawn_expanded_card", Callable(self, "_spawn_expanded_card"))
	# Wait one frame so child nodes are ready
	await get_tree().process_frame

	# Prove the method exists
	if not card.has_method("set_avatar_by_name"):
		push_error("PostCard missing set_avatar_by_name()")
		return

	# Prove the avatar node exists
	var avatar_node = card.get_node_or_null("avatar")
	print("Has avatar node?", avatar_node != null)

	# Call *deferred* to avoid any race with card _ready()
	card.call_deferred("set_avatar_by_name", name)

	var scroll := feed_container.get_parent()
	if scroll is ScrollContainer:
		scroll.scroll_vertical = feed_container.get_combined_minimum_size().y

func _maybe_strip_bold_header(s: String) -> Dictionary:
	# Case 1: [b]Header[/b]:\nBody...
	var re := RegEx.new()
	# (?m) multiline, (?s) dotall so '.' matches newlines, \R = any newline
	re.compile("(?ms)^\\[b\\](.+?)\\[/b\\]\\s*:?[ \\t]*\\R(.*)$")
	var m := re.search(s)
	if m:
		return {
			"header": m.get_string(1).strip_edges(),
			"body": m.get_string(2)
		}

	# Case 2: Plain "Header:\nBody..." (no BBCode)
	var re2 := RegEx.new()
	re2.compile("(?ms)^([A-Za-z0-9 _\\-/]+):\\s*\\R(.*)$")
	var m2 := re2.search(s)
	if m2:
		return {
			"header": m2.get_string(1).strip_edges(),
			"body": m2.get_string(2)
		}

	return { "header": "", "body": s }

func _on_RequestNode_request_completedOLD(result, response_code, headers, body):
	fetching = false

	if response_code != 200:
		print("Request failed with code: ", response_code)
		fetch_next_topic()
		return

	var json_string = body.get_string_from_utf8()
	var parsed = JSON.parse_string(json_string)

	if parsed == null or typeof(parsed) != TYPE_ARRAY:
		print("Failed to parse JSON: ", parsed)
		fetch_next_topic()
		return

	for post in parsed:
		if post.has("text") and post.has("topic"):
			var formatted_post = "[b]%s[/b]:\n%s" % [post["topic"], post["text"]]
			_add_feed_post(formatted_post)

	# 🔁 Move to next topic once done
	fetch_next_topic()

func button_pressed_research_tab():
	print("research_tab_button pressed")
	if research_tab_pressed:
		$CanvasLayer/label_researchers.visible = false
		$CanvasLayer/agent_list.visible = false
		research_tab_pressed = false
	else:
		$CanvasLayer/label_researchers.visible = true
		$CanvasLayer/agent_list.visible = true
		research_tab_pressed = true

func _assign_agent_name(child: Node) -> void:
	if available_names.size() > 0:
		var idx: int = randi() % available_names.size()
		child.agent_name = available_names[idx]
		available_names.remove_at(idx)

func get_random_name() -> String:
	if available_names.is_empty():
		return "Anonymous"
	var idx := randi() % available_names.size()
	# If you want no repeats until pool is exhausted, remove it:
	# var name := available_names[idx]
	# available_names.remove_at(idx)
	# return name
	return available_names[idx]

func _add_agent_button(name: String) -> void:
	var btn = FilterButtonScene.instantiate()
	btn.agent_name = name
	btn.connect("filter_toggled", Callable(self, "_on_agent_button_toggled"))
	agent_list.add_child(btn)

func _on_agent_button_toggled(agent_name: String, pressed: bool) -> void:
	current_filter = agent_name if pressed else ""
	_refresh_chat()

func _on_agent_said_something(message: String) -> void:
	# Create a PostCard entry
	var parts = message.split(":", false, 1)
	var author = parts[0]
	var content = parts[1].strip_edges() if parts.size() > 1 else message

	var card = PostCardScene.instantiate()
	card.title = "Title  " + author
	card.author = author
	card.content = content
	feed_container.add_child(card)
	card.connect("spawn_expanded_card", Callable(self, "_spawn_expanded_card"))

func _spawn_expanded_card(title, author, content):
	print("expanding card")
	# Instantiate the popup and set its content
	var spawn_parent = $CanvasLayer
	var popup = FullPostPopupScene.instantiate()
	popup.title = title
	popup.author = author
	popup.content = content
	# Add to the current scene tree (overlay on top)
	spawn_parent.add_child(popup)
	# Center and show the popup
	var pos = Vector2(0, 29)
	popup.position = pos
	popup.show()

func _refresh_chat() -> void:
	group_chat.clear()
	for msg in message_buffer:
		if current_filter == "" or msg.begins_with(current_filter + ":"):
			group_chat.append_text(msg + "\n")
	group_chat.scroll_to_line(group_chat.get_line_count() - 1)
