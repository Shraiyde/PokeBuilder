## GameManager
## Central game singleton. Manages the global state, game settings,
## and feature flags that the fangame creator can enable or disable.
##
## Usage:
##   GameManager.change_state(GameManager.State.BATTLE)
##   if GameManager.features.mega_evolution: ...
##   GameManager.settings.text_speed = GameManager.TextSpeed.FAST
extends Node

# ---------------------------------------------------------------------------
# Enumerations
# ---------------------------------------------------------------------------

## Global game state. Determines which systems are active.
enum State {
	BOOT,       ## Initial boot, loading resources
	TITLE,      ## Title screen
	OVERWORLD,  ## Player on the map / exploring
	BATTLE,     ## In combat
	MENU,       ## Menu paused on top of another state
	CUTSCENE,   ## Cutscene / game event in progress
	DIALOGUE,   ## Dialogue box active
	TRANSITION, ## Scene transition in progress (blocking)
	GAME_OVER,  ## Game Over screen
}

## Text speed for dialogue boxes.
enum TextSpeed { SLOW = 1, NORMAL = 2, FAST = 3, INSTANT = 4 }

## Player's preferred battle style.
enum BattleStyle { SHIFT, SET }

# ---------------------------------------------------------------------------
# Signals
# ---------------------------------------------------------------------------

## Emitted every time the game state changes.
signal state_changed(old_state: State, new_state: State)

## Emitted when player settings are modified.
signal settings_changed

## Emitted when a feature flag changes.
signal feature_changed(flag_name: String, enabled: bool)

# ---------------------------------------------------------------------------
# Current state
# ---------------------------------------------------------------------------

var current_state: State = State.BOOT

# ---------------------------------------------------------------------------
# Feature Flags
## Mechanics that the fangame creator can enable or disable.
## All disabled by default; the fangame project enables them via its config.
# ---------------------------------------------------------------------------

var features: Dictionary = {
	## Generation 1–3 core (always active, cannot be disabled)
	"core":              true,

	## Generation 6 — Mega Evolution
	"mega_evolution":    false,

	## Generation 6 — Primal Reversion (Groudon / Kyogre)
	"primal_reversion":  false,

	## Generation 7 — Z-Moves
	"z_moves":           false,

	## Generation 7 — Alolan regional forms
	"alolan_forms":      false,

	## Generation 8 — Dynamax / Gigantamax
	"dynamax":           false,

	## Generation 8 — Galarian regional forms
	"galarian_forms":    false,

	## Generation 9 — Terastallization
	"terastallization":  false,

	## Generation 9 — Paldean regional forms
	"paldean_forms":     false,

	## Shadow Pokémon system (Colosseum / XD style)
	"shadow_pokemon":    false,

	## Breeding / egg system
	"breeding":          true,

	## Pokémon Contests
	"contests":          false,

	## Pokéathlon / mini-games
	"mini_games":        false,

	## Phone system / rematches
	"phone_system":      true,

	## Berry farming
	"berry_farming":     true,

	## Procedural dungeon generation
	"dungeons":          false,

	## Real-time clock (day / night based on system time)
	"real_time":         true,

	## Pokémon follower in the overworld
	"followers":         false,

	## Battle Frontier / Battle Facilities
	"battle_frontier":   false,
}

# ---------------------------------------------------------------------------
# Player settings
# ---------------------------------------------------------------------------

var settings: Dictionary = {
	"text_speed":          TextSpeed.NORMAL,  ## Dialogue text speed
	"battle_animations":   true,              ## Show move animations
	"battle_style":        BattleStyle.SHIFT, ## Shift (warned) or Set (no warning)
	"sound_mono":          false,             ## Mono audio output
	"battle_scene":        true,              ## Show the battle scene
	"screen_shake":        true,              ## Screen shake in battle
	"show_enemy_hp_bar":   true,              ## Show enemy HP bar
	"show_exp_bar":        true,              ## Show EXP bar in battle
	"nickname_prompt":     true,              ## Ask for nickname when catching
	"send_to_box_prompt":  true,              ## Ask when the party is full
	"language":            "es",             ## Game language locale
}

# ---------------------------------------------------------------------------
# Global game metadata (written by the fangame creator)
# ---------------------------------------------------------------------------

