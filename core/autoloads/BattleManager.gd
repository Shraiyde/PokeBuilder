## BattleManager
## Singleton that acts as the entry and exit point of the battle system.
## Receives battle configuration (participants, rules, music, etc.),
## loads the battle scene, and returns the result to the calling context.
##
## Usage from the overworld or game events:
##
##   # Wild battle
##   var result = await BattleManager.start_wild_battle({
##       "species_id": "PIDGEY",
##       "level": 12,
##       "shiny": false,
##   })
##
##   # Trainer battle
##   var result = await BattleManager.start_trainer_battle("YOUNGSTER", "Ben", 0)
##
##   # The result is a Dictionary with at minimum {"outcome": BattleManager.Outcome}
extends Node

# ---------------------------------------------------------------------------
# Enumerations
# ---------------------------------------------------------------------------

## Battle outcome.
enum Outcome {
	WIN,    ## The player won
	LOSE,   ## The player lost (all Pokémon fainted)
	FLEE,   ## The player fled
	CAUGHT, ## A Pokémon was caught (wild battles only)
	DRAW,   ## Draw (rare; possible with Destiny Bond)
	ABORT,  ## Battle aborted by a game event (does not count as a loss)
}

## Battle type.
enum BattleType {
	WILD_SINGLE,    ## 1v1 against a wild Pokémon
	WILD_DOUBLE,    ## 2v2 against two wild Pokémon
	TRAINER_SINGLE, ## 1v1 against a trainer
	TRAINER_DOUBLE, ## 2v2 against a trainer (double battle)
	TRAINER_MULTI,  ## 2+2 vs 2+2 (multi battle with an ally)
	SAFARI,         ## Safari Zone (special mechanics)
	BUG_CONTEST,    ## Bug-Catching Contest
	FRONTIER,       ## Battle Facility (no permanent Pokémon loss on defeat)
}

# ---------------------------------------------------------------------------
# Signals
# ---------------------------------------------------------------------------

## Emitted when a battle is about to start.
signal battle_starting(config: Dictionary)

## Emitted when a battle ends.
signal battle_ended(result: Dictionary)

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

const BATTLE_SCENE_PATH := "res://scenes/battle/battle_scene.tscn"

# ---------------------------------------------------------------------------
# Internal state
# ---------------------------------------------------------------------------

var _current_config: Dictionary = {}  ## Configuration of the active battle
var _battle_active:  bool       = false

# ---------------------------------------------------------------------------
# Public API — Start battles
# ---------------------------------------------------------------------------

## Starts a wild Pokémon battle.
##
## pokemon_data may contain:
##   species_id (String), level (int), shiny (bool), form_index (int),
##   moves (Array), ability_id (String), item_id (String),
##   iv_override (Array[int]), nature (String)
##
## Returns a result Dictionary (see _make_result).
func start_wild_battle(pokemon_data: Dictionary, options: Dictionary = {}) -> Dictionary:
	var config: Dictionary = {
		"type":         BattleType.WILD_SINGLE,
		"wild_pokemon": [pokemon_data],
		"can_flee":     options.get("can_flee",    true),
		"can_catch":    options.get("can_catch",   true),
		"bgm":          options.get("bgm",         ""),  # empty = use the map's default
		"transition":   options.get("transition",  ""),  # empty = use the map's default
		"weather":      options.get("weather",     ""),
		"environment":  options.get("environment", ""),
		"is_fishing":   options.get("is_fishing",  false),
		"is_surfing":   options.get("is_surfing",  false),
	}
	return await _run_battle(config)


## Starts a double wild battle against two Pokémon.
func start_wild_double_battle(pokemon_data_a: Dictionary, pokemon_data_b: Dictionary, options: Dictionary = {}) -> Dictionary:
	var config: Dictionary = {
		"type":         BattleType.WILD_DOUBLE,
		"wild_pokemon": [pokemon_data_a, pokemon_data_b],
		"can_flee":     options.get("can_flee",  true),
		"can_catch":    options.get("can_catch", true),
		"bgm":          options.get("bgm",       ""),
	}
	return await _run_battle(config)


## Starts a battle against a trainer defined in the database.
##
## trainer_type_id: trainer class ID (e.g. "YOUNGSTER")
## trainer_name:    trainer's name (e.g. "Ben")
## version_index:   trainer version index for rematches (default 0)
func start_trainer_battle(trainer_type_id: String, trainer_name: String, version_index := 0, options: Dictionary = {}) -> Dictionary:
	var trainer: Dictionary = RPGDatabase.query_one(
		"SELECT * FROM trainers WHERE type_id = ? AND name = ? AND version_index = ?",
		[trainer_type_id, trainer_name, version_index]
	)
	if trainer.is_empty():
		push_error("BattleManager: Trainer not found: [%s, %s, %d]" % [trainer_type_id, trainer_name, version_index])
		return _make_result(Outcome.ABORT)

	var trainer_type: Dictionary = GameData.trainer_type(trainer_type_id)
	var is_gym_leader: bool = trainer_type.get("flags", "").contains("GymLeader")
	var is_e4:         bool = trainer_type.get("flags", "").contains("EliteFour")

	var config: Dictionary = {
		"type":          BattleType.TRAINER_SINGLE,
		"trainer":       trainer,
		"trainer_type":  trainer_type,
		"can_flee":      false,
		"can_catch":     false,
		"is_gym_leader": is_gym_leader,
		"is_elite_four": is_e4,
		"bgm":           options.get("bgm",           _pick_trainer_bgm(trainer_type_id)),
		"transition":    options.get("transition",     _pick_trainer_transition(trainer_type_id)),
		"double_battle": options.get("double_battle",  false),
	}
	if config["double_battle"]:
		config["type"] = BattleType.TRAINER_DOUBLE

	return await _run_battle(config)


