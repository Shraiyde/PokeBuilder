## BattlePokemon
## Volatile battle-state wrapper around a persistent Pokemon instance.
## Holds all data that exists only for the duration of a battle:
## stat stages, confusion, type/ability overrides, substitute, etc.
##
## The underlying Pokemon is modified only for permanent changes
## (damage, PP loss, status, happiness). Everything else lives here.
##
## Usage:
##   var bp: BattlePokemon = BattlePokemon.wrap(player_party[0])
##   bp.apply_stat_stage("atk", 2)
##   var stats: Dictionary = bp.calc_effective_stats()
##   bp.reset_volatile()
class_name BattlePokemon
extends RefCounted

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

const MIN_STAGE: int = -6
const MAX_STAGE: int =  6

## Stat stage multiplier table (index 0 = stage −6 … index 12 = stage +6).
## Numerators — denominator is always 2.
const STAGE_NUMERATORS: Array[int] = [2, 2, 2, 2, 3, 4, 2, 3, 4, 5, 6, 7, 8]
const STAGE_DENOMS:     Array[int] = [8, 7, 6, 5, 4, 3, 2, 2, 2, 2, 2, 2, 2]

## Accuracy / evasion stage multiplier numerators (same denominator = 3).
const ACC_STAGE_NUMS:  Array[int] = [3, 3, 3, 3, 3, 3, 3, 4, 5, 6, 7, 8, 9]
const ACC_STAGE_DENOMS: Array[int] = [9, 8, 7, 6, 5, 4, 3, 3, 3, 3, 3, 3, 3]

# ---------------------------------------------------------------------------
# Reference to the underlying Pokemon
# ---------------------------------------------------------------------------

## The persistent Pokémon this wrapper represents.
var pokemon: Pokemon = null

# ---------------------------------------------------------------------------
# Stat stages (−6 to +6)
# ---------------------------------------------------------------------------

var stage_atk: int = 0
var stage_def: int = 0
var stage_spa: int = 0
var stage_spd: int = 0
var stage_spe: int = 0
var stage_acc: int = 0  ## Accuracy stage
var stage_eva: int = 0  ## Evasion stage
var stage_crit: int = 0 ## Critical-hit stage (0–3)

# ---------------------------------------------------------------------------
# Volatile status flags
# ---------------------------------------------------------------------------

## Confusion turns remaining (0 = not confused).
var confusion_turns: int = 0

## True while the Pokémon is in a two-turn move charge state (Fly, Dig, etc.).
var is_charging: bool = false

## Name of the charging move (used to render "used Fly!" etc.).
var charging_move_id: String = ""

## True while flinched (cleared at end of turn).
var is_flinched: bool = false

## True while the Pokémon is protected by Protect / Detect this turn.
var is_protected: bool = false

## Seeded by Leech Seed (source position index, -1 = not seeded).
var leech_seed_source: int = -1

## Substitute HP remaining (0 = no substitute).
var substitute_hp: int = 0

## Encore — locked into repeating this move for encore_turns more turns.
var encore_move_id: String = ""
var encore_turns: int = 0

## Disable — the specified move slot cannot be used.
var disabled_move_id: String = ""
var disable_turns: int = 0

## Taunt turns remaining.
var taunt_turns: int = 0

## Torment — cannot use the same move twice in a row.
var is_tormented: bool = false

## Last move successfully used (for Encore, Torment, etc.).
var last_move_used: String = ""

## True if this Pokémon has acted this turn (for priority resolution).
var has_acted: bool = false

## Consecutive uses of the same move (for Rollout, Fury Cutter, etc.).
var consecutive_move_uses: int = 0

# ---------------------------------------------------------------------------
# Type / ability overrides
# ---------------------------------------------------------------------------

## Overrides the Pokémon's type(s) for the battle (e.g. via Soak).
## Empty array = use pokemon.type_ids().
var type_override: Array[String] = []

## Overrides the Pokémon's effective ability (e.g. via Simple Beam, Entrainment).
## "" = use pokemon.current_ability_id().
var ability_override: String = ""

# ---------------------------------------------------------------------------
# Misc battle state
# ---------------------------------------------------------------------------

## Effective speed used for turn-order calculations (cached each turn).
var effective_speed: int = 0

## True if the Pokémon has already used its Mega Evolution / Z-Move this battle.
var has_mega_evolved: bool = false
var has_used_z_move: bool  = false

# ---------------------------------------------------------------------------
# Factory
# ---------------------------------------------------------------------------

## Creates a BattlePokemon from a persistent Pokemon instance.
static func wrap(pk: Pokemon) -> BattlePokemon:
	var bp: BattlePokemon = BattlePokemon.new()
	bp.pokemon           = pk
	return bp

