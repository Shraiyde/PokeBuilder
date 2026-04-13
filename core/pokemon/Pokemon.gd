## Pokemon
## Runtime data of a single live Pokémon instance.
## Created by PokemonFactory; stored in PlayerData.party and pc_boxes.
##
## All stat calculations use the Generation III formula (same as PE v21.1).
##
## Usage:
##   var pk: Pokemon = PokemonFactory.create_wild("PIKACHU", 10)
##   var stats: Dictionary = pk.calc_stats()
##   if pk.is_fainted(): ...
class_name Pokemon
extends RefCounted

# ---------------------------------------------------------------------------
# Enumerations
# ---------------------------------------------------------------------------

## Permanent status conditions.
enum Status {
	NONE,       ## Healthy
	BURN,       ## Halves Atk; 1/8 max-HP damage per turn
	POISON,     ## 1/8 max-HP damage per turn
	BADPOISON,  ## Damage increases each turn (1/16 on turn 1)
	PARALYSIS,  ## Speed halved; 25 % chance of being fully paralysed each turn
	FREEZE,     ## Cannot act; thawed by Fire-type moves or full-thaw items
	SLEEP,      ## Cannot act for 1–3 turns
}

# ---------------------------------------------------------------------------
# Identity
# ---------------------------------------------------------------------------

var species_id:    String = ""    ## e.g. "BULBASAUR"
var form_index:    int    = 0     ## 0 = base form; positive = alternate form
var nickname:      String = ""    ## "" = display species name
var gender:        int    = 0     ## 0 = male · 1 = female · 2 = genderless
var is_shiny:      bool   = false

# ---------------------------------------------------------------------------
# Growth
# ---------------------------------------------------------------------------

var level: int = 5
var exp:   int = 0   ## Total accumulated experience points

# ---------------------------------------------------------------------------
# Nature / Ability
# ---------------------------------------------------------------------------

var nature_id:     String = "HARDY"
## 0 = first ability · 1 = second ability · 2 = hidden ability
var ability_index: int    = 0

# ---------------------------------------------------------------------------
# HP
# ---------------------------------------------------------------------------

## Current hit points. Set to calc_stats()["hp"] when the Pokémon is first created.
var current_hp: int = 0

# ---------------------------------------------------------------------------
# Individual Values (0–31)
# ---------------------------------------------------------------------------

var iv_hp:  int = 0
var iv_atk: int = 0
var iv_def: int = 0
var iv_spa: int = 0
var iv_spd: int = 0
var iv_spe: int = 0

# ---------------------------------------------------------------------------
# Effort Values (0–252 per stat; 510 max total)
# ---------------------------------------------------------------------------

var ev_hp:  int = 0
var ev_atk: int = 0
var ev_def: int = 0
var ev_spa: int = 0
var ev_spd: int = 0
var ev_spe: int = 0

# ---------------------------------------------------------------------------
# Moves (up to 4 slots)
## Each entry: { "move_id": String, "current_pp": int, "max_pp": int, "pp_ups": int }
# ---------------------------------------------------------------------------

var moves: Array = []

# ---------------------------------------------------------------------------
# Status condition
# ---------------------------------------------------------------------------

var status:       Status = Status.NONE
var sleep_turns:  int    = 0   ## Remaining sleep turns
var poison_turns: int    = 0   ## Bad-poison counter (increments each turn)

# ---------------------------------------------------------------------------
# Held item / Friendship
# ---------------------------------------------------------------------------

var held_item_id: String = ""   ## "" = no held item
var happiness:    int    = 70   ## Friendship value (0–255)

# ---------------------------------------------------------------------------
# Original trainer
# ---------------------------------------------------------------------------

var ot_name:      String = ""
var ot_id:        int    = 0
var ot_secret_id: int    = 0
var ot_gender:    int    = 0   ## 0 = male · 1 = female

# ---------------------------------------------------------------------------
# Pokéball
# ---------------------------------------------------------------------------

var pokeball_id: String = "POKEBALL"

# ---------------------------------------------------------------------------
# Met data
# ---------------------------------------------------------------------------