## Starts a Safari Zone battle.
func start_safari_battle(pokemon_data: Dictionary) -> Dictionary:
	var config: Dictionary = {
		"type":         BattleType.SAFARI,
		"wild_pokemon": [pokemon_data],
		"can_flee":     true,
		"can_catch":    true,
		"safari_balls": 30,
	}
	return await _run_battle(config)


## Starts a Battle Facility battle (no permanent Pokémon loss on defeat).
func start_frontier_battle(opponent_config: Dictionary, options: Dictionary = {}) -> Dictionary:
	var config: Dictionary = {
		"type":      BattleType.FRONTIER,
		"opponent":  opponent_config,
		"can_flee":  false,
		"can_catch": false,
		"bgm":       options.get("bgm", "Battle Frontier"),
	}
	return await _run_battle(config)

# ---------------------------------------------------------------------------
# Internal engine
# ---------------------------------------------------------------------------

func _run_battle(config: Dictionary) -> Dictionary:
	if _battle_active:
		push_error("BattleManager: Attempted to start a battle while one is already active.")
		return _make_result(Outcome.ABORT)

	_battle_active  = true
	_current_config = config

	# Update game state
	GameManager.change_state(GameManager.State.BATTLE)
	battle_starting.emit(config)

	# Handle battle BGM
	var bgm: String = config.get("bgm", "")
	if bgm != "":
		AudioManager.push_bgm(bgm, 0.0, 0.2, 0.3)

	# Load the battle scene and pass the configuration
	SceneManager.push(BATTLE_SCENE_PATH, SceneManager.Transition.FADE, 0.3)

	# Wait for the battle scene to emit its result via finish_battle()
	var result: Dictionary = await battle_ended

	return result


## Called by the battle scene when the battle is over.
## result must contain at least {"outcome": BattleManager.Outcome}
func finish_battle(result: Dictionary) -> void:
	if not _battle_active:
		push_warning("BattleManager: finish_battle() called with no active battle.")
		return

	_battle_active = false

	# Apply outcome consequences
	_apply_outcome(result)

	# Restore the previous BGM
	if _current_config.get("bgm", "") != "":
		AudioManager.pop_bgm(0.2, 0.4)

	# Return to the previous scene (overworld / frontier)
	SceneManager.pop(SceneManager.Transition.FADE, 0.3)

	# Restore game state
	GameManager.change_state(GameManager.State.OVERWORLD)

	_current_config = {}
	battle_ended.emit(result)


func _apply_outcome(result: Dictionary) -> void:
	var outcome: int = result.get("outcome", Outcome.ABORT)

	match outcome:
		Outcome.LOSE:
			# Partially heal the party and teleport to the last Pokémon Centre
			_handle_blackout()
		Outcome.CAUGHT:
			# The caught Pokémon arrives through result["caught_pokemon"]
			if result.has("caught_pokemon"):
				var caught: Pokemon = result["caught_pokemon"]
				PlayerData.add_to_party(caught)
				PlayerData.register_caught(caught.species_id)


func _handle_blackout() -> void:
	# Give each fainted Pokémon 1 HP so the healing animation can play
	for pokemon: Pokemon in PlayerData.party:
		if pokemon.current_hp <= 0:
			pokemon.current_hp = 1
	# TODO: teleport to the last registered healing spot

# ---------------------------------------------------------------------------
# BGM / transition helpers based on trainer type
# ---------------------------------------------------------------------------

func _pick_trainer_bgm(trainer_type_id: String) -> String:
	var flags: String = GameData.trainer_type(trainer_type_id).get("flags", "")
	if flags.contains("Champion"):  return "Battle Champion"
	if flags.contains("EliteFour"): return "Battle Elite"
	if flags.contains("GymLeader"): return "Battle Gym Leader"
	return "Battle trainer"


func _pick_trainer_transition(trainer_type_id: String) -> String:
	# VS transition graphics are looked up in assets/graphics/transitions/
	return "vsTrainer_" + trainer_type_id

# ---------------------------------------------------------------------------
# State queries
# ---------------------------------------------------------------------------

## Returns true if a battle is currently active.
func is_battle_active() -> bool:
	return _battle_active


## Returns the configuration of the current battle (empty if none).
func current_config() -> Dictionary:
	return _current_config

# ---------------------------------------------------------------------------
# Result helpers
# ---------------------------------------------------------------------------

func _make_result(outcome: Outcome, extra: Dictionary = {}) -> Dictionary:
	var result: Dictionary = {"outcome": outcome}
	result.merge(extra)
	return result
