class_name BagScreen
extends CanvasLayer
## BagScreen — the bag on the 240x160 game screen (overworld START menu and battle BAG),
## adapted from Quetzal (game/ui/bag_screen.gd) to the PokeBuilder port.
## Our own layout in the spirit of Emerald's bag: pocket name with ◀ ▶ at the top, the item
## list (name ×count) with a cursor, the description of the selected item at the bottom.
## D-pad: up/down item, left/right pocket; A use; B back.
## Taps: a row = use it, the pocket bar halves = previous/next pocket, outside the window = back.
## After an item that needs a target: a party list (and for Ether/Max Ether a move list).
## Emits used(item, party_index, move_index) (-1 = none) or closed. The caller applies/consumes the item.
##
## PORT ADAPTATIONS (see ui-helpers-design.md for the full list):
## - Item names / descriptions / pockets come from the port's BattleData adapter
##   (bd.item_name / bd.item_desc / bd.item_pocket — item_desc and item_pocket
##   are new accessors, see the BattleData diff note), NOT from Quetzal's
##   EventStore (`events`). The `events` var is RETAINED only because
##   battle_screen.gd assigns it (bag.events = bag_source.events); BagScreen
##   no longer reads item data from it.
## - Pockets are the port's five (ItemUse.POCKETS: ITEMS, POKé BALLS,
##   MATERIALS, KEY ITEMS, MEDICINE), not Quetzal's (TMs & HMs / BERRIES).
## - The streamed ROM bag background (the satchel, SpriteSource.menu_ui) is
##   gone: there is no ROM cache in the port, so the bag draws its white
##   list window on the plain GBA stage instead of over the satchel art.
## - The Repel / Escape Rope no-target check now passes bd
##   (ItemUse.is_no_target_field_item(bd, id) — name-based in the port).
## Depends on: BattleData, ItemUse, UiTheme, TapInput, GbaScreen.
## Used by: ui/battle_screen.gd (_open_bag).
signal used(item: int, to: int, move: int)
signal closed

const WIN := Rect2(4, 2, 232, 156)
const BAG_WIN := Rect2(144, 2, 92, 156)   # GBA px: the main bag list window (right side, see _win_rect)
const ROWS := 6
const PITCH := 16.0
const TEXT := Color8(72, 72, 80)

var events                      # Retained: battle_screen.gd assigns bag.events = bag_source.events.
								# BagScreen itself no longer reads item data from it (see _item_name etc.).
var bd: BattleData              # effects (bag table), balls, move PP, item names/descs/pockets
var items: Dictionary = {}      # progress.items (read only here), keyed by str(item id)
var party: Array = []           # party records (field) or battle snapshots (battle), own mons only
var party_index: Array = []     # index to report for each entry of `party`
var preset_target := -1         # 0.1.42: party-screen ITEM: skip the target picker, use this progress.party index
var context := "field"          # field | battle
var wild := true                # battle: balls allowed
var pocket := 0
var sel := 0
var top := 0
var mode := "bag"               # bag | party | move | msg
var message := ""
var _item := 0
var _to := -1
var _root: Control
var _labels: Array = []

func _ready() -> void:
	layer = 28 if context == "battle" else 24   # above the battle screen (27)
	_root = Control.new()
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.theme = UiTheme.shared()
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.draw.connect(_draw_win)
	add_child(_root)
	get_viewport().size_changed.connect(_relayout)
	_relayout()

## Item name from the port's BattleData (item_name is a port addition fix:
## it must return the real Pokewilds item name, not "Item %d" — see the
## BattleData diff note). Falls back to `events` when bd is unset, else a placeholder.
func _item_name(id: int) -> String:
	if bd != null:
		return bd.item_name(id)
	if events != null and events.has_method("item_name"):
		return str(events.call("item_name", id))
	return "Item %d" % id

## Item description from the port's BattleData (item_desc is a new accessor —
## see the BattleData diff note). Falls back to `events`, else "".
func _item_desc(id: int) -> String:
	if bd != null:
		return bd.item_desc(id)
	if events != null and events.has_method("item_desc"):
		return str(events.call("item_desc", id))
	return ""

## Item pocket index from the port's BattleData (item_pocket is a new accessor —
## see the BattleData diff note). Falls back to `events`, else pocket 0 (ITEMS).
func _item_pocket(id: int) -> int:
	if bd != null:
		return bd.item_pocket(id)
	if events != null and events.has_method("item_pocket"):
		return int(events.call("item_pocket", id))
	return 0

func entries() -> Array:
	return ItemUse.list(items, bd, pocket)

func _L() -> Dictionary:
	return GbaScreen.layout(get_viewport())

func _gba(r: Rect2) -> Rect2:
	var L := _L()
	return Rect2(L.rect.position + r.position * L.scale, r.size * L.scale)

## Window rect: the main bag list sits in the right-side BAG_WIN. Party/move
## pickers keep their content-sized full-width window (transient, and they need
## the width for party info); msg uses the bag window.
func _win_rect() -> Rect2:
	if mode == "party" or mode == "move":
		var n := mini(ROWS, _rows().size())
		return Rect2(WIN.position.x, WIN.position.y, WIN.size.x, 20 + PITCH * n + 8)
	return BAG_WIN

