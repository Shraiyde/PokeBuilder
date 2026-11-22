class_name GfxFilter
## Graphics filter setting (0.1.52): the emulator look.
## Pizza Boy and other GBA emulators upscale the 240x160 frame with bilinear
## (linear) filtering, so pixels blend softly. Our game used Nearest everywhere
## (project default + explicit per-node NEAREST), so it looked blocky by comparison.
## This setting picks the filter every game sprite uses at creation time:
## smooth (Linear, the emulator look, default) or crisp (Nearest, the old look).
## Saved to user://graphics.json; the title-screen "Graphics" button flips it, and
## it takes effect for the next game session (sprites read it when created).
## Note: nodes that never set a filter (bag/PC/Pokédex pics) follow the project
## default, which is Linear since 0.1.52 — so in Crisp mode a few minor pics stay
## smooth while the map, characters, battles and menus go crisp. The SP skin is
## always Linear (it is a high-res image, not pixel art).

const PATH := "user://graphics.json"
static var _smooth: bool = true
static var _loaded: bool = false

static func _load() -> void:
	if _loaded:
		return
	_loaded = true
	if FileAccess.file_exists(PATH):
		var d: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(PATH))
		if d is Dictionary and d.has("smooth"):
			_smooth = bool(d["smooth"])

static func smooth() -> bool:
	_load()
	return _smooth

static func set_smooth(v: bool) -> void:
	_load()
	_smooth = v
	var f := FileAccess.open(PATH, FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify({"smooth": _smooth}))

static func filter() -> CanvasItem.TextureFilter:
	return CanvasItem.TEXTURE_FILTER_LINEAR if smooth() else CanvasItem.TEXTURE_FILTER_NEAREST

static func label() -> String:
	return "Graphics: Smooth" if smooth() else "Graphics: Crisp"
