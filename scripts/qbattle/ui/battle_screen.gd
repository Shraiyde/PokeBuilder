class_name BattleScreen
extends CanvasLayer
## BattleScreen — the battle UI driven by a BattleController, laid out like the GBA original (0.1.9).
## Everything is drawn inside one 240x160 "GBA stage", integer-scaled, centred and pillarboxed in black:
##   - the ROM battle background (rows 0-111 visible; the bottom 48 rows are the text box area);
##   - the Pokémon / trainer pictures decoded from the user's own ROM (KI-35, Stephen's decision 2026-10-31);
##   - healthboxes at the ROM positions (foe top-left, player bottom-right above the text box; doubles: two per
##     side). Name, gender, Lv, status, HP bar; the player's box also has HP numbers and an EXP bar. The ROM's
##     healthbox graphics are not located yet, so the boxes are plain neutral stand-ins of the same size (KI-53);
##   - the ROM's bottom 240x48 text box window, decoded from the ROM at import (sprites/battle_ui, see
##     SpriteImporter._import_battle_ui) and shown through the ui_provider hook. Three ROM layouts:
##       "msg"     one message, at most 2 lines at a time (longer ones page on), tap anywhere to advance;
##       "action"  "What will X do?" on the left, FIGHT / BAG / POKéMON / RUN on the right;
##       "moves"   the 4 moves on the left, PP and TYPE of the selected move on the right.
##     Without that data (old cache) a plain stand-in window of the same shape is drawn instead.
## Nothing else is drawn over the field. Text uses the project font (the ROM font is not decoded yet, KI-54).
## Touch: menu cells are large invisible buttons over the ROM's menu cells. One tap on a move (or on
## FIGHT / BAG / POKéMON / RUN) acts at once (0.1.11); the PP/TYPE window uses the move under the cursor.
## D-pad / A / B (0.1.11 controller): the D-pad moves the ▶ cursor (moves: also PP/TYPE), A confirms. In any sub-menu a tap on the field (outside the
## text box) or Android Back goes back, like the B button. Bag / Party / doubles targets reuse the "action"
## window (prompt left, choices right); Party shows a plain stand-in list over the field (the ROM opens a
## separate party screen there, KI-55).
## Pictures: this file never draws a character. When a hook is unset or returns null (old cache, decode
## failure) it falls back to the ORIGINAL placeholders (an abstract tinted blob) and shows a yellow debug line
## in the pillarbox ("pics: <reason>", also printed to logcat). Textures are memoised per screen (_tex_memo) and
## release_hook drops the decoder's in-memory copies when the screen leaves the tree. Nothing is written to disk.
## Doubles (offline only in this port; the source's co-op/online features were removed): 4 slots, menus act
## for our slot (my_slot), a target choice when a single-target move has two living foes.
## API: screen.setup(controller); host.add_child(screen); ... await screen.closed_after_end()
## Depends on: BattleController, BattleData, UiTheme, TapInput. Created by: BattleController._run().
## PORT NOTE: this file has NO load()/preload() calls and NO hardcoded res:// asset paths — every picture
## (Pokémon/trainer/player-back sprites, ROM text-box windows, battle background) arrives through the hooks
## above (sprite_provider, trainer_provider, player_back_provider, ui_provider) or set_background(), so the
## port supplies art by setting those hooks; there is nothing to re-point here. Classes this file still
## needs from the port (not yet present in battle-port/src): UiTheme, TapInput, GbaScreen, GfxFilter,
## GamePad, BagScreen, ItemUse, BattleData, BattleState. Already in the port: ItemHooks, BattleAI.

signal closed

## Optional sprite hook: func(species: int, back: bool[, shiny: bool]) -> Texture2D or null.
static var sprite_provider: Callable
## Optional: foe trainer picture by trainer pic id (BattleData trainer record "pic"): func(pic_id) -> Texture2D|null.
static var trainer_provider: Callable
## Optional: the local player's battle back picture: func(frame: int) -> Texture2D|null (frame 0 = standing,
## 1..player_back_frame_count-1 = the throw, played just before the player's first Pokémon appears).
static var player_back_provider: Callable
static var player_back_frame_count := 0
## Optional: called once when the screen leaves the tree (drops decoded textures held in memory).
static var release_hook: Callable
## Optional (0.1.6): func(species: int, back: bool) -> String, why a Pokémon picture is missing ("" = fine).
static var reason_provider: Callable
## Optional (0.1.9): ROM battle UI window, func(name: String) -> Texture2D|null; names "textbox_msg",
## "textbox_action", "textbox_moves" (240x48). Set by SpriteSource.install_battle_hooks.
static var ui_provider: Callable
## 0.1.14: the player's bag for BAG (set by ui/game.gd): {events: EventStore, progress: Progress}. Empty =
## the old BALL/CANCEL stand-in (tests without a game).
static var bag_source: Dictionary = {}
## 0.1.60: the game's AudioManager for send-out cries (set by ui/game.gd). Null = silent (tests without a game).
static var audio_node = null

const THROW_FRAME_TIME := 0.07  # seconds per player-back throw frame

# ---- GBA stage geometry (GBA pixels). Field geometry measured from the decoded ROM battle backgrounds
# (identical for all 10 terrains): foe platform x 112-239 y 48-79; player platform top y 101, x 4-124,
# running under the text box. Text box = the ROM window, bottom 48 rows.
const GBA := Vector2(240, 160)
const TEXTBOX_TOP := 112.0
const TEXTBOX := Rect2(0, 112, 240, 48)
const FOE_BASE := Vector2(176, 68)         # foe's feet: centre of its platform, a bit low
const PLAYER_BASE := Vector2(64, 112)      # player's back pic bottom: on the text-box edge over its platform
const FOE_PLATFORM := Rect2(112, 48, 128, 32)
const PLAYER_PLATFORM := Rect2(4, 101, 121, 11)   # the part visible above the text box
const SLOT_DX := 28.0                      # doubles: sideways offset of the two slots (see _anchor)
# Healthboxes (stand-ins at the ROM's positions/sizes). Singles: foe top-left, player bottom-right just above
# the text box. Doubles: two per side, stacked, kept clear of the four pictures (layout test --doubles).
const HB_SINGLE := {"1:0": Rect2(13, 16, 100, 29), "0:0": Rect2(126, 80, 104, 32)}
const HB_DOUBLE := {"1:0": Rect2(4, 2, 100, 22), "1:1": Rect2(14, 25, 100, 22),
	"0:0": Rect2(128, 68, 104, 21), "0:1": Rect2(136, 90, 104, 21)}
# Text box layouts (inside TEXTBOX). Text is placed on the ROM's two text rows (16 px apart).
const MSG_TEXT := Rect2(11, 119, 218, 36)        # message window text area
const PROMPT_TEXT := Rect2(11, 119, 104, 36)     # "What will X do?" (left window of the action layout)
const ACTION_CELLS := [Rect2(120, 112, 60, 24), Rect2(180, 112, 60, 24), Rect2(120, 136, 60, 24), Rect2(180, 136, 60, 24)]
const ACTION_TEXT_DX := 15.0                     # text starts 15 px into each action cell (cursor before it)
const MOVE_CELLS := [Rect2(0, 112, 80, 24), Rect2(80, 112, 80, 24), Rect2(0, 136, 80, 24), Rect2(80, 136, 80, 24)]
const MOVE_TEXT_DX := 15.0
const MOVE_INFO := Rect2(160, 112, 80, 48)       # PP / TYPE window of the moves layout
const PARTY_AREA := Rect2(0, 0, 240, 112)        # stand-in party list (over the field, like the ROM's party screen)
const FONT_TEXT := 11.0                          # GBA px; message / menu text
const FONT_BOX := 9.0                            # healthbox text
const FONT_SMALL := 8.0
const LINE_PITCH := 16.0                         # the ROM's text rows are 16 px apart
const TEXT_MSG := Color8(20, 20, 24)           # message text (dark on the ROM's teal message box)
const SHADOW_LIGHT := Color8(104, 88, 112)
const TEXT_DARK := Color8(72, 72, 80)            # menu text (dark on the white menu windows)
const SHADOW_DARK := Color8(208, 208, 200)
const TEXT_DISABLED := Color8(160, 160, 168)

const MSG_TIME := 0.75          # seconds each message page stays before the next event (tap skips)
const TYPE_TINT := [Color(0.75, 0.75, 0.7), Color(0.8, 0.4, 0.3), Color(0.6, 0.7, 0.95), Color(0.65, 0.4, 0.75),
	Color(0.8, 0.7, 0.45), Color(0.7, 0.62, 0.4), Color(0.6, 0.75, 0.3), Color(0.45, 0.4, 0.65), Color(0.7, 0.72, 0.8),
	Color(0.5, 0.5, 0.5), Color(0.95, 0.5, 0.25), Color(0.35, 0.55, 0.95), Color(0.4, 0.8, 0.4), Color(0.95, 0.85, 0.3),
	Color(0.95, 0.45, 0.65), Color(0.6, 0.85, 0.9), Color(0.45, 0.4, 0.85), Color(0.4, 0.35, 0.35), Color(0.95, 0.65, 0.8),
	Color(0.8, 0.8, 0.8)]