func _label(t: String, r: Rect2, size := 11.0, al := HORIZONTAL_ALIGNMENT_LEFT) -> void:
	var l := Label.new()
	l.text = t
	l.clip_text = true
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART if r.size.y > 20 else TextServer.AUTOWRAP_OFF
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	l.add_theme_font_size_override("font_size", int(round(size * _L().scale)))
	l.add_theme_color_override("font_color", TEXT)
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER if r.size.y <= 20 else VERTICAL_ALIGNMENT_TOP
	l.horizontal_alignment = al
	var g := _gba(r)
	l.position = g.position
	l.size = g.size
	_root.add_child(l)
	_labels.append(l)

func _rows() -> Array:
	match mode:
		"party":
			var out: Array = []
			for m in party:
				var mx := int(m.get("max_hp", m.get("stats", {}).get("hp", 0)))
				var st := str(m.get("status", "")).to_upper()
				out.append("%s  Lv%d  %d/%d %s" % [str(m.get("name", "?")), int(m.get("level", 1)), int(m.get("hp", 0)), mx, st])
			out.append("CANCEL")
			return out
		"move":
			var out: Array = []
			var m: Dictionary = party[_to] if _to >= 0 and _to < party.size() else {}
			var mv: Array = m.get("moves", [])
			var pp: Array = m.get("pp", [])
			for i in mv.size():
				var e = mv[i]
				var nm := str(e[1]) if e is Array and e.size() > 1 else (bd.move_name(int(e.get("id", 0))) if e is Dictionary else str(e))
				var cur := int(pp[i]) if i < pp.size() else (int(e.get("pp", 0)) if e is Dictionary else 0)
				out.append("%s  PP %d" % [nm, cur])
			return out
	var out2: Array = []
	for e in entries():
		out2.append("%s" % _item_name(int(e[0])))
	out2.append("CLOSE BAG")
	return out2

func _relayout() -> void:
	for l in _labels:
		l.queue_free()
	_labels.clear()
	var rows := _rows()
	sel = clampi(sel, 0, maxi(0, rows.size() - 1))
	if sel < top:
		top = sel
	if sel >= top + ROWS:
		top = sel - ROWS + 1
	# 0.1.60 layout pass: bag/msg labels live in the right-side window (BAG_WIN); party/move
	# pickers keep the full-width window. Msg shows the pocket header (it lists bag entries).
	var wx := BAG_WIN.position.x if mode == "bag" or mode == "msg" else WIN.position.x
	var ww := BAG_WIN.size.x if mode == "bag" or mode == "msg" else WIN.size.x
	var head := "◀ %s ▶" % ItemUse.POCKETS[pocket] if mode == "bag" or mode == "msg" else ("Use on which POKéMON?" if mode == "party" else "Restore which move?")
	_label(head, Rect2(wx + 4, WIN.position.y + 2, ww - 8, 16), 11, HORIZONTAL_ALIGNMENT_CENTER)
	var ents := entries()
	for i in range(top, mini(rows.size(), top + ROWS)):
		var y := WIN.position.y + 20 + PITCH * (i - top)
		if mode == "bag" or mode == "msg":
			_label(rows[i], Rect2(wx + 4, y, 64, PITCH), 9)
			if mode == "bag" and i < ents.size():
				_label("×%d" % int(ents[i][1]), Rect2(wx + 68, y, 20, PITCH), 9, HORIZONTAL_ALIGNMENT_RIGHT)
		else:
			_label(rows[i], Rect2(WIN.position.x + 16, y, 208, PITCH))
	var desc := message
	if desc == "" and mode == "bag":
		desc = _item_desc(int(ents[sel][0])) if sel < ents.size() else "Close the BAG."
	if desc != "":
		_label(desc.replace("\n", " "), Rect2(wx + 4, WIN.position.y + 20 + PITCH * ROWS + 4, ww - 8, 32), 9)
	_root.queue_redraw()

func _draw_win() -> void:
	var L := _L()
	var s: float = L.scale
	var w := _gba(_win_rect())
	# PORT: no streamed ROM bag background (no ROM cache in the port), so the
	# list window is drawn on the plain stage — white fill, dark frame.
	_root.draw_rect(w, Color8(255, 255, 255))
	_root.draw_rect(w, Color8(74, 65, 82), false, maxf(2.0, s))
	if mode == "bag" or mode == "msg":
		var sep := WIN.position.y + 20 + PITCH * ROWS + 2
		_root.draw_line(L.rect.position + Vector2(BAG_WIN.position.x + 2, sep) * s, L.rect.position + Vector2(BAG_WIN.end.x - 2, sep) * s, Color8(160, 168, 184), maxf(1.0, s * 0.5))
	var wx := BAG_WIN.position.x if mode == "bag" or mode == "msg" else WIN.position.x
	var cy := WIN.position.y + 20 + PITCH * (sel - top) + PITCH / 2.0
	var p: Vector2 = L.rect.position + Vector2(wx + 6, cy) * s
	_root.draw_colored_polygon(PackedVector2Array([p + Vector2(0, -4) * s, p + Vector2(5, 0) * s, p + Vector2(0, 4) * s]), TEXT)

