## PokemonFactory
## Creates Pokemon instances from various sources.
##   create_wild()              — Random wild Pokémon
##   create_from_trainer_slot() — Pokémon from a trainer's team (DB row)
##   create_egg()               — Egg for the breeding system
##   restore()                  — Reconstruction from a save-file Dictionary
##
## All methods are static; this class does not need to be instantiated.
##
## Usage:
##   var pk: Pokemon = PokemonFactory.create_wild("RATTATA", 8)
##   var pk: Pokemon = PokemonFactory.restore(save_dict)
class_name PokemonFactory
extends RefCounted

# ---------------------------------------------------------------------------
# Wild Pokémon
# ---------------------------------------------------------------------------

## Creates a wild Pokémon with random stats and nature.
## rng: pass an existing RandomNumberGenerator for reproducible results;
##      null creates a new one seeded from the system clock.
static func create_wild(
		species_id:  String,
		level:       int,
		form_index:  int                    = 0,
		rng:         RandomNumberGenerator  = null) -> Pokemon:

	if rng == null:
		rng = RandomNumberGenerator.new()

	var sp: Dictionary = GameData.species(species_id)
	if sp.is_empty():
		push_error("PokemonFactory.create_wild: unknown species '%s'" % species_id)
		return null

	var pk: Pokemon  = Pokemon.new()
	pk.species_id    = species_id
	pk.form_index    = form_index
	pk.level         = clampi(level, 1, 100)
	pk.nature_id     = _random_nature_id(rng)
	pk.ability_index = _random_ability_index(sp, rng)
	pk.gender        = _roll_gender(sp.get("gender_ratio", "Female50Percent"), rng)
	pk.is_shiny      = _roll_shiny(rng)

	# Random IVs (0–31)
	pk.iv_hp  = rng.randi_range(0, 31)
	pk.iv_atk = rng.randi_range(0, 31)
	pk.iv_def = rng.randi_range(0, 31)
	pk.iv_spa = rng.randi_range(0, 31)
	pk.iv_spd = rng.randi_range(0, 31)
	pk.iv_spe = rng.randi_range(0, 31)

	pk.happiness = sp.get("happiness", 70)

	# Build the level-up moveset
	_assign_level_moves(pk, sp, level)

	# Original trainer data (from the current player)
	pk.ot_name      = PlayerData.trainer_name
	pk.ot_id        = PlayerData.trainer_id
	pk.ot_secret_id = PlayerData.secret_id
	pk.ot_gender    = PlayerData.trainer_gender
	pk.met_map_id   = PlayerData.map_id
	pk.met_level    = pk.level
	pk.met_date     = Time.get_date_string_from_system()

	# Set HP to maximum
	pk.current_hp = pk.calc_stats()["hp"]
	return pk

# ---------------------------------------------------------------------------
# Trainer Pokémon (from DB row)
# ---------------------------------------------------------------------------

## Creates a Pokémon from a trainer_pokemon Dictionary (DB query result).
## Expected keys: species_id, form_index, level, gender, shiny, ability_index,
##   held_item_id, iv_hp…iv_spe, nature, nickname
static func create_from_trainer_slot(tp: Dictionary) -> Pokemon:
	var sp: Dictionary = GameData.species(tp.get("species_id", ""))
	if sp.is_empty():
		push_error("PokemonFactory.create_from_trainer_slot: unknown species")
		return null

	var rng: RandomNumberGenerator = RandomNumberGenerator.new()
	var pk:  Pokemon  = Pokemon.new()
	pk.species_id     = tp.get("species_id",   "")
	pk.form_index     = tp.get("form_index",   0)
	pk.level          = clampi(tp.get("level", 5), 1, 100)
	pk.is_shiny       = tp.get("shiny",        0) == 1
	pk.ability_index  = clampi(tp.get("ability_index", 0), 0, 2)
	pk.held_item_id   = _str_or(tp.get("held_item_id"), "")
	pk.happiness      = sp.get("happiness", 70)

	# Gender: from DB or rolled from the species ratio
	var gender_val: Variant = tp.get("gender")
	pk.gender = gender_val if gender_val != null \
			else _roll_gender(sp.get("gender_ratio", "Female50Percent"), rng)

	# Nature: from DB or random
	var nature_val: Variant = tp.get("nature")
	pk.nature_id = nature_val if nature_val != null else _random_nature_id(rng)

	# Nickname
	var nick_val: Variant = tp.get("nickname")
	pk.nickname = nick_val if nick_val != null else ""

	# IVs: from DB or defaulted to 15 when the column is NULL
	pk.iv_hp  = _int_or(tp.get("iv_hp"),  15)
	pk.iv_atk = _int_or(tp.get("iv_atk"), 15)
	pk.iv_def = _int_or(tp.get("iv_def"), 15)
	pk.iv_spa = _int_or(tp.get("iv_spa"), 15)
	pk.iv_spd = _int_or(tp.get("iv_spd"), 15)
	pk.iv_spe = _int_or(tp.get("iv_spe"), 15)

	# Set HP to maximum
	pk.current_hp = pk.calc_stats()["hp"]
	return pk