# ---------------------------------------------------------------------------
# Stat stage management
# ---------------------------------------------------------------------------

## Applies a stat stage change and returns the actual change applied
## (clamped to the available range, so it may be 0 if already at cap).
func apply_stat_stage(stat: String, delta: int) -> int:
	var old: int = get_stage(stat)
	var new_val: int = clampi(old + delta, MIN_STAGE, MAX_STAGE)
	_set_stage(stat, new_val)
	return new_val - old


## Returns the current stage for the given stat key.
func get_stage(stat: String) -> int:
	match stat:
		"atk":  return stage_atk
		"def":  return stage_def
		"spa":  return stage_spa
		"spd":  return stage_spd
		"spe":  return stage_spe
		"acc":  return stage_acc
		"eva":  return stage_eva
		"crit": return stage_crit
	push_warning("BattlePokemon.get_stage: unknown stat '%s'" % stat)
	return 0


## Resets all volatile state without touching the persistent Pokemon.
func reset_volatile() -> void:
	stage_atk = 0; stage_def = 0; stage_spa = 0
	stage_spd = 0; stage_spe = 0; stage_acc = 0
	stage_eva = 0; stage_crit = 0

	confusion_turns     = 0
	is_charging         = false
	charging_move_id    = ""
	is_flinched         = false
	is_protected        = false
	leech_seed_source   = -1
	substitute_hp       = 0
	encore_move_id      = ""
	encore_turns        = 0
	disabled_move_id    = ""
	disable_turns       = 0
	taunt_turns         = 0
	is_tormented        = false
	last_move_used      = ""
	has_acted           = false
	consecutive_move_uses = 0
	type_override.clear()
	ability_override    = ""
	effective_speed     = 0
	has_mega_evolved    = false
	has_used_z_move     = false

# ---------------------------------------------------------------------------
# Effective stats with stages applied
# ---------------------------------------------------------------------------

## Returns a stat Dictionary with stage modifiers applied.
## Does NOT apply burn/paralysis or ability modifiers — those belong in
## the damage formula and speed-sorting code respectively.
func calc_effective_stats() -> Dictionary:
	var base: Dictionary = pokemon.calc_stats()
	return {
		"hp":  base["hp"],
		"atk": _apply_stage(base["atk"], stage_atk),
		"def": _apply_stage(base["def"], stage_def),
		"spa": _apply_stage(base["spa"], stage_spa),
		"spd": _apply_stage(base["spd"], stage_spd),
		"spe": _apply_stage(base["spe"], stage_spe),
	}


## Returns the stage-modified accuracy multiplier (as a float).
func accuracy_multiplier() -> float:
	var idx: int = stage_acc + 6
	return float(ACC_STAGE_NUMS[idx]) / float(ACC_STAGE_DENOMS[idx])


## Returns the stage-modified evasion multiplier (as a float).
func evasion_multiplier() -> float:
	var idx: int = stage_eva + 6
	return float(ACC_STAGE_NUMS[idx]) / float(ACC_STAGE_DENOMS[idx])

# ---------------------------------------------------------------------------
# Type / ability resolution
# ---------------------------------------------------------------------------

## Returns the effective type array (override → pokemon).
func effective_types() -> Array[String]:
	if not type_override.is_empty():
		return type_override
	var raw: Array = pokemon.type_ids()
	var typed: Array[String] = []
	for t: String in raw:
		typed.append(t)
	return typed


## Returns the effective ability ID (override → pokemon).
func effective_ability() -> String:
	if ability_override != "":
		return ability_override
	return pokemon.current_ability_id()

# ---------------------------------------------------------------------------
# Convenience pass-throughs
# ---------------------------------------------------------------------------

func is_fainted() -> bool:
	return pokemon.is_fainted()

func is_alive() -> bool:
	return pokemon.is_alive()

func full_name() -> String:
	return pokemon.full_name()

# ---------------------------------------------------------------------------
# Private helpers
# ---------------------------------------------------------------------------

func _set_stage(stat: String, value: int) -> void:
	match stat:
		"atk":  stage_atk  = value
		"def":  stage_def  = value
		"spa":  stage_spa  = value
		"spd":  stage_spd  = value
		"spe":  stage_spe  = value
		"acc":  stage_acc  = value
		"eva":  stage_eva  = value
		"crit": stage_crit = value


func _apply_stage(base_val: int, stage: int) -> int:
	var idx: int = stage + 6
	return int(float(base_val) * float(STAGE_NUMERATORS[idx]) / float(STAGE_DENOMS[idx]))