func row_at(p: Vector2) -> int:
	var wx := BAG_WIN.position.x if mode == "bag" or mode == "msg" else WIN.position.x
	var ww := BAG_WIN.size.x if mode == "bag" or mode == "msg" else WIN.size.x
	for i in ROWS:
		if _gba(Rect2(wx, WIN.position.y + 20 + PITCH * i, ww, PITCH)).has_point(p):
			return top + i
	return -1

func _input(e: InputEvent) -> void:
	var handled := true
	if mode == "msg":
		if e.is_action_pressed("ui_accept") or e.is_action_pressed("ui_cancel") or TapInput.is_tap(e):
			message = ""
			mode = "bag"
			_relayout()
		else:
			handled = e is InputEventAction or e is InputEventKey
	elif e.is_action_pressed("ui_up", true):
		sel = (sel + _rows().size() - 1) % maxi(1, _rows().size())
		_relayout()
	elif e.is_action_pressed("ui_down", true):
		sel = (sel + 1) % maxi(1, _rows().size())
		_relayout()
	elif mode == "bag" and e.is_action_pressed("ui_left", true):
		switch_pocket(-1)
	elif mode == "bag" and e.is_action_pressed("ui_right", true):
		switch_pocket(1)
	elif e.is_action_pressed("ui_accept"):
		accept()
	elif e.is_action_pressed("ui_cancel"):
		back()
	elif TapInput.is_tap(e):
		var r := row_at(e.position)
		var head := _gba(Rect2(BAG_WIN.position.x, WIN.position.y, BAG_WIN.size.x, 18))
		if head.has_point(e.position) and mode == "bag":
			switch_pocket(-1 if e.position.x < head.get_center().x else 1)
		elif r >= 0 and r < _rows().size():
			sel = r
			accept()
		elif not _gba(_win_rect()).has_point(e.position):
			back()
	else:
		handled = false
	if handled:
		get_viewport().set_input_as_handled()

func switch_pocket(d: int) -> void:
	pocket = (pocket + d + ItemUse.POCKETS.size()) % ItemUse.POCKETS.size()
	sel = 0
	top = 0
	_relayout()

func _say(t: String) -> void:
	message = t
	mode = "msg"
	_relayout()

## A on the current row.
func accept() -> void:
	match mode:
		"bag":
			var ents := entries()
			if sel >= ents.size():
				close()
				return
			_item = int(ents[sel][0])
			if ItemUse.is_ball(bd, _item):
				if context != "battle":
					_say("There's no Pokémon to catch here.")
				elif not wild:
					_say("You can't catch a trainer's Pokémon!")
				else:
					_finish(-1, -1)
				return
			var k := str(ItemUse.kind(bd, _item).get("k", ""))
			if context == "battle" and k in ["x", "dire_hit", "guard_spec"]:
				_finish(-1, -1)
				return
			if not ItemUse.field_usable(bd, _item):
				_say("You can't use that here.")
				return
			# 0.1.49: rods need no party target — finish at once (to = -1); game.gd fishes.
			if context == "field" and ItemUse.is_rod(bd, _item):
				_finish(-1, -1)
				return
			# 0.1.65: Repel / Escape Rope need no party target — finish at once (to = -1); game.gd uses them.
			if context == "field" and ItemUse.is_no_target_field_item(bd, _item):
				_finish(-1, -1)
				return
			# 0.1.42: preset target (party-screen ITEM) — skip the target picker.
			if preset_target >= 0:
				var prow := -1
				for r in party.size():
					if r < party_index.size() and int(party_index[r]) == preset_target:
						prow = r
						break
				if prow < 0 and preset_target < party.size():
					prow = preset_target
				if prow >= 0:
					_to = prow
					if ItemUse.needs_move(bd, _item):
						mode = "move"
						sel = 0
						top = 0
						_relayout()
						return
					if not ItemUse.has_effect(bd, _item, party[_to]):
						_say("It won't have any effect.")
						return
					_finish(_to, -1)
					return
			mode = "party"
			sel = 0
			top = 0
			_relayout()
		"party":
			if sel >= party.size():
				back()
				return
			_to = sel
			if ItemUse.needs_move(bd, _item):
				mode = "move"
				sel = 0
				top = 0
				_relayout()
				return
			if not ItemUse.has_effect(bd, _item, party[_to]):
				_say("It won't have any effect.")
				return
			_finish(_to, -1)
		"move":
			if not ItemUse.has_effect(bd, _item, party[_to], sel):
				_say("It won't have any effect.")
				return
			_finish(_to, sel)

func back() -> void:
	match mode:
		"move":
			mode = "party"
			sel = _to
		"party":
			mode = "bag"
			sel = 0
		_:
			close()
			return
	top = 0
	_relayout()

func _finish(to: int, mv: int) -> void:
	used.emit(_item, party_index[to] if to >= 0 and to < party_index.size() else to, mv)
	close()

func close() -> void:
	if is_queued_for_deletion():
		return
	closed.emit()
	queue_free()