var met_map_id: int    = 0
var met_level:  int    = 5
var met_date:   String = ""    ## ISO-8601 "YYYY-MM-DD", or "" if unknown
var is_egg:     bool   = false
var egg_steps:  int    = 0     ## Steps remaining to hatch; 0 = not an egg

# ---------------------------------------------------------------------------
# Ribbons
# ---------------------------------------------------------------------------

var ribbons: Array = []   ## Array[String] of ribbon IDs earned

# ---------------------------------------------------------------------------
# Pokerus
# ---------------------------------------------------------------------------

## 0 = never had it · 1–4 = active (days remaining) · -1 = cured (inactive carrier)
var pokerus_days: int = 0

# ===========================================================================
# STAT CALCULATION
# ===========================================================================

## Computes current stats using the Gen-III formula.
## Returns a Dictionary with keys: hp, atk, def, spa, spd, spe.
func calc_stats() -> Dictionary:
	var base: Dictionary = _get_base_stats()
	var nat:  Dictionary = GameData.nature(nature_id)
	var stat_up:   String = nat.get("stat_up",   "") if nat.get("stat_up")   != null else ""
	var stat_down: String = nat.get("stat_down", "") if nat.get("stat_down") != null else ""

	var stats: Dictionary = {}

	# HP formula — differs from all other stats
	var b_hp: int = base.get("stat_hp", 45)
	stats["hp"] = (2 * b_hp + iv_hp + ev_hp / 4) * level / 100 + level + 10

	# The five combat stats
	var pairs: Array = [
		["atk", "stat_atk", iv_atk, ev_atk],
		["def", "stat_def", iv_def, ev_def],
		["spa", "stat_spa", iv_spa, ev_spa],
		["spd", "stat_spd", iv_spd, ev_spd],
		["spe", "stat_spe", iv_spe, ev_spe],
	]
	for pair: Array in pairs:
		var key:  String = pair[0]
		var bkey: String = pair[1]
		var iv:   int    = pair[2]
		var ev:   int    = pair[3]
		var b:    int    = base.get(bkey, 45)
		var raw:  int    = (2 * b + iv + ev / 4) * level / 100 + 5
		var mod:  float  = 1.0
		if   stat_up   == key: mod = 1.1
		elif stat_down == key: mod = 0.9
		stats[key] = maxi(1, int(float(raw) * mod))

	return stats


## Returns the maximum HP (computed via calc_stats).
func max_hp() -> int:
	return calc_stats()["hp"]


## Merges species base stats with any form overrides (NULL form fields inherit from base).
func _get_base_stats() -> Dictionary:
	var sp: Dictionary = GameData.species(species_id)
	if form_index == 0:
		return sp
	var frm:    Dictionary = GameData.form(species_id, form_index)
	var merged: Dictionary = sp.duplicate()
	for stat_key: String in ["stat_hp", "stat_atk", "stat_def", "stat_spa", "stat_spd", "stat_spe"]:
		var frm_val: Variant = frm.get(stat_key)
		if frm_val != null:
			merged[stat_key] = frm_val
	return merged

# ===========================================================================
# TYPE & ABILITY
# ===========================================================================

## Returns effective type IDs (1 or 2 elements), applying form overrides.
func type_ids() -> Array:
	var sp: Dictionary = GameData.species(species_id)
	var t1: String     = sp.get("type1_id", "NORMAL")
	var t2: String     = sp.get("type2_id", "") if sp.get("type2_id") != null else ""

	if form_index > 0:
		var frm: Dictionary = GameData.form(species_id, form_index)
		var ft1: Variant    = frm.get("type1_id")
		var ft2: Variant    = frm.get("type2_id")
		if ft1 != null: t1 = ft1
		if ft2 != null: t2 = ft2

	var result: Array = [t1]
	if not t2.is_empty():
		result.append(t2)
	return result


## Returns the active ability ID, resolving ability_index against the species data.
func current_ability_id() -> String:
	var sp: Dictionary = GameData.species(species_id)
	match ability_index:
		0: return sp.get("ability1_id",      "") if sp.get("ability1_id")     != null else ""
		1: return sp.get("ability2_id",      "") if sp.get("ability2_id")     != null else \
			      sp.get("ability1_id",      "")
		2: return sp.get("hidden_ability_id","") if sp.get("hidden_ability_id") != null else \
			      sp.get("ability1_id",      "")
		_: return ""


