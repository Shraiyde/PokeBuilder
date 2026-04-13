## SceneManager
## Singleton that manages scene changes with transition effects
## (fade to black, slides, etc.) and a scene stack for menus.
##
## Usage:
##   SceneManager.goto("res://scenes/overworld/map.tscn")
##   SceneManager.goto("res://scenes/battle/battle_scene.tscn", SceneManager.Transition.FADE)
##   SceneManager.push("res://scenes/ui/party_screen.tscn")   # stacks on top of the current scene
##   SceneManager.pop()                                         # returns to the previous scene
extends Node

# ---------------------------------------------------------------------------
# Enumerations
# ---------------------------------------------------------------------------

## Transition type when changing scenes.
enum Transition {
	NONE,          ## Instant change with no effect
	FADE,          ## Fade to black and back
	FADE_WHITE,    ## Fade to white (evolution, flash)
	SLIDE_LEFT,    ## Slide to the left
	SLIDE_RIGHT,   ## Slide to the right
	POKEBALL,      ## Poké Ball effect (circular wipe)
}

# ---------------------------------------------------------------------------
# Signals
# ---------------------------------------------------------------------------

## Emitted just before the new scene becomes visible.
signal scene_changing(to_path: String)

## Emitted when the new scene is fully visible.
signal scene_changed(to_path: String)

## Emitted when a scene is pushed onto the stack.
signal scene_pushed(path: String)

## Emitted when a scene is popped from the stack.
signal scene_popped(to_path: String)

# ---------------------------------------------------------------------------
# Internal state
# ---------------------------------------------------------------------------

const DEFAULT_FADE_DURATION := 0.4

## Scene path stack for the push / pop menu system.
var _scene_stack: Array = []

## True while a transition is running (blocks new requests).
var _transitioning: bool = false

## Reference to the transition overlay (ColorRect above the canvas).
var _overlay: ColorRect

# ---------------------------------------------------------------------------
# Lifecycle
# ---------------------------------------------------------------------------

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_create_overlay()


func _create_overlay() -> void:
	var canvas: CanvasLayer = CanvasLayer.new()
	canvas.layer = 100  # Above everything else
	canvas.name = "TransitionLayer"

	_overlay = ColorRect.new()
	_overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_overlay.color = Color.BLACK
	_overlay.modulate.a = 0.0
	_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE

	canvas.add_child(_overlay)
	add_child(canvas)

# ---------------------------------------------------------------------------
# Main navigation
# ---------------------------------------------------------------------------

## Changes to a new scene, discarding the current one.
## path: res:// path to a .tscn file
## transition: transition effect type
## duration: duration of each half of the transition (fade out + fade in)
func goto(path: String, transition := Transition.FADE, duration := DEFAULT_FADE_DURATION) -> void:
	if _transitioning:
		push_warning("SceneManager: goto('%s') ignored because a transition is already running." % path)
		return

	_scene_stack.clear()
	_transitioning = true
	scene_changing.emit(path)

	await _fade_in_overlay(transition, duration)
	get_tree().change_scene_to_file(path)
	await get_tree().process_frame  # Wait for the new scene to be in the tree

	await _fade_out_overlay(transition, duration)
	_transitioning = false
	scene_changed.emit(path)


## Pushes a new scene on top of the current one (useful for menus and pause screens).
## The pushed scene is added as a child of the current root.
func push(path: String, transition := Transition.FADE, duration := DEFAULT_FADE_DURATION) -> void:
	if _transitioning:
		return

	var current_scene: Node = get_tree().current_scene
	if current_scene:
		_scene_stack.append(current_scene.scene_file_path)

	_transitioning = true
	await _fade_in_overlay(transition, duration)

	var new_scene: Node = load(path).instantiate()
	get_tree().root.add_child(new_scene)
	get_tree().current_scene = new_scene

	# Hide the previous scene to save performance
	if current_scene:
		current_scene.process_mode = Node.PROCESS_MODE_DISABLED
		current_scene.visible = false

	await _fade_out_overlay(transition, duration)
	_transitioning = false
	scene_pushed.emit(path)


## Pops the top scene from the stack and returns to the previous one.
func pop(transition := Transition.FADE, duration := DEFAULT_FADE_DURATION) -> void:
	if _transitioning or _scene_stack.is_empty():
		return

	_transitioning = true
	var previous_path: String = _scene_stack.pop_back()

	await _fade_in_overlay(transition, duration)

	# Remove the current scene
	var current: Node = get_tree().current_scene
	if current:
		current.queue_free()
		await current.tree_exited

	# Re-activate the previous scene
	var root: Window = get_tree().root
	for child: Node in root.get_children():
		if child.scene_file_path == previous_path:
			child.process_mode = Node.PROCESS_MODE_INHERIT
			child.visible = true
			get_tree().current_scene = child
			break

	await _fade_out_overlay(transition, duration)
	_transitioning = false
	scene_popped.emit(previous_path)


## Changes to a new scene instantly with no transition (equivalent to goto with NONE).
func goto_instant(path: String) -> void:
	await goto(path, Transition.NONE, 0.0)

# ---------------------------------------------------------------------------
# Reload current scene
# ---------------------------------------------------------------------------

## Reloads the currently active scene.
func reload(transition := Transition.FADE, duration := DEFAULT_FADE_DURATION) -> void:
	var path: String = get_tree().current_scene.scene_file_path
	await goto(path, transition, duration)

# ---------------------------------------------------------------------------
# Transition helpers
# ---------------------------------------------------------------------------

func _fade_in_overlay(transition: Transition, duration: float) -> void:
	match transition:
		Transition.NONE:
			return
		Transition.FADE, Transition.POKEBALL:
			_overlay.color = Color.BLACK
		Transition.FADE_WHITE:
			_overlay.color = Color.WHITE
		Transition.SLIDE_LEFT, Transition.SLIDE_RIGHT:
			_overlay.color = Color.BLACK

	_overlay.modulate.a = 0.0
	var tween: Tween = create_tween()
	tween.tween_property(_overlay, "modulate:a", 1.0, duration)
	await tween.finished


func _fade_out_overlay(transition: Transition, duration: float) -> void:
	if transition == Transition.NONE:
		return

	var tween: Tween = create_tween()
	tween.tween_property(_overlay, "modulate:a", 0.0, duration)
	await tween.finished

# ---------------------------------------------------------------------------
# State queries
# ---------------------------------------------------------------------------

## Returns true if a transition is currently running.
func is_transitioning() -> bool:
	return _transitioning

## Returns the number of scenes on the stack.
func stack_depth() -> int:
	return _scene_stack.size()

## Returns the path of the scene at the top of the stack (the one that would be restored by pop()).
func peek_stack() -> String:
	return _scene_stack.back() if not _scene_stack.is_empty() else ""
