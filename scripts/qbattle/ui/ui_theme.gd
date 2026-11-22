class_name UiTheme
extends RefCounted
## UiTheme — code-built Theme (readable fonts, touch-sized controls at the 960x540 base size) and
## small factory helpers (button, label, safe-area root container). Built in code so no theme assets ship.
## Depends on: nothing. Used by: every ui/*.gd screen.

const FONT := 22
const SMALL := 18
const TOUCH := 56

static var _shared: Theme

## The single Theme instance used app-wide (built on first use).
static func shared() -> Theme:
	if _shared == null:
		_shared = make()
	return _shared

## Builds a new Theme (fonts, button/line-edit/panel/progress styles).
## Quetzal ROM style: the colours are sampled from the ROM's own
## battle text boxes (sprites/battle_ui, decoded at import) —
## message-box teal #6aa4a4, dark frame #4a4152, accent red #d54a39,
## white menu boxes. Buttons: white face, dark frame, red frame on
## focus (the ROM's red cursor), teal when pressed. Panels: white
## with the dark frame. HP fill matches the battle HP green.
static func make() -> Theme:
	var t := Theme.new()
	t.default_font_size = FONT
	for cls in ["Button", "LineEdit"]:
		for st in ["normal", "hover", "pressed", "focus", "disabled", "read_only"]:
			var sb := StyleBoxFlat.new()
			sb.bg_color = Color(0.98, 0.98, 0.97) if st != "pressed" else Color8(106, 164, 164)
			if st == "hover": sb.bg_color = Color(1.0, 1.0, 1.0)
			if st == "disabled": sb.bg_color = Color(0.75, 0.75, 0.75)
			if cls == "LineEdit" and st in ["normal", "focus"]: sb.bg_color = Color(1.0, 1.0, 1.0)
			sb.border_color = Color8(213, 74, 57) if st == "focus" else Color8(74, 65, 82)
			sb.set_border_width_all(3)
			sb.set_corner_radius_all(8)
			sb.content_margin_left = 16
			sb.content_margin_right = 16
			sb.content_margin_top = 10
			sb.content_margin_bottom = 10
			t.set_stylebox(st, cls, sb)
		t.set_color("font_color", cls, Color(0.1, 0.1, 0.1))
		t.set_color("font_pressed_color", cls, Color(0.05, 0.05, 0.05))
		t.set_color("font_hover_color", cls, Color(0.1, 0.1, 0.1))
		t.set_color("font_focus_color", cls, Color(0.1, 0.1, 0.1))
	var panel := StyleBoxFlat.new()
	panel.bg_color = Color(1.0, 1.0, 1.0, 0.97)
	panel.border_color = Color8(74, 65, 82)
	panel.set_border_width_all(3)
	panel.set_corner_radius_all(12)
	panel.set_content_margin_all(16)
	t.set_stylebox("panel", "PanelContainer", panel)
	var pb_bg := StyleBoxFlat.new()
	pb_bg.bg_color = Color8(74, 65, 82)
	pb_bg.set_corner_radius_all(8)
	var pb_fill := StyleBoxFlat.new()
	pb_fill.bg_color = Color8(88, 208, 128)
	pb_fill.set_corner_radius_all(8)
	t.set_stylebox("background", "ProgressBar", pb_bg)
	t.set_stylebox("fill", "ProgressBar", pb_fill)
	t.set_constant("separation", "VBoxContainer", 12)
	t.set_constant("separation", "HBoxContainer", 12)
	return t

## Full-rect root with safe-area-aware margins (notches/rounded corners), in viewport units.
static func safe_root(parent: Node, extra: int = 16) -> MarginContainer:
	var m := MarginContainer.new()
	m.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	m.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(m)
	var ins := safe_insets(parent.get_viewport())
	m.add_theme_constant_override("margin_left", extra + int(ins.x))
	m.add_theme_constant_override("margin_top", extra + int(ins.y))
	m.add_theme_constant_override("margin_right", extra + int(ins.z))
	m.add_theme_constant_override("margin_bottom", extra + int(ins.w))
	return m

## Returns (left, top, right, bottom) safe-area insets converted to viewport units.
static func safe_insets(vp: Viewport) -> Vector4:
	if not OS.has_feature("mobile") or vp == null:
		return Vector4.ZERO
	var win := DisplayServer.window_get_size()
	var safe := DisplayServer.get_display_safe_area()
	if win.x <= 0 or safe.size.x <= 0:
		return Vector4.ZERO
	var k := vp.get_visible_rect().size.x / float(win.x)
	return Vector4(safe.position.x, safe.position.y, win.x - safe.end.x, win.y - safe.end.y) * k

## Touch-sized Button (height UiTheme.TOUCH) wired to cb.
static func button(text: String, cb: Callable, min_w: int = 0) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(min_w, TOUCH)
	b.pressed.connect(cb)
	return b

## Label with a font size; wrap=true enables word wrap + horizontal expand.
static func label(text: String, size: int = FONT, wrap: bool = false) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", size)
	if wrap:
		l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return l