## Returns the display name (nickname if set, otherwise species name).
func full_name() -> String:
	if nickname.is_empty():
		return GameData.species(species_id).get("name", species_id)
	return nickname

# ===========================================================================
# BATTLE STATE HELPERS
# ===========================================================================

func is_fainted() -> bool:
	return current_hp <= 0


func is_alive() -> bool:
	return current_hp > 0


func has_status() -> bool:
	return status != Status.NONE


## Applies damage capped at current HP. Returns the actual damage dealt.
func take_damage(amount: int) -> int:
	var actual: int = mini(amount, current_hp)
	current_hp -= actual
	return actual


## Restores HP up to the maximum. Returns the actual HP restored.
func restore_hp(amount: int) -> int:
	var mhp:    int = max_hp()
	var actual: int = mini(amount, mhp - current_hp)
	current_hp += actual
	return actual


## Full heal: restores HP, clears status, and refills all move PP.
func full_heal() -> void:
	current_hp   = max_hp()
	status       = Status.NONE
	sleep_turns  = 0
	poison_turns = 0
	for slot: Dictionary in moves:
		slot["current_pp"] = slot.get("max_pp", 0)

# ===========================================================================
# MOVE MANAGEMENT
# ===========================================================================

## Returns true if this Pokémon knows the given move.
func has_move(move_id: String) -> bool:
	return moves.any(func(m: Dictionary) -> bool: return m.get("move_id") == move_id)


## Sets the move in slot `position` (0–3).
## position == -1 appends to the first free slot.
## Returns true on success.
func set_move(position: int, move_id: String) -> bool:
	var move_data: Dictionary = GameData.move(move_id)
	if move_data.is_empty():
		push_warning("Pokemon.set_move: unknown move '%s'" % move_id)
		return false
	var pp:   int        = move_data.get("total_pp", 5)
	var slot: Dictionary = {"move_id": move_id, "current_pp": pp, "max_pp": pp, "pp_ups": 0}

	if position == -1:
		if moves.size() < 4:
			moves.append(slot)
			return true
		return false  # No free slot

	while moves.size() <= position:
		moves.append({})
	moves[position] = slot
	return true


## Removes the move at `position` and shifts remaining moves left.
func remove_move(position: int) -> void:
	if position >= 0 and position < moves.size():
		moves.remove_at(position)


## Restores PP for all moves to their maximum (e.g., after using an Elixir).
func restore_all_pp() -> void:
	for slot: Dictionary in moves:
		slot["current_pp"] = slot.get("max_pp", 0)

# ===========================================================================
# EV MANAGEMENT
# ===========================================================================

## Returns the total EV sum (must not exceed 510).
func total_evs() -> int:
	return ev_hp + ev_atk + ev_def + ev_spa + ev_spd + ev_spe


## Adds EVs to a stat, respecting the per-stat cap (252) and total cap (510).
## stat: "hp" | "atk" | "def" | "spa" | "spd" | "spe"
## Returns the actual amount added.
func add_ev(stat: String, amount: int) -> int:
	var room_total: int = 510 - total_evs()
	if room_total <= 0:
		return 0
	var to_add: int = mini(amount, room_total)
	match stat:
		"hp":
			var cap: int = mini(to_add, 252 - ev_hp)
			ev_hp += cap
			return cap
		"atk":
			var cap: int = mini(to_add, 252 - ev_atk)
			ev_atk += cap
			return cap
		"def":
			var cap: int = mini(to_add, 252 - ev_def)
			ev_def += cap
			return cap
		"spa":
			var cap: int = mini(to_add, 252 - ev_spa)
			ev_spa += cap
			return cap
		"spd":
			var cap: int = mini(to_add, 252 - ev_spd)
			ev_spd += cap
			return cap
		"spe":
			var cap: int = mini(to_add, 252 - ev_spe)
			ev_spe += cap
			return cap
	return 0

# ===========================================================================
# SERIALIZATION
# ===========================================================================