var game_meta: Dictionary = {
	"title":       "My FanGame",
	"version":     "1.0.0",
	"author":      "",
	"start_map":   1,    ## ID of the starting map
	"start_x":     7,    ## Player's starting X position
	"start_y":     5,    ## Player's starting Y position
	"start_dir":   2,    ## Starting direction (2=down, 4=left, 6=right, 8=up)
	"start_money": 3000, ## Starting money
}

# ---------------------------------------------------------------------------
# Lifecycle
# ---------------------------------------------------------------------------

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS  # The manager never pauses

	## Load fangame configuration from the database once it is open.
	## RPGDatabase is the first autoload so it is already ready by the time
	## GameManager._ready() runs; the fallback handles edge cases.
	if RPGDatabase.is_ready():
		_load_game_settings()
	else:
		RPGDatabase.database_ready.connect(_load_game_settings, CONNECT_ONE_SHOT)

# ---------------------------------------------------------------------------
# State management
# ---------------------------------------------------------------------------

## Changes the global game state.
## Emits state_changed with the old and new states.
func change_state(new_state: State) -> void:
	if current_state == new_state:
		return
	var old: State = current_state
	current_state = new_state
	state_changed.emit(old, new_state)


## Returns true if the game is in one of the given states.
func is_state(states: Array) -> bool:
	return current_state in states


## Returns true if the player currently has control.
func is_player_in_control() -> bool:
	return current_state in [State.OVERWORLD, State.BATTLE]

# ---------------------------------------------------------------------------
# Feature flags
# ---------------------------------------------------------------------------

## Enables or disables a feature flag by name.
func set_feature(flag: String, enabled: bool) -> void:
	if not features.has(flag):
		push_warning("GameManager: Unknown feature flag: '%s'" % flag)
		return
	if flag == "core":
		push_error("GameManager: The 'core' flag cannot be disabled.")
		return
	features[flag] = enabled
	feature_changed.emit(flag, enabled)


## Returns true if a feature flag is active.
func has_feature(flag: String) -> bool:
	return features.get(flag, false)


## Loads a dictionary of features at once (from the fangame config).
func load_features(config: Dictionary) -> void:
	for key: String in config:
		set_feature(key, config[key])

# ---------------------------------------------------------------------------
# Settings
# ---------------------------------------------------------------------------

## Modifies a player setting.
func set_setting(key: String, value: Variant) -> void:
	if not settings.has(key):
		push_warning("GameManager: Unknown setting: '%s'" % key)
		return
	settings[key] = value
	settings_changed.emit()


## Returns the value of a setting, or default_val if it does not exist.
func get_setting(key: String, default_val: Variant = null) -> Variant:
	return settings.get(key, default_val)


## Loads settings from a dictionary (used by SaveSystem when loading a save file).
func load_settings(data: Dictionary) -> void:
	for key: String in data:
		if settings.has(key):
			settings[key] = data[key]
	settings_changed.emit()

# ---------------------------------------------------------------------------
# Database settings loader
# ---------------------------------------------------------------------------

## Reads the game_settings table and populates game_meta + feature flags.
## Called automatically once RPGDatabase is open.
func _load_game_settings() -> void:
	var rows: Array = RPGDatabase.query("SELECT key, value, type FROM game_settings")
	for row: Dictionary in rows:
		var key:   String = row.get("key",   "")
		var val:   String = row.get("value", "")
		var vtype: String = row.get("type",  "string")
		var typed: Variant = _coerce(val, vtype)

		## game_meta keys
		match key:
			"game_title":      game_meta["title"]       = typed
			"game_version":    game_meta["version"]     = typed
			"game_author":     game_meta["author"]      = typed
			"start_map_id":    game_meta["start_map"]   = typed
			"start_x":         game_meta["start_x"]     = typed
			"start_y":         game_meta["start_y"]     = typed
			"start_direction": game_meta["start_dir"]   = typed
			"start_money":     game_meta["start_money"] = typed

		## Feature flags (keys are prefixed "feat_")
		if key.begins_with("feat_"):
			var flag: String = key.substr(5)  ## strip "feat_"
			if features.has(flag):
				features[flag] = typed


## Converts a string value from game_settings to the declared GDScript type.
func _coerce(val: String, vtype: String) -> Variant:
	match vtype:
		"int":   return val.to_int()
		"float": return val.to_float()
		"bool":  return val.to_lower() == "true"
		_:       return val  ## "string" and "json" kept as-is