var ctl: BattleController
var bd: BattleData
var _queue: Array = []
var _playing := false
var _skip := false
var _ended := false
var _closed := false
var _menu_mode := "main"       # main | moves | bag | party | party_forced | target | none
var _slots := {}               # "side:slot" -> {holder, blob, tex, hb (healthbox dict), ...}
var _menu: Control             # holds the current menu's tap buttons (freed by _clear_menu)
var _msg: Label                # the text box text (one message, 2 lines at a time)
var _hint: Label               # extra prompt on the message window's second row
var _more: Control             # ROM-style "▼ more" marker shown while waiting for the closing tap
var _cursor: Control           # menu cursor (selected move / last action)
var _win: TextureRect          # ROM text box window (decoded) for the current layout
var _win_alt: Control          # neutral stand-in window when the ROM window is not in the cache
var _win_mode := "msg"
var _move_info: Array = []     # [pp label, type label] in the moves layout
var _move_sel := 0             # selected move (cursor), kept for the whole battle like the ROM
var _action_sel := 0           # last action cell
var _party_bg: Panel           # stand-in party list background
var _pics_debug: Label         # one-line "pics: <reason>" shown only when a placeholder is used (0.1.6)
var _waiting_close := false
var _bg: ColorRect             # full screen, black: the pillarbox
var _stage: Control            # the 240x160 GBA stage (clips its children)
var _arena: Control
var _bg_rect: TextureRect
var _rom_bg: Texture2D
var _s := 3.0                  # logical px per GBA px (integer in physical px)
var _origin := Vector2.ZERO    # logical position of the GBA stage's top-left
var _lay := {}                 # node instance id -> {node, rect (GBA, parent-relative), font, kind...}
var _feet_cache := {}          # texture rid -> lowest opaque row + 1
var _tex_memo := {}            # per-battle picture memo ("mon:…", "trainer:…", "pback:…"; story_test counts it)
var _ui_memo := {}             # ROM text box windows by layout name
var _intro_done := false
var _player_intro := false
var _foe_trainer_shown := false
var _foe_entered := false
## Tests only (battle_layout_test --doubles on a build without the doubles engine): treat both sides as doubles.
var debug_doubles := false
## 0.1.11 D-pad navigation: the current menu's entries [{rect (GBA tap rect), dx, btn, move (index or -1)}]
## and the one under the ▶ cursor. D-pad moves to the nearest entry in that direction, A presses it.
var _nav: Array = []
var last_submit := {}   # tests: the last action this screen submitted for our slot
var _nav_i := 0

## Connects the screen to a controller (call before add_child).
func setup(c: BattleController) -> void:
	ctl = c
	bd = c.bd
	c.events_ready.connect(_on_events)

func _ready() -> void:
	layer = 27
	_bg = ColorRect.new()
	_bg.color = Color.BLACK
	_bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	_bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_bg.theme = UiTheme.shared()
	add_child(_bg)
	_stage = Control.new()
	_stage.name = "GbaStage"
	_stage.clip_contents = true
	_stage.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_bg.add_child(_stage)
	# Original placeholder platforms, only when there is no ROM background and no picture.
	_arena = _Arena.new()
	_arena.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_stage.add_child(_arena)
	_place(_arena, Rect2(Vector2.ZERO, GBA))
	# Pictures: foe first so the player's side draws on top where they meet, like the original.
	for key in ["1:1", "1:0", "0:1", "0:0"]:
		_stage.add_child(_pic_box(key))
	for key in ["1:0", "1:1", "0:0", "0:1"]:
		_stage.add_child(_healthbox(key))
	_party_bg = Panel.new()
	_party_bg.visible = false
	_party_bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_stage.add_child(_party_bg)
	_place(_party_bg, PARTY_AREA, 0.0, "party_bg")
	# Text box window: the ROM's own window graphics, or the neutral stand-in.
	_win = TextureRect.new()
	_win.texture_filter = GfxFilter.filter()
	_win.stretch_mode = TextureRect.STRETCH_SCALE
	_win.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_win.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_win.name = "RomTextBox"
	_stage.add_child(_win)
	_place(_win, TEXTBOX)
	_win_alt = _WindowStandIn.new()
	_win_alt.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_stage.add_child(_win_alt)
	_place(_win_alt, TEXTBOX)
	_msg = _label(_stage, MSG_TEXT, FONT_TEXT, TEXT_MSG, SHADOW_LIGHT)
	_msg.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_msg.max_lines_visible = 2
	_msg.vertical_alignment = VERTICAL_ALIGNMENT_TOP
	_hint = _label(_stage, Rect2(100, 135, 128, 18), FONT_TEXT, TEXT_MSG, SHADOW_LIGHT)
	_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	for i in 2:   # moves layout: "PP 35/35" and "TYPE/NORMAL"
		var l := _label(_stage, Rect2(MOVE_INFO.position + Vector2(8, 7 + 16 * i), Vector2(66, 16)), FONT_BOX + 1, TEXT_DARK, SHADOW_DARK)
		l.visible = false
		_move_info.append(l)
	_menu = Control.new()
	_menu.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_stage.add_child(_menu)
	_place(_menu, Rect2(Vector2.ZERO, GBA))
	_cursor = _Marker.new()
	_cursor.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_cursor.visible = false
	_stage.add_child(_cursor)
	_more = _Marker.new()
	_more.down = true
	_more.color = Color8(213, 74, 57)
	_more.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_more.visible = false
	_stage.add_child(_more)
	_place(_more, Rect2(222, 144, 7, 6))
	# Debug line (0.1.6): in the left pillarbox (outside the GBA stage), hidden unless a placeholder is used.
	_pics_debug = UiTheme.label("", UiTheme.SMALL, true)
	_pics_debug.modulate = Color(1.0, 0.85, 0.4)
	_pics_debug.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_pics_debug.visible = false
	_bg.add_child(_pics_debug)
	_set_window("msg")
	get_viewport().size_changed.connect(_relayout)
	_relayout()
	# Intro pictures are shown on the first event batch, not here: the controller adds this screen to the
	# tree (→ _ready) BEFORE it calls _begin(), so ctl.what is still empty at this point.

# ------------------------------------------------------------- layout (GBA stage, integer scale)
# The stage is 240x160 GBA px scaled by an INTEGER number of physical pixels per GBA pixel and centred; the
# rest of the screen stays black (pillarbox). Every node inside is registered with _place(node, GBA rect
# relative to its parent) and re-placed by _relayout, so all UI lives in GBA coordinates.

## Registers `node` at `r` (GBA px, relative to its parent's GBA origin). font > 0 also scales its font size.
func _place(node: Control, r: Rect2, font: float = 0.0, kind: String = "") -> void:
	_lay[node.get_instance_id()] = {"node": node, "rect": r, "font": font, "kind": kind}
	_apply(_lay[node.get_instance_id()])

