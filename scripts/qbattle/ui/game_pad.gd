class_name GamePad
extends RefCounted
## GamePad — STUB for the PokeBuilder port (the full Quetzal on-screen gamepad,
## game/ui/game_pad.gd, 981 lines, is NOT ported).
##
## Why a stub: the port's battle context has no on-screen controller. Battle
## input comes from Godot's built-in actions (ui_up/ui_down/ui_left/ui_right,
## ui_accept/ui_cancel — the D-pad / A / B the battle screen already reads)
## plus TapInput for touch taps. There is no GamePad node in the tree, no
## GBA SP skin, no hinge zones, no edit mode, and no info strip to show a
## debug line on.
##
## What battle_screen.gd actually uses (the only call site):
##   - `GamePad.debug_line(text)` (battle_screen.gd:1059): shows the "pics:
##     <reason>" debug line on the controller's info strip when one exists.
##     Here there is no controller, so it returns false and battle_screen
##     keeps the label visible in the pillarbox instead (its own fallback).
## What TapInput uses:
##   - `GamePad.active()` (tap_input.gd): true only when a GamePad instance
##     is in the tree, visible, and in portrait. Here always false, so
##     TapInput never treats a tap as "from the controller area" and every
##     tap is counted normally.
##   - `GamePad.instance` (tap_input.gd): only read when active() is true
##     (short-circuit), so it is never dereferenced here; it stays null.
##
## Deliberately NOT ported: ensure(), skins, layouts, hit-testing, multitouch,
## hold-to-repeat, haptics, edit mode, status/toast, reset_input(), is_held(),
## skin_screen_rect(). If the port later adds its own on-screen controller, it
## should provide a real GamePad with the same three members (instance,
## active(), debug_line()) and the battle screen + TapInput will pick it up
## with no changes.

## The (absent) on-screen controller instance. Always null in the port.
static var instance: GamePad = null

## True when a GamePad instance is in the tree, visible, and in portrait.
## Always false: the port has no on-screen controller in the battle context.
static func active() -> bool:
	return false

## Shows `t` on the controller's info strip. Returns false: there is no
## controller, so the caller (battle_screen.gd) keeps its own debug label.
static func debug_line(t: String) -> bool:
	return false