## Returns all Pokémon data as a serializable Dictionary (for JSON save files).
func serialize() -> Dictionary:
	return {
		"species_id":    species_id,
		"form_index":    form_index,
		"nickname":      nickname,
		"gender":        gender,
		"is_shiny":      is_shiny,
		"level":         level,
		"exp":           exp,
		"nature_id":     nature_id,
		"ability_index": ability_index,
		"current_hp":    current_hp,
		"ivs": [iv_hp, iv_atk, iv_def, iv_spa, iv_spd, iv_spe],
		"evs": [ev_hp, ev_atk, ev_def, ev_spa, ev_spd, ev_spe],
		"moves":         _serialize_moves(),
		"status":        int(status),
		"sleep_turns":   sleep_turns,
		"poison_turns":  poison_turns,
		"held_item_id":  held_item_id,
		"happiness":     happiness,
		"ot_name":       ot_name,
		"ot_id":         ot_id,
		"ot_secret_id":  ot_secret_id,
		"ot_gender":     ot_gender,
		"pokeball_id":   pokeball_id,
		"met_map_id":    met_map_id,
		"met_level":     met_level,
		"met_date":      met_date,
		"is_egg":        is_egg,
		"egg_steps":     egg_steps,
		"ribbons":       ribbons.duplicate(),
		"pokerus_days":  pokerus_days,
	}


func _serialize_moves() -> Array:
	var result: Array = []
	for slot: Dictionary in moves:
		result.append(slot.duplicate())
	return result


## Reconstructs a Pokemon from a save-file Dictionary.
## Use this instead of Pokemon.new() when loading a saved game.
static func restore(data: Dictionary) -> Pokemon:
	var pk: Pokemon    = Pokemon.new()
	pk.species_id      = data.get("species_id",    "")
	pk.form_index      = data.get("form_index",    0)
	pk.nickname        = data.get("nickname",      "")
	pk.gender          = data.get("gender",        0)
	pk.is_shiny        = data.get("is_shiny",      false)
	pk.level           = data.get("level",         5)
	pk.exp             = data.get("exp",           0)
	pk.nature_id       = data.get("nature_id",     "HARDY")
	pk.ability_index   = data.get("ability_index", 0)
	pk.current_hp      = data.get("current_hp",    0)

	var ivs: Array = data.get("ivs", [0, 0, 0, 0, 0, 0])
	pk.iv_hp  = ivs[0] if ivs.size() > 0 else 0
	pk.iv_atk = ivs[1] if ivs.size() > 1 else 0
	pk.iv_def = ivs[2] if ivs.size() > 2 else 0
	pk.iv_spa = ivs[3] if ivs.size() > 3 else 0
	pk.iv_spd = ivs[4] if ivs.size() > 4 else 0
	pk.iv_spe = ivs[5] if ivs.size() > 5 else 0

	var evs: Array = data.get("evs", [0, 0, 0, 0, 0, 0])
	pk.ev_hp  = evs[0] if evs.size() > 0 else 0
	pk.ev_atk = evs[1] if evs.size() > 1 else 0
	pk.ev_def = evs[2] if evs.size() > 2 else 0
	pk.ev_spa = evs[3] if evs.size() > 3 else 0
	pk.ev_spd = evs[4] if evs.size() > 4 else 0
	pk.ev_spe = evs[5] if evs.size() > 5 else 0

	pk.moves        = data.get("moves",        []).duplicate(true)
	pk.status       = data.get("status",       0)
	pk.sleep_turns  = data.get("sleep_turns",  0)
	pk.poison_turns = data.get("poison_turns", 0)
	pk.held_item_id = data.get("held_item_id", "")
	pk.happiness    = data.get("happiness",    70)
	pk.ot_name      = data.get("ot_name",      "")
	pk.ot_id        = data.get("ot_id",        0)
	pk.ot_secret_id = data.get("ot_secret_id", 0)
	pk.ot_gender    = data.get("ot_gender",    0)
	pk.pokeball_id  = data.get("pokeball_id",  "POKEBALL")
	pk.met_map_id   = data.get("met_map_id",   0)
	pk.met_level    = data.get("met_level",    5)
	pk.met_date     = data.get("met_date",     "")
	pk.is_egg       = data.get("is_egg",       false)
	pk.egg_steps    = data.get("egg_steps",    0)
	pk.ribbons      = data.get("ribbons",      []).duplicate()
	pk.pokerus_days = data.get("pokerus_days", 0)
	return pk