func _apply(e: Dictionary) -> void:
	var n: Control = e.node
	var r: Rect2 = e.rect
	n.position = (r.position * _s).round()
	n.size = (r.size * _s).round()
	if n == _stage:
		return
	if e.font > 0.0:
		var fs := maxi(6, roundi(e.font * _s))
		# Single-line texts shrink to fit their ROM cell (the ROM font is narrower than ours; long move and
		# species names would be cut off otherwise).
		var one_line: bool = (n is Button and not "\n" in n.text) or (n is Label and n.autowrap_mode == TextServer.AUTOWRAP_OFF and not "\n" in n.text)
		if one_line and n.text != "":
			var fnt: Font = n.get_theme_font("font")
			var avail: float = (r.size.x - float(e.get("dx", 0.0)) - 5.0) * _s
			while fnt != null and fs > 6 and fnt.get_string_size(n.text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x > avail:
				fs -= 1
		n.add_theme_font_size_override("font_size", fs)
		var sh := maxi(1, roundi(_s))
		n.add_theme_constant_override("shadow_offset_x", sh)
		n.add_theme_constant_override("shadow_offset_y", sh)
		if n is Label:
			var f: Font = n.get_theme_font("font")
			n.add_theme_constant_override("line_spacing", roundi(LINE_PITCH * _s - f.get_height(fs)) if f != null else 0)
	match str(e.kind):
		"hb":
			n.add_theme_stylebox_override("panel", _box_style(Color8(248, 248, 224), Color8(74, 65, 82), 2.0))
		"party_bg":
			n.add_theme_stylebox_override("panel", _box_style(Color8(56, 96, 112), Color8(74, 65, 82), 0.0))
		"cell":
			var sb := StyleBoxEmpty.new()
			sb.content_margin_left = roundf(float(e.get("dx", 0.0)) * _s)
			# Text rows of the ROM menus are 16 px apart (centres y 128 / 144) while the tap cells are 24 px
			# tall: shift the text towards the window's middle by 4 px.
			if r.size.y == 24.0 and r.position.y >= TEXTBOX_TOP:
				if r.position.y < 136.0:
					sb.content_margin_top = roundf(8 * _s)
				else:
					sb.content_margin_bottom = roundf(8 * _s)
			for st in ["normal", "hover", "pressed", "disabled", "focus", "hover_pressed"]:
				n.add_theme_stylebox_override(st, sb)
		"entry":
			var pressed := _box_style(Color8(106, 164, 164), Color8(74, 65, 82), 2.0)
			var normal := _box_style(Color8(255, 255, 255), Color8(74, 65, 82), 2.0)
			var dis := _box_style(Color8(168, 176, 176), Color8(74, 65, 82), 2.0)
			for st in ["normal", "hover", "focus"]:
				n.add_theme_stylebox_override(st, normal)
			n.add_theme_stylebox_override("pressed", pressed)
			n.add_theme_stylebox_override("hover_pressed", pressed)
			n.add_theme_stylebox_override("disabled", dis)

## Sets a placed label's text and re-applies its placement (font fitting).
func _set_text(l: Control, t: String) -> void:
	l.text = t
	if _lay.has(l.get_instance_id()):
		_apply(_lay[l.get_instance_id()])

func _box_style(fill: Color, border: Color, radius: float) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = fill
	sb.border_color = border
	sb.set_border_width_all(maxi(1, roundi(_s)))
	sb.set_corner_radius_all(roundi(radius * _s))
	sb.content_margin_left = roundf(4 * _s)
	sb.content_margin_right = roundf(4 * _s)
	return sb

## Label at a GBA rect inside `parent` with the ROM-like text colour and 1 px shadow.
func _label(parent: Control, r: Rect2, font: float, col: Color, shadow: Color) -> Label:
	var l := Label.new()
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	l.clip_text = true
	l.add_theme_color_override("font_color", col)
	l.add_theme_color_override("font_shadow_color", shadow)
	parent.add_child(l)
	_place(l, r, font)
	return l

## Places everything for the current viewport size. Safe to call repeatedly (resize, new picture).
func _relayout() -> void:
	if _bg == null:
		return
	# 0.1.11: GbaScreen decides (portrait: top of the screen, whole physical px per GBA px, controller below;
	# landscape: centred with a pillarbox).
	var L := GbaScreen.layout(get_viewport())
	_s = L.scale
	_origin = (L.rect as Rect2).position
	_stage.position = _origin
	_stage.size = GBA * _s
	for id in _lay.keys():
		var e: Dictionary = _lay[id]
		if not is_instance_valid(e.node):
			_lay.erase(id)
			continue
		_apply(e)
	_arena.visible = _rom_bg == null and not _any_pic()
	_arena.queue_redraw()
	_build_bg_rect()
	for key in _slots:
		if _slots[key].has("tex"):
			_place_pic(key)
	_place_healthboxes()
	# Debug line: portrait → the controller's info strip (GamePad.debug_line); else the left pillarbox when
	# there is room, else on the stage's top edge.
	if L.portrait:
		_pics_debug.position = (L.strip as Rect2).position + Vector2(10, 28)
		_pics_debug.size = Vector2((L.strip as Rect2).size.x - 20, 0)
	elif _origin.x >= 120:
		_pics_debug.position = Vector2(8, 8)
		_pics_debug.size = Vector2(_origin.x - 16, 0)
	else:
		_pics_debug.position = _origin + Vector2(4, 2)
		_pics_debug.size = Vector2(GBA.x * _s - 8, 0)

## Logical-pixel point (screen) for a GBA stage point.
func stage_point(p: Vector2) -> Vector2:
	return _origin + p * _s

## Logical rect (screen) for a GBA stage rect.
func stage_rect(r: Rect2) -> Rect2:
	return Rect2(stage_point(r.position), r.size * _s)

## Screen rect of a control inside the stage.
func _screen_rect(c: Control) -> Rect2:
	return Rect2(c.get_global_rect().position, c.get_global_rect().size)

## ROM battle background (240x160, from SpriteSource.battle_background via ui/game.gd). The node keeps the
## name RomBattleBackground (tests look for it).
func set_background(tex: Texture2D) -> void:
	_rom_bg = tex
	_relayout()

func _build_bg_rect() -> void:
	if _rom_bg == null:
		return
	if _bg_rect == null:
		_bg_rect = TextureRect.new()
		_bg_rect.name = "RomBattleBackground"
		_bg_rect.texture_filter = GfxFilter.filter()
		_bg_rect.stretch_mode = TextureRect.STRETCH_SCALE
		_bg_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		_bg_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_stage.add_child(_bg_rect)
		_stage.move_child(_bg_rect, 0)
		_place(_bg_rect, Rect2(Vector2.ZERO, GBA))
	_bg_rect.texture = _rom_bg

## GBA-stage anchor ("feet" point) for a slot. Doubles anchors from the source's measurements (0.1.8).
func _anchor(key: String) -> Vector2:
	var side := int(key.get_slice(":", 0))
	var slot := int(key.get_slice(":", 1))
	var base := FOE_BASE if side == 1 else PLAYER_BASE
	if _double_active(side):
		if slot == 1:
			base += Vector2(SLOT_DX + 4, -4) if side == 1 else Vector2(SLOT_DX, 0)
		else:
			base += Vector2(-SLOT_DX + 2, 0) if side == 1 else Vector2(-SLOT_DX + 4, 0)
	return base

## Doubles on this side? From the battle format (active slot count) when known, else from what is shown.
func _double_active(side: int) -> bool:
	if debug_doubles:
		return true
	if ctl != null and ctl.state is Dictionary and ctl.state.has("sides") and (ctl.state.sides as Array).size() > side:
		return (ctl.state.sides[side].get("active", []) as Array).size() > 1
	var k := "%d:1" % side
	return _slots.has(k) and _slots[k].has("holder") and _slots[k].holder.visible

## Lowest non-transparent row + 1 of a picture (64 if solid to the bottom), cached per texture.
func _feet(t: Texture2D) -> int:
	if t == null:
		return 64
	var id := t.get_rid().get_id()
	if _feet_cache.has(id):
		return _feet_cache[id]
	var img := t.get_image()
	var bottom := img.get_height()
	if img != null and not img.is_empty():
		if img.is_compressed():
			img.decompress()
		bottom = 0
		for y in range(img.get_height() - 1, -1, -1):
			var found := false
			for x in img.get_width():
				if img.get_pixel(x, y).a > 0.0:
					found = true
					break
			if found:
				bottom = y + 1
				break
		if bottom == 0:
			bottom = img.get_height()
	_feet_cache[id] = bottom
	return bottom

## Positions a slot's picture (or placeholder blob) so its feet sit on the anchor, integer-scaled.
func _place_pic(key: String) -> void:
	var s := _slot(key)
	if not s.has("holder"):
		return
	var t: Texture2D = s.tex.texture if s.tex.visible else null
	var a := _anchor(key)
	var feet := float(_feet(t)) if t != null else 60.0
	var w := float(t.get_width()) if t != null else 64.0
	var h := float(t.get_height()) if t != null else 64.0
	var top_left := Vector2(roundf(a.x - w / 2.0), a.y - feet)
	s.holder.position = top_left * _s
	s.holder.size = Vector2(w, h) * _s
	s["rest"] = s.holder.position   # resting position (animations tween away from / back to it)

## Picture rect actually covered by non-transparent pixels (screen logical px). Empty if hidden.
func pic_rect(key: String) -> Rect2:
	var s := _slot(key)
	if not s.has("holder") or not s.holder.visible:
		return Rect2()
	var pos: Vector2 = _origin + s.holder.position
	if not s.tex.visible or s.tex.texture == null:
		return Rect2(pos, s.holder.size)
	var u: Rect2i = s.tex.texture.get_image().get_used_rect()
	return Rect2(pos + Vector2(u.position) * _s, Vector2(u.size) * _s)

func _any_pic() -> bool:
	for key in _slots:
		var s: Dictionary = _slots[key]
		if s.has("tex") and s.tex.visible and s.holder.visible:
			return true
	return false

## Named rects (screen logical px) for tests/battle_layout_test.gd. "ui" lists every visible UI element
## (healthboxes, text box, menu cells, party list); "field_ui" the ones that are not healthboxes and lie
## above the text box (should be empty except the party list stand-in).
func layout_rects() -> Dictionary:
	var r := {"textbox": stage_rect(TEXTBOX), "stage": stage_rect(Rect2(Vector2.ZERO, GBA)),
		"foe_platform": stage_rect(FOE_PLATFORM), "player_platform": stage_rect(PLAYER_PLATFORM),
		"viewport": get_viewport().get_visible_rect(), "foe_pic": pic_rect("1:0"), "player_pic": pic_rect("0:0"),
		"foe_anchor": stage_point(_anchor("1:0")), "player_anchor": stage_point(_anchor("0:0")), "scale": _s,
		"window": _screen_rect(_win if _win.visible else _win_alt), "rom_window": _win.visible}
	r["pics"] = {}
	r["infos"] = {}
	r["anchors"] = {}
	var ui: Array = [r.window]
	var field_ui: Array = []
	for key in ["1:0", "1:1", "0:0", "0:1"]:
		var s := _slot(key)
		if s.has("holder") and s.holder.visible:
			r.pics[key] = pic_rect(key)
			r.anchors[key] = stage_point(_anchor(key))
		if s.has("hb") and s.hb.box.visible:
			var hr := _screen_rect(s.hb.box)
			r.infos[key] = hr
			ui.append(hr)
	if r.infos.has("1:0"):
		r["foe_info"] = r.infos["1:0"]
	if r.infos.has("0:0"):
		r["player_info"] = r.infos["0:0"]
	for c in _menu.get_children():
		if c is Control and c.visible and not c.is_queued_for_deletion():
			var cr := _screen_rect(c)
			ui.append(cr)
			if cr.position.y < r.textbox.position.y - 0.5:
				field_ui.append(cr)
	for l in [_msg, _hint] + _move_info:
		if l.visible and l.text != "":
			ui.append(_screen_rect(l))
	if _party_bg.visible:
		ui.append(_screen_rect(_party_bg))
		field_ui.append(_screen_rect(_party_bg))
	r["ui"] = ui
	r["field_ui"] = field_ui
	r["menu_mode"] = _menu_mode
	r["window_mode"] = _win_mode
	return r

# ------------------------------------------------------------- text box window

## Switches the bottom window to a ROM layout: "msg", "action" or "moves" (ROM texture or stand-in).
func _set_window(mode: String) -> void:
	_win_mode = mode
	if not _ui_memo.has(mode):
		var u = ui_provider.call("textbox_" + mode) if ui_provider.is_valid() else null
		_ui_memo[mode] = u if u is Texture2D else null
	var t: Texture2D = _ui_memo[mode]
	_win.texture = t
	_win.visible = t != null
	_win_alt.visible = t == null
	_win_alt.mode = mode
	_win_alt.queue_redraw()
	_msg.visible = mode != "moves"
	_place(_msg, MSG_TEXT if mode == "msg" else PROMPT_TEXT, FONT_TEXT)
	_msg.lines_skipped = 0
	for l in _move_info:
		l.visible = mode == "moves"
	if mode != "msg":
		_hint.text = ""
		_more.visible = false

# ------------------------------------------------------------- healthboxes (neutral stand-ins, KI-53)

## Healthbox for a slot: a plain panel at the ROM position with name, gender, Lv, status, HP bar; the
## singles player box adds HP numbers and an EXP bar. Children are placed in box-relative GBA px.
func _healthbox(key: String) -> Panel:
	var p := Panel.new()
	p.mouse_filter = Control.MOUSE_FILTER_IGNORE
	p.visible = false
	var hb := {"box": p, "key": key, "frac": 1.0, "exp": 0.0}
	hb["name"] = _label(p, Rect2(), FONT_BOX, TEXT_DARK, SHADOW_DARK)
	hb["gender"] = _label(p, Rect2(), FONT_BOX, TEXT_DARK, SHADOW_DARK)
	hb["lv"] = _label(p, Rect2(), FONT_BOX, TEXT_DARK, SHADOW_DARK)
	hb.lv.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	hb["status"] = _label(p, Rect2(), FONT_SMALL, Color8(200, 64, 56), SHADOW_DARK)
	hb["hp_tag"] = _label(p, Rect2(), FONT_SMALL, Color8(232, 176, 40), SHADOW_DARK)
	hb.hp_tag.text = "HP"
	hb["hp_bg"] = _rect(p, Color8(72, 80, 80))
	hb["hp_fill"] = _rect(p, Color8(88, 208, 128))
	hb["hp_num"] = _label(p, Rect2(), FONT_BOX, TEXT_DARK, SHADOW_DARK)
	hb.hp_num.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	hb["exp_bg"] = _rect(p, Color8(72, 80, 80))
	hb["exp_fill"] = _rect(p, Color8(64, 200, 248))
	_slot(key)["hb"] = hb
	_place(p, Rect2(), 0.0, "hb")
	return p

func _rect(parent: Control, c: Color) -> ColorRect:
	var r := ColorRect.new()
	r.color = c
	r.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(r)
	_place(r, Rect2())
	return r

## Places the healthboxes for the current format (singles / doubles per side) and their contents.
func _place_healthboxes() -> void:
	for key in ["1:0", "1:1", "0:0", "0:1"]:
		var s := _slot(key)
		if not s.has("hb"):
			continue
		var hb: Dictionary = s.hb
		var side := int(key[0])
		var dbl := _double_active(side)
		var r: Rect2 = HB_DOUBLE[key] if dbl else HB_SINGLE.get(key, HB_DOUBLE[key])
		_place(hb.box, r, 0.0, "hb")
		var full := side == 0 and not dbl           # the singles player box (HP numbers + EXP bar)
		var w := r.size.x
		_place(hb.name, Rect2(6, 1, w - 50, 12), FONT_BOX)
		_place(hb.gender, Rect2(w - 45, 1, 11, 12), FONT_BOX)
		_place(hb.lv, Rect2(w - 34, 1, 30, 12), FONT_BOX)
		var bar := Rect2(w - 54, 15 if not dbl else 14, 48, 3)
		_place(hb.status, Rect2(4, bar.position.y - 4, 24, 10), FONT_SMALL)
		_place(hb.hp_tag, Rect2(bar.position.x - 13, bar.position.y - 4, 13, 10), FONT_SMALL)
		_place(hb.hp_bg, bar)
		_place(hb.hp_fill, Rect2(bar.position, Vector2(_bar_px(hb.frac, 48), 3)))
		hb.hp_num.visible = full
		hb.exp_bg.visible = full
		hb.exp_fill.visible = full
		_place(hb.hp_num, Rect2(w - 62, 17, 56, 11), FONT_BOX)
		_place(hb.exp_bg, Rect2(w - 70, r.size.y - 4, 64, 2))
		_place(hb.exp_fill, Rect2(w - 70, r.size.y - 4, _bar_px(hb.exp, 64), 2))

## Filled pixels of a bar of `px` width for fraction f (at least 1 while anything is left, like the ROM).
static func _bar_px(f: float, px: int) -> float:
	if f <= 0.0:
		return 0.0
	return clampf(floorf(f * px), 1.0, float(px))

func _set_hp(hb: Dictionary, hp: float, mx: float) -> void:
	var f := hp / maxf(1.0, mx)
	hb.frac = f
	hb.hp_fill.color = Color8(88, 208, 128) if f > 0.5 else Color8(248, 216, 48) if f > 0.2 else Color8(240, 88, 56)
	var e: Dictionary = _lay[hb.hp_fill.get_instance_id()]
	e.rect = Rect2(e.rect.position, Vector2(_bar_px(f, 48), 3))
	_apply(e)
	hb.hp_num.text = "%d/%3d" % [int(round(hp)), int(mx)]   # fixed cell; digits always fit

func _fill_healthbox(key: String, mon: Dictionary) -> void:
	var s := _slot(key)
	if not s.has("hb"):
		return
	var hb: Dictionary = s.hb
	hb.box.visible = true
	var nm := str(mon.get("name", "?"))
	hb.name.text = nm
	var g := int(mon.get("gender", -1))
	hb.gender.text = "♂" if g == 0 else "♀" if g == 1 else ""
	hb.gender.add_theme_color_override("font_color", Color8(64, 152, 248) if g == 0 else Color8(248, 88, 88))
	hb.lv.text = "Lv%d" % int(mon.get("level", 1))
	hb.status.text = str(mon.get("status", "")).to_upper()
	_set_hp(hb, float(mon.get("hp", 0)), float(mon.get("max_hp", 1)))
	hb.exp = 0.0
	if bd != null and mon.has("exp") and mon.has("growth"):
		var lv := int(mon.level)
		var lo := bd.exp_at(int(mon.growth), lv)
		var hi := bd.exp_at(int(mon.growth), mini(lv + 1, 100))
		hb.exp = clampf(float(int(mon.exp) - lo) / maxf(1.0, float(hi - lo)), 0.0, 1.0) if lv < 100 else 0.0
	_place_healthboxes()

func _pic_box(key: String) -> Control:
	var c := Control.new()
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	c.visible = false
	var blob := _Blob.new()
	blob.set_anchors_preset(Control.PRESET_FULL_RECT)
	blob.mouse_filter = Control.MOUSE_FILTER_IGNORE
	blob.visible = false
	c.add_child(blob)
	var tex := TextureRect.new()
	tex.set_anchors_preset(Control.PRESET_FULL_RECT)
	tex.stretch_mode = TextureRect.STRETCH_SCALE
	tex.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	tex.texture_filter = GfxFilter.filter()
	tex.mouse_filter = Control.MOUSE_FILTER_IGNORE
	tex.visible = false
	c.add_child(tex)
	_slot(key).merge({"holder": c, "blob": blob, "tex": tex})
	return c

func _slot(key: String) -> Dictionary:
	if not _slots.has(key):
		_slots[key] = {}
	return _slots[key]

# ------------------------------------------------------------- slot helper

func _my_slot() -> int:
	return ctl.my_slot() if ctl != null and ctl.has_method("my_slot") else 0

# ------------------------------------------------------------- event playback

func _on_events(ev: Array, _state: Dictionary) -> void:
	if not _intro_done:
		_intro_done = true
		_show_intro_pics()
	_queue.append_array(ev)
	if not _playing:
		_play()

func _play() -> void:
	_playing = true
	_clear_menu()
	while not _queue.is_empty():
		var e: Dictionary = _queue.pop_front()
		match str(e.get("e", "")):
			"msg":
				await _show_message(str(e.text))
			# 0.1.59 BATTLE ANIMATIONS: the engine already emits "move" (attacker, move id) but the
			# screen ignored it, so attacks were text + HP drain only. Now the attacker lunges (or
			# glows for a status move) on "move", and the defender flashes white + shakes when its
			# HP actually drops on "hp" (bigger drop = bigger shake). Healing never flinches.
			"move":
				await _attack_anim(int(e.side), int(e.slot), int(e.get("move", -1)))
			"stage":
				var sk2 := _slot("%d:%d" % [int(e.side), int(e.slot)])
				if sk2.has("holder") and sk2.holder.visible:
					var tw3 := create_tween()
					tw3.tween_property(sk2.holder, "modulate", Color(1.8, 1.8, 1.8, 1.0), 0.12)
					tw3.tween_property(sk2.holder, "modulate", Color.WHITE, 0.12)
					await tw3.finished
			"send":
				var key := "%d:%d" % [int(e.side), int(e.slot)]
				var sk := _slot(key)
				if int(e.side) == 0 and _player_intro:
					await _play_throw()            # throw frames, then the player slides out
				elif int(e.side) == 1 and _foe_trainer_shown:
					_foe_trainer_shown = false
					await _slide_out("1:0", 1)     # the trainer leaves to the right
				elif sk.has("holder") and sk.holder.visible and not sk.get("fainted", false):
					await _pop_out(key)            # switching out a standing Pokémon
				sk["fainted"] = false
				# Wild foes slide in on their first appearance (per slot), later sends pop in.
				var wild_entry: bool = int(e.side) == 1 and str(ctl.what.get("kind", "")) == "wild" and not bool(sk.get("entered", false))
				_show_mon(int(e.side), int(e.slot), e.mon)
				if audio_node != null:
					var sp := int(e.mon.get("species", 0))
					if sp > 0:
						audio_node.play_cry(sp, 0)
				if wild_entry:
					_foe_entered = true
					sk["entered"] = true
					await _slide_in(key, -1)       # wild Pokémon slides in from the left
				else:
					await _pop_in(key)
				await _wait(0.1)
			"hp":
				var hk := "%d:%d" % [int(e.side), int(e.slot)]
				var hs := _slot(hk)
				var old_hp := -1
				if hs.has("hb"):
					old_hp = int(hs.hb.frac * int(e.max))
				if old_hp >= 0 and int(e.hp) < old_hp:
					await _hit_reaction(int(e.side), int(e.slot), float(old_hp - int(e.hp)) / maxf(1.0, float(e.max)))
				await _anim_hp(int(e.side), int(e.slot), int(e.hp), int(e.max))
			"status":
				var s := _slot("%d:%d" % [int(e.side), int(e.slot)])
				if s.has("hb"):
					s.hb.status.text = str(e.status).to_upper()
			"faint":
				var fk := "%d:%d" % [int(e.side), int(e.slot)]
				await _faint(fk)
				if _slot(fk).has("hb"):
					_slot(fk).hb.box.visible = false
			"take_item":
				# The taken item goes back to the bag.
				_return_item_to_bag(int(e.get("item", 0)))
			"give_item":
				# The old held item, if any, goes back to the bag.
				_return_item_to_bag(int(e.get("old", 0)))
			"level":
				if int(e.side) == 0:
					_refresh_from_state()
			"end":
				_ended = true
	_playing = false
	_after_playback()

## One message in the ROM text box: 2 lines at a time; longer messages page on (tap skips each page).
func _show_message(t: String) -> void:
	_say(t)
	await get_tree().process_frame     # line count needs the label laid out
	var lines := maxi(1, _msg.get_line_count())
	var page := 0
	while true:
		await _wait(MSG_TIME)
		page += 2
		if page >= lines:
			break
		_msg.lines_skipped = page

func _after_playback() -> void:
	if ctl.is_over() or _ended:
		_set_window("msg")
		_more.visible = true
		_waiting_close = true
		return
	if ctl.auto:
		return
	var need := ctl.needed()
	if need.is_empty():
		return
	_hint.text = ""
	if str(need[0].kind) == "switch":
		_show_party(true)
	else:
		_show_main()

## Shows a message in the text box (message layout). Replaces the previous one (no scrolling log).
func _say(t: String) -> void:
	if _win_mode != "msg":
		_set_window("msg")
	_msg.text = t
	_msg.lines_skipped = 0

func _wait(sec: float) -> void:
	_skip = false
	var t := 0.0
	while t < sec and not _skip:
		await get_tree().process_frame
		t += get_process_delta_time()

## HP bar drain (0.1.7): the bar and the number count down together; duration grows with the change
## (0.25-1.0 s), and the colour updates as it crosses the half/fifth thresholds.
func _anim_hp(side: int, slot: int, hp: int, mx: int) -> void:
	var s := _slot("%d:%d" % [side, slot])
	if not s.has("hb"):
		return
	var hb: Dictionary = s.hb
	var from: float = hb.frac * mx
	var dur := clampf(0.25 + 0.8 * absf(from - hp) / maxf(1, mx), 0.25, 1.0)
	var tw := create_tween()
	tw.tween_method(func(v: float): _set_hp(hb, v, mx), from, float(hp), dur)
	await tw.finished

func _show_mon(side: int, slot: int, mon: Dictionary) -> void:
	var key := "%d:%d" % [side, slot]
	var s := _slot(key)
	_fill_healthbox(key, mon)
	if not s.has("holder"):
		return
	var shiny := bool(mon.get("shiny", false))
	var texd: Texture2D = _memo("mon:%d:%s:%s" % [int(mon.species), side == 0, shiny], sprite_provider,
		[int(mon.species), side == 0, shiny] if _provider_takes_shiny() else [int(mon.species), side == 0])
	if texd == null:
		_note_missing_pic(int(mon.species), side == 0)
	s.holder.visible = true
	s.holder.modulate = Color.WHITE
	s.holder.scale = Vector2.ONE
	s.tex.visible = texd != null
	s.tex.texture = texd
	s.tex.modulate = Color.WHITE
	s.blob.visible = texd == null
	s.blob.modulate = Color.WHITE
	var t: Array = mon.get("types", [0, 0])
	s.blob.c1 = TYPE_TINT[clampi(int(t[0]), 0, TYPE_TINT.size() - 1)]
	s.blob.c2 = TYPE_TINT[clampi(int(t[1]), 0, TYPE_TINT.size() - 1)]
	s.blob.seed_value = int(mon.species)
	s.blob.back = side == 0
	s.blob.queue_redraw()
	_place_pic(key)
	_arena.visible = _rom_bg == null and not _any_pic()

## sprite_provider may be the old 2-argument form (species, back) or the 0.1.7 form (species, back, shiny).
func _provider_takes_shiny() -> bool:
	return sprite_provider.is_valid() and sprite_provider.get_argument_count() >= 3

func _refresh_from_state() -> void:
	var st: Dictionary = ctl.state
	for side in st.get("sides", []):
		for slot in side.active.size():
			var i := int(side.active[slot])
			if i >= 0:
				_show_mon(int(side.id), slot, side.mons[i])

# ------------------------------------------------------------- ROM pictures (hooks; never drawn here)

## Calls `hook` with `args` once per key per battle and remembers the texture (or null). Unset hook → null.
func _memo(key: String, hook: Callable, args: Array) -> Texture2D:
	if _tex_memo.has(key):
		return _tex_memo[key]
	var t: Texture2D = null
	if hook.is_valid():
		var r = hook.callv(args)
		if r is Texture2D:
			t = r
	_tex_memo[key] = t
	return t

## Before any Pokémon is sent out: the foe trainer's picture (trainer battles) in the foe box and the player's
## back picture in the player box, like the original's intro. Both stay hidden if their hook returns null.
## The trainer pic id comes from ctl.what + BattleData (same data offline and online; no protocol change).
func _show_intro_pics() -> void:
	if ctl == null:
		return
	var w: Dictionary = ctl.what
	if str(w.get("kind", "")) == "trainer" and bd != null:
		var rec := bd.trainer(int(w.get("trainer", 0)), int(w.get("table", 0)))
		if rec.has("pic"):
			var tp := _memo("trainer:%d" % int(rec.pic), trainer_provider, [int(rec.pic)])
			if tp != null:
				_show_pic("1:0", tp)
				_foe_trainer_shown = true
				_slide_in("1:0", -1)
	var pb := _memo("pback:0", player_back_provider, [0])
	if pb != null:
		_show_pic("0:0", pb)
		_player_intro = true
		_slide_in("0:0", 1)

## Shows a still picture in a slot's picture box (blob hidden). Null → leaves the slot as it is.
func _show_pic(key: String, t: Texture2D) -> void:
	var s := _slot(key)
	if t == null or not s.has("tex"):
		return
	s.tex.texture = t
	s.tex.visible = true
	s.tex.modulate = Color.WHITE
	s.blob.visible = false
	s.holder.visible = true
	s.holder.modulate = Color.WHITE
	_place_pic(key)
	_arena.visible = _rom_bg == null and not _any_pic()

## Plays the player's throw frames (1..n-1) quickly, then hands the box back to the Pokémon picture.
## Skipped frames (null) are simply not shown. TODO: slide-out and ball animation (not in the original data).
func _play_throw() -> void:
	_player_intro = false
	for f in range(1, player_back_frame_count):
		var t := _memo("pback:%d" % f, player_back_provider, [f])
		if t != null:
			_show_pic("0:0", t)
			await _wait(THROW_FRAME_TIME)
	await _slide_out("0:0", -1)

# ------------------------------------------------------------- animations (0.1.7; tweens only, nothing drawn)
# All animations move/scale/fade the slot's holder (which shows the decoded ROM picture or the placeholder
# blob). No ball art yet: the ROM's Poké Ball graphics are not located/decoded (TODO, KI-42), so "ball open"
# is a pop-in (grow from the feet + bright flash). Durations are short so auto-played tests stay fast.

const SLIDE_TIME := 0.5
const SLIDE_OUT_TIME := 0.3
const POP_TIME := 0.25
const FAINT_TIME := 0.4

## Slides a slot's holder in from off-screen: dir -1 = from the left edge, +1 = from the right edge.
func _slide_in(key: String, dir: int) -> void:
	var s := _slot(key)
	if not s.has("holder"):
		return
	var rest: Vector2 = s.get("rest", s.holder.position)
	var start := Vector2(-s.holder.size.x, rest.y) if dir < 0 else Vector2(GBA.x * _s, rest.y)   # stage edges
	s.holder.position = start
	var tw := create_tween()
	tw.tween_property(s.holder, "position", rest, SLIDE_TIME).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	s["tween"] = tw
	await tw.finished

## Slides a slot's holder off-screen (dir -1 left, +1 right) and hides it (trainer leaving the field).
func _slide_out(key: String, dir: int) -> void:
	var s := _slot(key)
	if not s.has("holder") or not s.holder.visible:
		return
	if s.has("tween") and s.tween.is_valid():
		s.tween.kill()
	var rest: Vector2 = s.get("rest", s.holder.position)
	var end := Vector2(-s.holder.size.x, rest.y) if dir < 0 else Vector2(GBA.x * _s, rest.y)
	var tw := create_tween()
	tw.tween_property(s.holder, "position", end, SLIDE_OUT_TIME).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	await tw.finished
	s.holder.visible = false
	s.holder.position = rest

## "Ball open": the new Pokémon grows from its feet with a bright flash.
func _pop_in(key: String) -> void:
	var s := _slot(key)
	if not s.has("holder"):
		return
	var t: Texture2D = s.tex.texture if s.tex.visible else null
	s.holder.pivot_offset = Vector2(s.holder.size.x / 2.0, float(_feet(t) if t != null else 60) * _s)
	s.holder.scale = Vector2(0.15, 0.15)
	s.holder.modulate = Color(2.5, 2.5, 2.5, 1.0)
	var tw := create_tween().set_parallel(true)
	tw.tween_property(s.holder, "scale", Vector2.ONE, POP_TIME).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tw.tween_property(s.holder, "modulate", Color.WHITE, POP_TIME * 1.6)
	await tw.finished

## "Return to ball": shrink into the feet point (switching out a Pokémon that is still standing).
func _pop_out(key: String) -> void:
	var s := _slot(key)
	if not s.has("holder") or not s.holder.visible:
		return
	var t: Texture2D = s.tex.texture if s.tex.visible else null
	s.holder.pivot_offset = Vector2(s.holder.size.x / 2.0, float(_feet(t) if t != null else 60) * _s)
	var tw := create_tween().set_parallel(true)
	tw.tween_property(s.holder, "scale", Vector2(0.1, 0.1), POP_TIME)
	tw.tween_property(s.holder, "modulate", Color(2.5, 2.5, 2.5, 0.0), POP_TIME)
	await tw.finished
	s.holder.visible = false
	s.holder.scale = Vector2.ONE

## Faint: the picture drops by half its height and fades out, then the slot is hidden.
func _faint(key: String) -> void:
	var s := _slot(key)
	if not s.has("holder") or not s.holder.visible:
		return
	var rest: Vector2 = s.get("rest", s.holder.position)
	var tw := create_tween().set_parallel(true)
	tw.tween_property(s.holder, "position", rest + Vector2(0, s.holder.size.y * 0.5), FAINT_TIME).set_ease(Tween.EASE_IN)
	tw.tween_property(s.holder, "modulate:a", 0.0, FAINT_TIME)
	await tw.finished
	s.holder.visible = false
	s.holder.position = rest
	s["fainted"] = true

## 0.1.59: attack animation for a "move" event. Damaging moves (cat 0/1) lunge toward the foe and
## back; status moves (cat 2) make the user glow instead of lunging. Unknown category (lookup
## failed) glows — a neutral effect that never misrepresents an attack.
func _attack_anim(side: int, slot: int, move_id: int) -> void:
	var key := "%d:%d" % [side, slot]
	var s := _slot(key)
	if not s.has("holder") or not s.holder.visible:
		return
	var cat := -1
	if ctl != null and ctl.get("bd") != null:
		var mv: Dictionary = ctl.bd.move(move_id)
		if not mv.is_empty():
			cat = int(mv.get("cat", -1))
	var rest: Vector2 = s.get("rest", s.holder.position)
	if cat == 2:
		var tw := create_tween()
		tw.tween_property(s.holder, "modulate", Color(2.0, 2.0, 2.0, 1.0), 0.15)
		tw.tween_property(s.holder, "modulate", Color.WHITE, 0.15)
		await tw.finished
		return
	if cat != 0 and cat != 1:
		var twg := create_tween()
		twg.tween_property(s.holder, "modulate", Color(1.6, 1.6, 1.6, 1.0), 0.12)
		twg.tween_property(s.holder, "modulate", Color.WHITE, 0.12)
		await twg.finished
		return
	var dir := Vector2(12, -10) * _s if side == 0 else Vector2(-12, 10) * _s
	var tw2 := create_tween()
	tw2.tween_property(s.holder, "position", rest + dir, 0.12).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tw2.tween_property(s.holder, "position", rest, 0.12).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	await tw2.finished

## 0.1.59: hit reaction for an HP drop — white flash + shake, bigger for bigger hits (drop >= 25%
## of max). Runs before the HP bar drains, like the GBA (flash on impact, then the bar falls).
func _hit_reaction(side: int, slot: int, drop_frac: float) -> void:
	var key := "%d:%d" % [side, slot]
	var s := _slot(key)
	if not s.has("holder") or not s.holder.visible:
		return
	var rest: Vector2 = s.get("rest", s.holder.position)
	var amp := (5.0 if drop_frac >= 0.25 else 3.0) * _s
	var tw := create_tween()
	tw.tween_property(s.holder, "modulate", Color(2.5, 2.5, 2.5, 1.0), 0.06)
	tw.tween_property(s.holder, "modulate", Color.WHITE, 0.18)
	var sh := create_tween()
	sh.tween_property(s.holder, "position", rest + Vector2(amp, 0), 0.05)
	sh.tween_property(s.holder, "position", rest - Vector2(amp, 0), 0.05)
	sh.tween_property(s.holder, "position", rest + Vector2(amp * 0.5, 0), 0.05)
	sh.tween_property(s.holder, "position", rest, 0.05)
	await sh.finished
	s.holder.position = rest
	s.holder.modulate = Color.WHITE

## Shows "pics: <reason>" once per battle (first missing picture) and prints it to logcat.
func _note_missing_pic(species: int, back: bool) -> void:
	if _pics_debug == null or _pics_debug.visible:
		return
	var why := "not wired (no picture hooks set)"
	if sprite_provider.is_valid():
		why = str(reason_provider.call(species, back)) if reason_provider.is_valid() else "no picture returned"
	if why == "":
		why = "no picture returned for species %d" % species
	_pics_debug.text = "pics: " + why
	_pics_debug.visible = true
	if GamePad.debug_line(_pics_debug.text):
		_pics_debug.modulate.a = 0.0   # shown by the controller's info strip instead (it draws over this layer)
	print("QZ battle pics fallback: ", why)

func _exit_tree() -> void:
	_tex_memo.clear()
	if release_hook.is_valid():
		release_hook.call()

# ------------------------------------------------------------- menus (ROM text box layouts)

func _clear_menu() -> void:
	_nav.clear()
	_nav_i = 0
	for c in _menu.get_children():
		_lay.erase(c.get_instance_id())
		c.queue_free()
	_cursor.visible = false
	_party_bg.visible = false
	_menu_mode = "none"

## One menu cell: an invisible button over `tap` (GBA rect, generous touch target) whose text starts `dx` px
## into the cell, in the ROM's dark menu text colour. Returns the button.
func _cell(text: String, tap: Rect2, dx: float, cb: Callable, enabled: bool = true, font: float = FONT_TEXT) -> Button:
	var b := Button.new()
	b.text = text
	b.flat = true
	b.clip_text = true
	b.focus_mode = Control.FOCUS_NONE
	b.alignment = HORIZONTAL_ALIGNMENT_LEFT
	b.disabled = not enabled
	for st in ["font_color", "font_hover_color", "font_pressed_color", "font_focus_color", "font_hover_pressed_color"]:
		b.add_theme_color_override(st, TEXT_DARK)
	b.add_theme_color_override("font_disabled_color", TEXT_DISABLED)
	b.add_theme_color_override("font_shadow_color", SHADOW_DARK)
	for st in ["normal", "hover", "pressed", "focus", "disabled", "hover_pressed"]:
		b.add_theme_stylebox_override(st, StyleBoxEmpty.new())   # no theme margins: the cell is the ROM rect at any scale
	b.pressed.connect(cb)
	_menu.add_child(b)
	if text != "":
		_nav.append({"rect": tap, "dx": dx, "btn": b, "move": MOVE_CELLS.find(tap) if _menu_mode == "moves" else -1})
	_lay[b.get_instance_id()] = {"node": b, "rect": tap, "font": font, "kind": "cell", "dx": dx}
	_apply(_lay[b.get_instance_id()])
	return b

## Party entry (stand-in list): a light rounded box with name / Lv / HP.
func _entry(text: String, r: Rect2, cb: Callable, enabled: bool) -> Button:
	var b := Button.new()
	b.text = text
	b.clip_text = true
	b.focus_mode = Control.FOCUS_NONE
	b.alignment = HORIZONTAL_ALIGNMENT_LEFT
	b.disabled = not enabled
	for st in ["font_color", "font_hover_color", "font_pressed_color", "font_focus_color", "font_hover_pressed_color"]:
		b.add_theme_color_override(st, TEXT_DARK)
	b.add_theme_color_override("font_disabled_color", Color8(96, 96, 104))
	b.pressed.connect(cb)
	_menu.add_child(b)
	_nav.append({"rect": r, "dx": 10.0, "btn": b, "move": -1})
	_lay[b.get_instance_id()] = {"node": b, "rect": r, "font": FONT_BOX, "kind": "entry"}
	_apply(_lay[b.get_instance_id()])
	return b

## Cursor (ROM-style ▶, drawn as a small triangle) just left of a cell's text.
func _point_at(tap: Rect2, dx: float) -> void:
	for k in _nav.size():
		if _nav[k].rect == tap:
			_nav_i = k
	_cursor.visible = true
	_cursor.color = TEXT_DARK
	var cy := tap.position.y + tap.size.y / 2.0
	if tap.size.y == 24.0 and tap.position.y >= TEXTBOX_TOP:
		cy += 4.0 if tap.position.y < 136.0 else -4.0   # same text rows as _apply "cell"
	_place(_cursor, Rect2(tap.position.x + dx - 9, cy - 4, 6, 8))

## Our active Pokémon (the slot we choose for).
func _me() -> Dictionary:
	var side: Dictionary = ctl.state.sides[0]
	var slot := _my_slot()
	var i := int(side.active[slot]) if slot < side.active.size() else -1
	return side.mons[i] if i >= 0 else {}

## "What will X do?" + FIGHT / BAG / POKéMON / RUN (the ROM's action layout).
func _show_main() -> void:
	_clear_menu()
	_menu_mode = "main"
	_set_window("action")
	_msg.text = "What will\n%s do?" % str(_me().get("name", "?"))
	var wild: bool = ctl.state.get("kind", "") == "wild"
	var items := [["FIGHT", _show_moves, true], ["BAG", _show_bag, true],
		["POKéMON", func(): _show_party(false), true], ["RUN", func(): _choose({"kind": "run"}), wild]]
	for i in 4:
		var cb: Callable = items[i][1]
		_cell(items[i][0], ACTION_CELLS[i], ACTION_TEXT_DX, func(): _action_sel = i; cb.call(), items[i][2], FONT_TEXT - 1.0)
	_point_at(ACTION_CELLS[_action_sel], ACTION_TEXT_DX)

## The move list (left) and PP / TYPE of the move under the cursor (right). Tap a move = use it (0.1.11);
## the PP/TYPE window = use the move under the cursor; D-pad = move the cursor, A = use.
func _show_moves() -> void:
	_clear_menu()
	_menu_mode = "moves"
	_set_window("moves")
	var mv: Array = _me().get("moves", [])
	var all_out := mv.all(func(m): return int(m.pp) <= 0)   # no PP left at all → Struggle (engine)
	if _move_sel >= mv.size():
		_move_sel = 0
	for i in 4:
		if i < mv.size():
			var m: Dictionary = mv[i]
			var md := bd.move(int(m.id))
			_cell(str(md.get("name", "?")).to_upper(), MOVE_CELLS[i], MOVE_TEXT_DX, func(): _use_move(i), int(m.pp) > 0 or all_out)
		else:
			_cell("-", MOVE_CELLS[i], MOVE_TEXT_DX, func(): pass, false)
	_cell("", MOVE_INFO, 0.0, func(): _tap_move(_move_sel), mv.size() > 0)
	_select_move(_move_sel)

func _select_move(i: int) -> void:
	_move_sel = i
	_point_at(MOVE_CELLS[i], MOVE_TEXT_DX)
	var mv: Array = _me().get("moves", [])
	if i >= mv.size():
		_move_info[0].text = ""
		_move_info[1].text = ""
		return
	var m: Dictionary = mv[i]
	var md := bd.move(int(m.id))
	_set_text(_move_info[0], "PP   %d/%d" % [int(m.pp), int(m.max_pp)])
	_set_text(_move_info[1], "TYPE/%s" % bd.type_name(int(md.get("type", 0))).to_upper())
	_move_info[0].add_theme_color_override("font_color", Color8(232, 64, 48) if int(m.pp) == 0 else TEXT_DARK)

## 0.1.11 (Stephen): one touch on a move uses it at once (the D-pad moves the cursor, A uses the move under
## it, like the ROM).
func _use_move(i: int) -> void:
	_select_move(i)
	var mv: Array = _me().get("moves", [])
	if i < mv.size():
		_pick_move(i, bd.move(int(mv[i].id)))

## Old two-step touch (select, then the selected move again = use); kept for the PP/TYPE window cell.
func _tap_move(i: int) -> void:
	if i != _move_sel:
		_select_move(i)
		return
	var mv: Array = _me().get("moves", [])
	if i < mv.size():
		_pick_move(i, bd.move(int(mv[i].id)))

## Living foe slots right now (from the latest snapshot).
func _living_foe_slots() -> Array:
	var out: Array = []
	var sides: Array = ctl.state.get("sides", [])
	if sides.size() < 2:
		return out
	var fs: Dictionary = sides[1]
	for slot in fs.active.size():
		var i := int(fs.active[slot])
		if i >= 0 and int(fs.mons[i].hp) > 0:
			out.append(slot)
	return out

## Fight → move i: single-target moves with two living foes ask which one (doubles); everything else goes
## straight to the engine, which picks the targets. Target bits come from BattleState when it has them.
func _pick_move(i: int, md: Dictionary) -> void:
	var foes := _living_foe_slots()
	var cm: Dictionary = (BattleState as Script).get_script_constant_map()
	var multi := int(cm.get("TGT_BOTH", 0)) | int(cm.get("TGT_FOES_AND_ALLY", 0)) | int(cm.get("TGT_USER", 0)) | int(cm.get("TGT_RANDOM", 0))
	var single := multi != 0 and (int(md.get("target", 0)) & multi) == 0
	if not single or foes.size() < 2:
		_choose({"kind": "move", "move": i, "target": {"side": 1, "slot": foes[0] if foes.size() > 0 else 0}})
		return
	_clear_menu()
	_menu_mode = "target"
	_set_window("action")
	_msg.text = "%s on\nwhich one?" % str(md.get("name", "it")).to_upper()
	var fs: Dictionary = ctl.state.sides[1]
	var n := 0
	for slot in foes:
		var m: Dictionary = fs.mons[int(fs.active[slot])]
		_cell(str(m.name), ACTION_CELLS[n], ACTION_TEXT_DX, func(): _choose({"kind": "move", "move": i, "target": {"side": 1, "slot": slot}}))
		n += 1
	_cell("CANCEL", ACTION_CELLS[3], ACTION_TEXT_DX, _show_moves)
	_point_at(ACTION_CELLS[0], ACTION_TEXT_DX)

## KI-47: pick which of two living wild foes to throw a ball at, then submit the ball action with a target.
func _show_ball_target_picker(item: int) -> void:
	_clear_menu()
	_menu_mode = "ball_target"
	_set_window("action")
	_msg.text = "Throw at\nwhich one?"
	var fs: Dictionary = ctl.state.sides[1]
	var n := 0
	for slot in _living_foe_slots():
		var m: Dictionary = fs.mons[int(fs.active[slot])]
		_cell(str(m.name), ACTION_CELLS[n], ACTION_TEXT_DX, func(): _choose_ball_target(item, slot))
		n += 1
	_cell("CANCEL", ACTION_CELLS[3], ACTION_TEXT_DX, _show_bag)
	_point_at(ACTION_CELLS[0], ACTION_TEXT_DX)

func _choose_ball_target(item: int, slot: int) -> void:
	var pv = bag_source.progress
	pv.remove_item(item, 1)
	pv.save()
	_menu_mode = "none"
	_choose.call_deferred({"kind": "ball", "item": item, "target": {"side": 1, "slot": slot}})

## Bag (stand-in, KI-55): one generic ball in wild battles. TODO: real bag (items from Progress).
func _show_bag() -> void:
	if not bag_source.is_empty() and bag_source.get("progress") != null:
		_open_bag()
		return
	_clear_menu()
	_menu_mode = "bag"
	_set_window("action")
	var wild: bool = ctl.state.get("kind", "") == "wild"
	_msg.text = "Use which\nitem?"
	_cell("BALL", ACTION_CELLS[0], ACTION_TEXT_DX, func(): _choose({"kind": "ball", "item": 0}), wild)
	_cell("CANCEL", ACTION_CELLS[3], ACTION_TEXT_DX, _show_main)
	_point_at(ACTION_CELLS[0], ACTION_TEXT_DX)

## 0.1.14: the same BAG as the overworld (ui/bag_screen.gd) over the battle screen. Balls → "ball" action
## (refused by the bag in trainer battles), medicine → "item" action on one of OUR mons.
## The item leaves the bag when the action is submitted (the turn is used up).
var bag: BagScreen = null
func _open_bag() -> void:
	_clear_menu()
	_menu_mode = "bag"
	_set_window("action")
	var pv = bag_source.progress
	bag = BagScreen.new()
	bag.context = "battle"
	bag.events = bag_source.events
	bag.bd = bd
	bag.items = pv.items
	bag.wild = ctl.state.get("kind", "") == "wild"
	var side: Dictionary = ctl.state.sides[0]
	for i in side.mons.size():
		var m: Dictionary = side.mons[i]
		bag.party.append(m)
		bag.party_index.append(i)
	bag.used.connect(func(item: int, to: int, mv: int):
		var a := {"kind": "ball", "item": item} if ItemUse.is_ball(bd, item) else {"kind": "item", "item": item, "to": to, "move": maxi(mv, 0)}
		if to < 0 and a.kind == "item":
			a.erase("to")
		# KI-47: with two wild foes up, a ball needs a target (the engine refuses "two_targets" otherwise).
		if a.kind == "ball" and _living_foe_slots().size() >= 2:
			_show_ball_target_picker(item)
			return
		pv.remove_item(item, 1)
		pv.save()
		_menu_mode = "none"
		_choose.call_deferred(a))
	bag.closed.connect(func():
		bag = null
		if _menu_mode == "bag":
			_show_main.call_deferred())
	add_child(bag)

## Party (stand-in list over the field, KI-55): up to 6 entries in 2 columns, CANCEL unless forced.
## Non-forced: tapping a mon opens what to do with it (switch / give / take); forced replacements stay
## single-tap switch.
func _show_party(forced: bool) -> void:
	_clear_menu()
	_menu_mode = "party_forced" if forced else "party"
	_set_window("action")
	_msg.text = "Choose a\nPOKéMON."
	_party_bg.visible = true
	var side: Dictionary = ctl.state.sides[0]
	var n := 0
	for i in side.mons.size():
		var m: Dictionary = side.mons[i]
		var ok: bool = int(m.hp) > 0 and not side.active.has(i)
		var r := Rect2(4 + 118 * (n % 2), 4 + 36 * (n / 2), 114, 32)
		_entry("%s  Lv%d\nHP %d/%d" % [m.name, int(m.level), int(m.hp), int(m.max_hp)], r,
			func(): _party_entry_tapped(i, forced), ok)
		n += 1
	if not forced:
		_cell("CANCEL", ACTION_CELLS[3], ACTION_TEXT_DX, _show_main)
	if not _nav.is_empty():
		_point_at(_nav[0].rect, _nav[0].dx)   # 0.1.11: D-pad cursor starts on the first Pokémon

func _party_entry_tapped(i: int, forced: bool) -> void:
	if forced:
		_choose({"kind": "switch", "to": i})
	else:
		_show_party_options(i)

## What to do with one party mon (non-forced party tap): switch it in, give it a held item from the
## bag, or take its held item off (the item goes back to the bag).
var _give_to := -1
func _show_party_options(i: int) -> void:
	var side: Dictionary = ctl.state.sides[0]
	if i < 0 or i >= side.mons.size():
		_show_party(false)
		return
	var m: Dictionary = side.mons[i]
	_clear_menu()
	_menu_mode = "party_options"
	_set_window("action")
	_msg.text = "Do what with\n%s?" % m.name
	_cell("SWITCH", ACTION_CELLS[0], ACTION_TEXT_DX, func(): _choose({"kind": "switch", "to": i}),
		int(m.hp) > 0 and not side.active.has(i))
	_cell("GIVE", ACTION_CELLS[1], ACTION_TEXT_DX, func(): _show_give_list(i), not _holdable_items().is_empty())
	_cell("TAKE", ACTION_CELLS[2], ACTION_TEXT_DX, func(): _choose({"kind": "take_item", "to": i}),
		int(m.get("item", 0)) > 0)
	_cell("CANCEL", ACTION_CELLS[3], ACTION_TEXT_DX, func(): _show_party(false))
	_point_at(ACTION_CELLS[0], ACTION_TEXT_DX)

## Holdable items in the bag, as [{id, n}]: pocket ITEMS (0) or BERRIES (3) by the ROM pocket byte
## (excludes TMs / key items), not a ball, and not bag medicine (the engine's holdable() check).
func _holdable_items() -> Array:
	var out: Array = []
	if bag_source.is_empty() or bag_source.get("progress") == null or bag_source.get("events") == null:
		return out
	var pv = bag_source.progress
	for k in pv.items.keys():
		var id := int(k)
		var n := int(pv.items[k])
		if n <= 0:
			continue
		if not ItemHooks.holdable(bd, id):
			continue
		var pocket := ItemUse.pocket_index(int(bag_source.events.item_pocket(id)))
		if pocket != 0 and pocket != 3:
			continue
		out.append({"id": id, "n": n})
	return out

## Pick a held item to give to party mon `i` (6 per page, party-list layout). The item leaves the bag
## only when the engine accepts the give (the turn is used up).
func _show_give_list(i: int, page: int = 0) -> void:
	_give_to = i
	var items := _holdable_items()
	var side: Dictionary = ctl.state.sides[0]
	var m: Dictionary = side.mons[i] if i >= 0 and i < side.mons.size() else {}
	_clear_menu()
	_menu_mode = "give_list"
	_set_window("action")
	_msg.text = "Give what to\n%s?" % str(m.get("name", ""))
	_party_bg.visible = true
	var per := 6
	var start := page * per
	var n := 0
	for k in mini(per, items.size() - start):
		var it: Dictionary = items[start + k]
		var id := int(it.id)
		var r := Rect2(4 + 118 * (n % 2), 4 + 36 * (n / 2), 114, 32)
		_entry("%s x%d" % [bd.item_name(id), int(it.n)], r, func(): _give_item_to(i, id), true)
		n += 1
	if start + per < items.size():
		_cell("MORE", ACTION_CELLS[2], ACTION_TEXT_DX, func(): _show_give_list(i, page + 1))
	_cell("CANCEL", ACTION_CELLS[3], ACTION_TEXT_DX, func(): _show_party_options(i))
	if not _nav.is_empty():
		_point_at(_nav[0].rect, _nav[0].dx)

func _give_item_to(i: int, id: int) -> void:
	var why := _choose({"kind": "give_item", "to": i, "item": id})
	if why == "" and not bag_source.is_empty() and bag_source.get("progress") != null:
		var pv = bag_source.progress
		pv.remove_item(id, 1)
		pv.save()

func _choose(a: Dictionary) -> String:
	last_submit = a.duplicate(true)
	_clear_menu()
	var why := ctl.submit(_my_slot(), a)
	_set_window("msg")
	if why != "":
		_say("Can't do that right now (%s)." % why)
		_after_playback()
	return why

## Returns an item to the bag (held items given/taken during battle), when the overworld bag is available.
func _return_item_to_bag(item: int) -> void:
	if item <= 0:
		return
	if bag_source.is_empty() or bag_source.get("progress") == null:
		return
	var pv = bag_source.progress
	pv.add_item(item, 1)
	pv.save()

## B button: back from a sub-menu (field tap outside the text box, or Android Back / Esc).
func _back() -> bool:
	match _menu_mode:
		"moves", "bag", "party":
			_show_main()
			return true
		"party_options":
			_show_party(false)
			return true
		"give_list":
			_show_party_options(_give_to)
			return true
		"target":
			_show_moves()
			return true
	return false

# ------------------------------------------------------------- input / closing

## D-pad: move the ▶ cursor to the nearest menu entry in that direction (moves menu: also selects the move,
## updating PP / TYPE, like the ROM). Returns true when the cursor moved.
func nav_move(dir: Vector2) -> bool:
	if _nav.is_empty() or _playing:
		return false
	_nav_i = clampi(_nav_i, 0, _nav.size() - 1)
	var from: Vector2 = (_nav[_nav_i].rect as Rect2).get_center()
	var best := -1
	var best_d := INF
	for k in _nav.size():
		if k == _nav_i:
			continue
		var d: Vector2 = (_nav[k].rect as Rect2).get_center() - from
		var along := d.dot(dir)
		if along <= 1.0:
			continue
		var score := along + absf(d.dot(Vector2(dir.y, dir.x))) * 2.0
		if score < best_d:
			best_d = score
			best = k
	if best < 0:
		return false
	_nav_i = best
	var e: Dictionary = _nav[best]
	if int(e.move) >= 0:
		_select_move(int(e.move))
	else:
		if _menu_mode == "main":
			_action_sel = ACTION_CELLS.find(e.rect)
		_point_at(e.rect, e.dx)
	return true

## A: press the entry under the cursor (disabled entries do nothing, like a greyed-out ROM option).
func nav_accept() -> bool:
	if _nav.is_empty() or _playing:
		return false
	var b: Button = _nav[clampi(_nav_i, 0, _nav.size() - 1)].btn
	if is_instance_valid(b) and not b.disabled:
		b.pressed.emit()
	return true

func _input(e: InputEvent) -> void:
	for d in [["ui_up", Vector2.UP], ["ui_down", Vector2.DOWN], ["ui_left", Vector2.LEFT], ["ui_right", Vector2.RIGHT]]:
		if e.is_action_pressed(d[0], true) and not _playing and not _nav.is_empty():
			nav_move(d[1])
			get_viewport().set_input_as_handled()
			return
	if e.is_action_pressed("ui_accept") and not _playing and not _waiting_close and not _nav.is_empty():
		get_viewport().set_input_as_handled()
		nav_accept()
		return
	if TapInput.is_tap(e) or e.is_action_pressed("ui_accept"):
		if _playing:
			_skip = true
		elif _waiting_close and not _closed:
			_closed = true
			closed.emit()
	elif e.is_action_pressed("ui_cancel") and not _playing and _back():
		get_viewport().set_input_as_handled()

## Taps no button took (menu cells are buttons): a tap on the field goes back from a sub-menu.
func _unhandled_input(e: InputEvent) -> void:
	if _playing or not TapInput.is_tap(e):
		return
	var p: Vector2 = e.position if "position" in e else Vector2.ZERO
	if p.y < stage_point(Vector2(0, TEXTBOX_TOP)).y and _back():
		get_viewport().set_input_as_handled()

## Awaitable: returns after the battle ended and the player tapped once (immediately in auto mode).
func closed_after_end() -> void:
	if ctl.auto:
		while _playing:
			await get_tree().process_frame
		return
	if not _closed:
		await closed

# ------------------------------------------------------------- original placeholder art

## Abstract blob placeholder (NOT a Pokémon drawing): a soft two-tone rounded shape whose proportions vary by
## species id so different species look different, tinted by its types.
class _Blob extends Control:
	var c1 := Color.GRAY
	var c2 := Color.GRAY
	var seed_value := 0
	var back := false
	func _draw() -> void:
		var r := Rect2(Vector2.ZERO, size)
		var cx := r.size.x * 0.5
		var cy := r.size.y * 0.58
		var w := r.size.x * (0.30 + 0.12 * ((seed_value * 7) % 5) / 4.0)
		var h := r.size.y * (0.28 + 0.12 * ((seed_value * 3) % 5) / 4.0)
		draw_set_transform(Vector2(cx, cy), 0.0, Vector2(1.0, h / w))
		draw_circle(Vector2.ZERO, w, c1.darkened(0.15))
		draw_circle(Vector2(0, -w * 0.15), w * 0.82, c1)
		draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
		draw_circle(Vector2(cx + w * 0.35, cy - h * 0.55), w * 0.28, c2)
		if not back:
			draw_circle(Vector2(cx - w * 0.25, cy - h * 0.25), w * 0.08, Color(0.1, 0.1, 0.12))
			draw_circle(Vector2(cx + w * 0.10, cy - h * 0.25), w * 0.08, Color(0.1, 0.1, 0.12))

## Two flat ellipses as battle platforms (original, plain shapes), drawn at the GBA platform positions. Only
## visible when there is no ROM background and no real picture.
class _Arena extends Control:
	func _draw() -> void:
		var stage_origin := Vector2.ZERO
		var stage_scale := size.x / 240.0
		for r in [FOE_PLATFORM, PLAYER_PLATFORM]:
			var rr: Rect2 = r
			var c := stage_origin + rr.get_center() * stage_scale
			var rad := rr.size.x * 0.5 * stage_scale
			draw_set_transform(c, 0.0, Vector2(1.0, (rr.size.y if rr != PLAYER_PLATFORM else 24.0) / rr.size.x))
			draw_circle(Vector2.ZERO, rad, Color(0.16, 0.2, 0.24))
		draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)