# ---------------------------------------------------------------------------
# Egg
# ---------------------------------------------------------------------------

## Creates a Pokémon egg for the breeding system.
## parent_nature_id: nature to inherit (e.g., via Everstone); "" = random.
static func create_egg(
		species_id:        String,
		rng:               RandomNumberGenerator = null,
		parent_nature_id:  String               = "") -> Pokemon:

	if rng == null:
		rng = RandomNumberGenerator.new()

	var sp: Dictionary = GameData.species(species_id)
	if sp.is_empty():
		push_error("PokemonFactory.create_egg: unknown species '%s'" % species_id)
		return null

	var pk: Pokemon  = Pokemon.new()
	pk.species_id    = species_id
	pk.form_index    = 0
	pk.level         = 1
	pk.nature_id     = parent_nature_id if not parent_nature_id.is_empty() \
			else _random_nature_id(rng)
	pk.ability_index = _random_ability_index(sp, rng)
	pk.gender        = _roll_gender(sp.get("gender_ratio", "Female50Percent"), rng)
	pk.is_shiny      = _roll_shiny(rng)
	pk.happiness     = sp.get("happiness", 70)

	pk.iv_hp  = rng.randi_range(0, 31)
	pk.iv_atk = rng.randi_range(0, 31)
	pk.iv_def = rng.randi_range(0, 31)
	pk.iv_spa = rng.randi_range(0, 31)
	pk.iv_spd = rng.randi_range(0, 31)
	pk.iv_spe = rng.randi_range(0, 31)

	pk.is_egg    = true
	pk.egg_steps = sp.get("egg_steps", 5120)
	pk.met_date  = Time.get_date_string_from_system()

	# Level-1 moveset (applied when the egg hatches)
	_assign_level_moves(pk, sp, 1)

	pk.current_hp = pk.calc_stats()["hp"]
	return pk

# ---------------------------------------------------------------------------
# Save restore
# ---------------------------------------------------------------------------

## Reconstructs a Pokemon from the Dictionary stored in a save file.
static func restore(data: Dictionary) -> Pokemon:
	return Pokemon.restore(data)

# ---------------------------------------------------------------------------
# Private helpers
# ---------------------------------------------------------------------------

## Returns a random nature ID from those loaded in GameData.
static func _random_nature_id(rng: RandomNumberGenerator) -> String:
	var natures: Array = GameData.all_natures()
	if natures.is_empty():
		return "HARDY"
	return natures[rng.randi_range(0, natures.size() - 1)].get("id", "HARDY")


## Randomly selects ability slot 0 or 1; wild Pokémon never start with their hidden ability.
static func _random_ability_index(sp: Dictionary, rng: RandomNumberGenerator) -> int:
	var has_ab2: bool = sp.get("ability2_id") != null
	return rng.randi_range(0, 1) if has_ab2 else 0


## Determines gender from the species gender ratio string.
static func _roll_gender(gender_ratio: String, rng: RandomNumberGenerator) -> int:
	match gender_ratio:
		"AlwaysMale":         return 0
		"AlwaysFemale":       return 1
		"Genderless":         return 2
		"FemaleOneEighth":    return 1 if rng.randi_range(0, 7)  == 0 else 0
		"Female25Percent":    return 1 if rng.randi_range(0, 3)  == 0 else 0
		"Female50Percent":    return 1 if rng.randi_range(0, 1)  == 0 else 0
		"Female75Percent":    return 0 if rng.randi_range(0, 3)  == 0 else 1
		"FemaleSevenEighths": return 0 if rng.randi_range(0, 7)  == 0 else 1
		_: return 0


## Standard shiny odds: 1/8192 (Gen II–V base rate).
static func _roll_shiny(rng: RandomNumberGenerator) -> bool:
	return rng.randi_range(0, 8191) == 0


## Assigns the last 4 learnable moves up to `level` (no duplicates).
static func _assign_level_moves(pk: Pokemon, sp: Dictionary, level: int) -> void:
	var level_moves: Array = sp.get("level_moves", [])

	# Collect all moves learnable at or below this level, in order
	var learnable: Array = []
	for entry: Dictionary in level_moves:
		if entry.get("level", 999) <= level:
			learnable.append(entry.get("move_id", ""))

	# Deduplicate preserving last occurrence (most recently learnt wins the slot)
	var unique: Array = []
	for mid: String in learnable:
		unique.erase(mid)
		unique.append(mid)

	# Take the last 4
	pk.moves.clear()
	var start: int = maxi(0, unique.size() - 4)
	for i: int in range(start, unique.size()):
		pk.set_move(-1, unique[i])


## Returns `val` as int if non-null, or `default_val` otherwise.
static func _int_or(val: Variant, default_val: int) -> int:
	return int(val) if val != null else default_val


## Returns `val` as String if non-null, or `default_val` otherwise.
static func _str_or(val: Variant, default_val: String) -> String:
	return str(val) if val != null else default_val
