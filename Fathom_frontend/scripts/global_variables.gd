extends Node2D

var card_expanded = false
var topics := ["space", "cooking", "biology", "octopuses", "neuroscience", "art", "history", "computers", "energy"]

var device_id: String = ""
var API_BASE := "https://apiservice-production-24ad.up.railway.app"
var API_KEY  := ""  


func _ensure_device_id() -> void:
	if device_id != "":
		return
	var cfg := ConfigFile.new()
	var path := "user://app.cfg"
	cfg.load(path)  # OK if missing
	device_id = str(cfg.get_value("auth", "device_id", ""))
	if device_id == "":
		var rnd = Crypto.new().generate_random_bytes(16)
		device_id = rnd.hex_encode()
		cfg.set_value("auth", "device_id", device_id)
		cfg.save(path)

func api_headers() -> PackedStringArray:
	_ensure_device_id()
	return PackedStringArray([
		"Content-Type: application/json",
		"X-API-Key: %s" % API_KEY,
		"X-User-Id: %s" % device_id,
	])
