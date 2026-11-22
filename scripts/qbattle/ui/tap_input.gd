class_name TapInput
extends RefCounted
## TapInput — one shared rule for "the player tapped to continue" on dialogue screens.
## Why: on the phone, a tap reaches Godot both as InputEventScreenTouch and (because
## input_devices/pointing/emulate_mouse_from_touch is on by default) as an emulated left mouse press.
## Counting both would skip a page per tap. Dialogue screens therefore check taps in `_input()` (before the GUI,
## so panels/labels with mouse_filter STOP can't swallow them) and call `is_tap()` to count each tap once.
## Rule for every dialogue screen: while a "tap to continue" is pending there are no buttons on screen, so a tap
## anywhere advances; while a menu is shown, don't consume taps (buttons need them).
## Depends on: GamePad, GbaScreen (0.1.11: no taps from the controller area). Used by: ui/intro_screen.gd, ui/battle_screen.gd.

## True for exactly one event per finger tap or mouse click (press, not release).
## Keyboard/gamepad confirm is handled separately via the "ui_accept" action.
static func is_tap(e: InputEvent) -> bool:
	# 0.1.11 portrait: touches on the controller below the game screen are buttons, never "taps".
	if (e is InputEventMouseButton or e is InputEventScreenTouch) and GamePad.active() \
			and GbaScreen.outside_screen(GamePad.instance.get_viewport(), e.position):
		return false
	if e is InputEventMouseButton:
		return e.pressed and e.button_index == MOUSE_BUTTON_LEFT
	if e is InputEventScreenTouch:
		# Only count raw touches when Godot is NOT also emulating a mouse click for them.
		return e.pressed and not ProjectSettings.get_setting("input_devices/pointing/emulate_mouse_from_touch", true)
	return false
