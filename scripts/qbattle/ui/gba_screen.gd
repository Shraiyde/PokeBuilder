class_name GbaScreen
extends RefCounted
## GbaScreen — where the 240x160 game screen goes (0.1.11 portrait, "like a Game Boy").
## Portrait (height > 1.2 × width): the screen sits at the top (below the safe-area inset), scaled by a whole
## number of PHYSICAL pixels per GBA pixel (floor(window width / 240), so 1080 px wide = 4x = 960x640), centred
## horizontally, never stretched or scaled differently in X and Y. Below it: an info strip (status / toasts /
## debug line) and the on-screen controller (ui/game_pad.gd).
## Landscape (desktop windows, old tests): the screen is centred both ways (pillarbox), no controller.
## All rects are in viewport (logical) units; `scale` = logical px per GBA px (integer in physical px).
## Depends on: UiTheme (safe insets). Used by: ui/game_pad.gd, ui/battle_screen.gd, ui/game.gd,
## ui/dialogue_box.gd, ui/tap_input.gd.

const GBA := Vector2(240, 160)
const STRIP := 56.0        # info strip height (logical) between the screen and the controller

# When the Rayquaza controller skin is active (ui/game_pad.gd), this holds the game screen rect in screen
# (logical) pixels, and layout() places the 240x160 game screen inside it instead of at the top of the
# viewport. Set by GamePad._relayout(); null = default top-of-screen layout.
static var _skin_screen_static = null

## {portrait, scale, rect (screen), strip (info strip), pad (controller area), view (visible size), cs}
static func layout(vp: Viewport) -> Dictionary:
	var vis := vp.get_visible_rect().size if vp != null else Vector2(540, 960)
	var win := vis
	if vp != null and vp is Window:
		win = Vector2((vp as Window).size)
	elif vp != null and vp.get_window() != null:
		win = Vector2(vp.get_window().size)
	if win.x <= 0 or win.y <= 0:
		win = vis
	var cs := win.y / vis.y if vis.y > 0 else 1.0            # physical px per logical px (canvas_items stretch)
	var ins := UiTheme.safe_insets(vp) if vp != null else Vector4.ZERO
	var portrait := win.y > win.x * 1.2
	var k := 1.0
	var origin := Vector2.ZERO
	var s := 1.0
	var r := Rect2(Vector2.ZERO, GBA)
	var strip := Rect2(0, 0, vis.x, 0.0)
	var pad := Rect2()
	if portrait and _skin_screen_static != null:
		# Skin mode: the game screen sits inside the skin's screen cutout.
		# FIX (gray screen on launch): this branch used to fall through to the
		# non-skin computation below, which redeclared s/r/strip/pad in the
		# same scope ("There is already a variable named s declared in this
		# scope") and broke the whole script, and with it GamePad and Main.
		r = _skin_screen_static
		s = _skin_screen_static.size.x / GBA.x
		strip = Rect2(0, r.end.y, vis.x, STRIP)
		pad = Rect2(0, strip.end.y, vis.x, maxf(0.0, vis.y - ins.w - strip.end.y))
		return {"portrait": portrait, "scale": s, "phys": k, "rect": r, "strip": strip, "pad": pad, "view": vis, "cs": cs}
	elif portrait:
		k = maxf(1.0, floorf(win.x / GBA.x))
		while k > 1.0 and GBA.y * k > win.y * 0.5:
			k -= 1.0
		origin = Vector2(floorf((win.x - GBA.x * k) / 2.0) / cs, ins.y)
	else:
		k = maxf(1.0, floorf(minf(win.x / GBA.x, win.y / GBA.y)))
		origin = Vector2(floorf((win.x - GBA.x * k) / 2.0), floorf((win.y - GBA.y * k) / 2.0)) / cs
	s = k / cs
	r = Rect2(origin, GBA * s)
	strip = Rect2(0, r.end.y, vis.x, STRIP if portrait else 0.0)
	pad = Rect2(0, strip.end.y, vis.x, maxf(0.0, vis.y - ins.w - strip.end.y)) if portrait else Rect2()
	return {"portrait": portrait, "scale": s, "phys": k, "rect": r, "strip": strip, "pad": pad, "view": vis, "cs": cs}

static func rect(vp: Viewport) -> Rect2:
	return layout(vp).rect

## A Control sized to exactly the 240x160 gameboy screen rect at the top of the viewport.
## Build full-screen UIs inside this (instead of PRESET_FULL_RECT) so nothing is drawn
## under the on-screen controller below it (the controller is always on top in portrait).
static func screen_container(vp: Viewport) -> Control:
	var L := layout(vp)
	var c := Control.new()
	c.position = L.rect.position
	c.size = L.rect.size
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	c.theme = UiTheme.shared()
	return c

## True when the on-screen controller is in use (portrait) and `p` (logical) is outside the game screen.
static func outside_screen(vp: Viewport, p: Vector2) -> bool:
	var L := layout(vp)
	return L.portrait and not L.rect.has_point(p)
