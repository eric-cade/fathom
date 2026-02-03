extends Node2D

var card_expanded = false
var topics := ["space", "cooking", "biology", "octopuses", "neuroscience", "art", "history", "computers", "energy"]

var device_id: String = ""
var API_BASE := "https://apiservice-production-24ad.up.railway.app"
var API_KEY  := ""  

const USE_DUMMY_BACKEND := true

const API_BASE_REAL := "https://apiservice-production-24ad.up.railway.app"
const API_BASE_DUMMY := "http://127.0.0.1:8000"


func api_base() -> String:
	return API_BASE_DUMMY if USE_DUMMY_BACKEND else API_BASE_REAL

func _ensure_device_id() -> void:
	if device_id != "":
		return
	var cfg := ConfigFile.new()
	var path := "user://app.cfg"
	cfg.load(path)
	device_id = str(cfg.get_value("auth", "device_id", ""))
	if device_id == "":
		var rnd = Crypto.new().generate_random_bytes(16)
		device_id = rnd.hex_encode()
		cfg.set_value("auth", "device_id", device_id)
		cfg.save(path)

func api_headers() -> PackedStringArray:
	_ensure_device_id()

	# Dummy backend doesn't require API key
	if USE_DUMMY_BACKEND:
		return PackedStringArray([
			"Content-Type: application/json",
			"X-User-Id: %s" % device_id,
			"Accept: application/json",
		])

	# Real backend headers
	return PackedStringArray([
		"Content-Type: application/json",
		"X-API-Key: %s" % API_KEY,
		"X-User-Id: %s" % device_id,
		"Accept: application/json",
	])