## Neutral stand-in for the ROM text box when the cache has no battle_ui/ (KI-56): plain frames of the same
## shape as the ROM layouts. Not ROM art; shown only until the add-on import has run.
class _WindowStandIn extends Control:
	var mode := "msg"
	func _draw() -> void:
		var k := size.x / 240.0
		draw_rect(Rect2(Vector2.ZERO, size), Color8(74, 65, 82))
		var dark := Color8(106, 164, 164)
		var light := Color8(248, 248, 248)
		var edge := Color8(74, 65, 82)
		var boxes := []
		match mode:
			"msg":
				boxes = [[Rect2(2, 2, 236, 44), dark]]
			"action":
				boxes = [[Rect2(2, 2, 116, 44), dark], [Rect2(122, 2, 116, 44), light]]
			"moves":
				boxes = [[Rect2(2, 2, 156, 44), light], [Rect2(162, 2, 76, 44), light]]
		for b in boxes:
			var r: Rect2 = b[0]
			draw_rect(Rect2(r.position * k, r.size * k), edge)
			draw_rect(Rect2((r.position + Vector2(2, 2)) * k, (r.size - Vector2(4, 4)) * k), b[1])

## Small triangle marker: the menu cursor (pointing right) or the "more / tap" marker (pointing down).
class _Marker extends Control:
	var down := false
	var color := Color8(213, 74, 57)
	func _draw() -> void:
		var pts := PackedVector2Array([Vector2.ZERO, Vector2(size.x, size.y / 2.0), Vector2(0, size.y)])
		if down:
			pts = PackedVector2Array([Vector2.ZERO, Vector2(size.x, 0), Vector2(size.x / 2.0, size.y)])
		draw_colored_polygon(pts, color)
