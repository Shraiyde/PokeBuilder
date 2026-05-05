## GameData
## Singleton that loads and caches all static game data from the SQLite database.
##
## Equivalent to Pokémon Essentials' GameData module.
## Once loaded, all data is accessible in memory without additional DB queries.
## Dynamic data (trainer teams, encounter tables) is fetched on demand via
## the runtime query helpers at the bottom of this file.
##
## Usage:
##   var spec  = GameData.species("BULBASAUR")
##   var move  = GameData.move("TACKLE")
##   var item  = GameData.item("POTION")
##   var nat   = GameData.nature("ADAMANT")
##   var map   = GameData.map(5)
##   var team  = GameData.trainer_team("LEADER_Brock", "Brock", 0)
extends Node

# ---------------------------------------------------------------------------
# Signals
# ---------------------------------------------------------------------------

## Emitted when all data has been loaded into the cache.
signal data_loaded

## Emitted if an error occurs while loading data.
signal load_error(table: String, message: String)

# ---------------------------------------------------------------------------
# In-memory caches
# ---------------------------------------------------------------------------

## Pokémon species data: species_id → Dictionary
## Includes nested arrays: level_moves, tutor_moves, egg_moves, evolutions
var _species:       Dictionary = {}

## Alternative forms: [species_id, form_index] → Dictionary
var _forms:         Dictionary = {}

## Sprite metrics per species: species_id → Dictionary
var _metrics:       Dictionary = {}

## Moves: move_id → Dictionary
var _moves:         Dictionary = {}

## Abilities: ability_id → Dictionary
var _abilities:     Dictionary = {}

## Items: item_id → Dictionary
var _items:         Dictionary = {}

## Types: type_id → Dictionary
var _types:         Dictionary = {}

## Type effectiveness chart: [attacker_id, defender_id] → float
## Only entries that differ from 1.0 are stored; missing pairs default to 1.0
var _type_chart:    Dictionary = {}

## Natures: nature_id → Dictionary
var _natures:       Dictionary = {}

## Berry plant data: item_id → Dictionary
var _berry_plants:  Dictionary = {}

## Trainer types: trainer_type_id → Dictionary
var _trainer_types: Dictionary = {}

## Ribbons: ribbon_id → Dictionary
var _ribbons:       Dictionary = {}

## Maps: map_id (int) → Dictionary
var _maps:          Dictionary = {}

## Map connections: map_id (int) → Array[Dictionary]
var _map_connections: Dictionary = {}

## Regional Pokédex: region_index (int) → Array[String] (species IDs in dex order)
var _regional_dexes: Dictionary = {}

## Badges: badge_id (String) → Dictionary
var _badges: Dictionary = {}

## Town Map points: map_id (int) → Array[Dictionary]
var _town_map_points: Dictionary = {}

## Z-Move data: base_move_id (String) → Dictionary
## Populated unconditionally; empty when z_move_data table has no rows.
var _z_moves: Dictionary = {}

## Contest move data: move_id (String) → Dictionary
## Populated unconditionally; empty when move_contest_data table has no rows.
var _move_contest: Dictionary = {}

## True once all caches have been populated.
var _is_loaded: bool = false

# ---------------------------------------------------------------------------
# Lifecycle
# ---------------------------------------------------------------------------

func _ready() -> void:
	## Wait for RPGDatabase before loading; it is the first autoload.
	if RPGDatabase.is_ready():
		_load_all()
	else:
		RPGDatabase.database_ready.connect(_load_all, CONNECT_ONE_SHOT)

# ---------------------------------------------------------------------------
# Data loading
# ---------------------------------------------------------------------------

func _load_all() -> void:
	_load_types()
	_load_type_chart()
	_load_abilities()
	_load_natures()
	_load_moves()
	_load_items()
	_load_berry_plants()
	_load_species()
	_load_forms()
	_load_metrics()
	_load_trainer_types()
	_load_ribbons()
	_load_maps()
	_load_map_connections()
	_load_regional_dexes()
	_load_badges()
	_load_town_map_points()
	_load_z_moves()
	_load_move_contest_data()

	_is_loaded = true
	data_loaded.emit()


func _load_types() -> void:
	for row: Dictionary in RPGDatabase.query("SELECT * FROM types ORDER BY icon_position"):
		_types[row["id"]] = row


func _load_type_chart() -> void:
	for row: Dictionary in RPGDatabase.query("SELECT * FROM type_effectiveness"):
		_type_chart[[row["attacker_id"], row["defender_id"]]] = row["multiplier"]


func _load_abilities() -> void:
	for row: Dictionary in RPGDatabase.query("SELECT * FROM abilities ORDER BY id"):
		_abilities[row["id"]] = row


func _load_natures() -> void:
	for row: Dictionary in RPGDatabase.query("SELECT * FROM natures ORDER BY id"):
		_natures[row["id"]] = row


func _load_moves() -> void:
	for row: Dictionary in RPGDatabase.query("SELECT * FROM moves ORDER BY id"):
		_moves[row["id"]] = row


func _load_items() -> void:
	for row: Dictionary in RPGDatabase.query("SELECT * FROM items ORDER BY pocket, id"):
		_items[row["id"]] = row


func _load_berry_plants() -> void:
	for row: Dictionary in RPGDatabase.query("SELECT * FROM berry_plants"):
		_berry_plants[row["item_id"]] = row


func _load_species() -> void:
	## Base species data
	for row: Dictionary in RPGDatabase.query(
			"SELECT * FROM pokemon_species ORDER BY national_dex_number"):
		_species[row["id"]] = row

	## Attach level-up moves as a nested Array sorted by level
	for row: Dictionary in RPGDatabase.query(
			"SELECT * FROM pokemon_level_moves ORDER BY species_id, level"):
		var sid: String = row["species_id"]
		if _species.has(sid):
			if not _species[sid].has("level_moves"):
				_species[sid]["level_moves"] = []
			_species[sid]["level_moves"].append({"level": row["level"], "move_id": row["move_id"]})

	## Attach TM / tutor moves
	for row: Dictionary in RPGDatabase.query(
			"SELECT * FROM pokemon_tutor_moves ORDER BY species_id"):
		var sid: String = row["species_id"]
		if _species.has(sid):
			if not _species[sid].has("tutor_moves"):
				_species[sid]["tutor_moves"] = []
			_species[sid]["tutor_moves"].append(row["move_id"])

	## Attach egg moves
	for row: Dictionary in RPGDatabase.query(
			"SELECT * FROM pokemon_egg_moves ORDER BY species_id"):
		var sid: String = row["species_id"]
		if _species.has(sid):
			if not _species[sid].has("egg_moves"):
				_species[sid]["egg_moves"] = []
			_species[sid]["egg_moves"].append(row["move_id"])

	## Attach evolution paths
	for row: Dictionary in RPGDatabase.query(
			"SELECT * FROM pokemon_evolutions ORDER BY species_id"):
		var sid: String = row["species_id"]
		if _species.has(sid):
			if not _species[sid].has("evolutions"):
				_species[sid]["evolutions"] = []
			_species[sid]["evolutions"].append(row)


func _load_forms() -> void:
	for row: Dictionary in RPGDatabase.query(
			"SELECT * FROM pokemon_forms ORDER BY species_id, form_index"):
		_forms[[row["species_id"], row["form_index"]]] = row


func _load_metrics() -> void:
	for row: Dictionary in RPGDatabase.query("SELECT * FROM pokemon_metrics"):
		_metrics[row["species_id"]] = row


func _load_trainer_types() -> void:
	for row: Dictionary in RPGDatabase.query("SELECT * FROM trainer_types ORDER BY id"):
		_trainer_types[row["id"]] = row


func _load_ribbons() -> void:
	for row: Dictionary in RPGDatabase.query("SELECT * FROM ribbons ORDER BY icon_position"):
		_ribbons[row["id"]] = row


func _load_maps() -> void:
	for row: Dictionary in RPGDatabase.query("SELECT * FROM maps ORDER BY id"):
		_maps[row["id"]] = row


func _load_map_connections() -> void:
	for row: Dictionary in RPGDatabase.query(
			"SELECT * FROM map_connections ORDER BY map_id"):
		var mid: int = row["map_id"]
		if not _map_connections.has(mid):
			_map_connections[mid] = []
		_map_connections[mid].append(row)


func _load_regional_dexes() -> void:
	for row: Dictionary in RPGDatabase.query(
			"SELECT * FROM regional_dex_entries ORDER BY region_index, position"):
		var region: int = row["region_index"]
		if not _regional_dexes.has(region):
			_regional_dexes[region] = []
		_regional_dexes[region].append(row["species_id"])


func _load_badges() -> void:
	for row: Dictionary in RPGDatabase.query("SELECT * FROM badges ORDER BY region, id"):
		_badges[row["id"]] = row


func _load_town_map_points() -> void:
	for row: Dictionary in RPGDatabase.query(
			"SELECT * FROM town_map_points ORDER BY map_id, id"):
		var mid: int = row["map_id"]
		if not _town_map_points.has(mid):
			_town_map_points[mid] = []
		_town_map_points[mid].append(row)


func _load_z_moves() -> void:
	for row: Dictionary in RPGDatabase.query("SELECT * FROM z_move_data"):
		_z_moves[row["base_move_id"]] = row


func _load_move_contest_data() -> void:
	for row: Dictionary in RPGDatabase.query("SELECT * FROM move_contest_data"):
		_move_contest[row["move_id"]] = row

# ---------------------------------------------------------------------------
# Pokémon accessors
# ---------------------------------------------------------------------------

## Returns species data by ID (e.g. "BULBASAUR").
## Includes nested: level_moves, tutor_moves, egg_moves, evolutions.
func species(id: String) -> Dictionary:
	return _species.get(id, {})


## Returns alternative form data.
## form_index = 0 maps to the base form (always in _species).
func form(species_id: String, form_index: int) -> Dictionary:
	if form_index == 0:
		return species(species_id)
	return _forms.get([species_id, form_index], {})


## Returns sprite metrics for a species.
func metrics(species_id: String) -> Dictionary:
	return _metrics.get(species_id, {})


## Returns all species as an Array ordered by national Pokédex number.
func all_species() -> Array:
	return _species.values()


## Returns the regional Pokédex species order for a given region index.
## region_index = 0 is the National Pokédex.
func regional_dex(region_index: int) -> Array:
	return _regional_dexes.get(region_index, [])

# ---------------------------------------------------------------------------
# Move accessors
# ---------------------------------------------------------------------------

## Returns move data by ID (e.g. "TACKLE").
func move(id: String) -> Dictionary:
	return _moves.get(id, {})


func all_moves() -> Array:
	return _moves.values()

# ---------------------------------------------------------------------------
# Ability accessors
# ---------------------------------------------------------------------------

## Returns ability data by ID (e.g. "OVERGROW").
func ability(id: String) -> Dictionary:
	return _abilities.get(id, {})


func all_abilities() -> Array:
	return _abilities.values()

# ---------------------------------------------------------------------------
# Nature accessors
# ---------------------------------------------------------------------------

## Returns nature data by ID (e.g. "ADAMANT").
## Fields: id, name, stat_up, stat_down, flavor_likes, flavor_dislikes
func nature(id: String) -> Dictionary:
	return _natures.get(id, {})


func all_natures() -> Array:
	return _natures.values()

# ---------------------------------------------------------------------------
# Item accessors
# ---------------------------------------------------------------------------

## Returns item data by ID (e.g. "POTION").
func item(id: String) -> Dictionary:
	return _items.get(id, {})


func all_items() -> Array:
	return _items.values()


## Returns all items in a specific bag pocket (1–8).
func items_in_pocket(pocket: int) -> Array:
	return _items.values().filter(func(i: Dictionary) -> bool: return i.get("pocket", 0) == pocket)


## Returns berry plant data for an item ID (e.g. "CHERIBERRY").
func berry_plant(item_id: String) -> Dictionary:
	return _berry_plants.get(item_id, {})


func all_berry_plants() -> Array:
	return _berry_plants.values()

# ---------------------------------------------------------------------------
# Type accessors
# ---------------------------------------------------------------------------

## Returns type data by ID (e.g. "FIRE").
func type(id: String) -> Dictionary:
	return _types.get(id, {})


func all_types() -> Array:
	return _types.values()


## Returns the effectiveness multiplier of attacker_type hitting defender_type.
## 0.0 = immune · 0.5 = not very effective · 1.0 = neutral · 2.0 = super effective
func type_effectiveness(attacker_id: String, defender_id: String) -> float:
	return _type_chart.get([attacker_id, defender_id], 1.0)


## Calculates the combined type multiplier of a move against a Pokémon
## with one or two types (pass both type IDs in defender_type_ids).
func calc_type_multiplier(move_type_id: String, defender_type_ids: Array) -> float:
	var mult: float = 1.0
	for t: String in defender_type_ids:
		mult *= type_effectiveness(move_type_id, t)
	return mult

# ---------------------------------------------------------------------------
# Map accessors
# ---------------------------------------------------------------------------

## Returns map data by integer ID.
func map(id: int) -> Dictionary:
	return _maps.get(id, {})


func all_maps() -> Array:
	return _maps.values()


## Returns all outgoing connections for a given map ID.
## Each entry: { map_id, direction, connected_map_id, offset }
func map_connections(map_id: int) -> Array:
	return _map_connections.get(map_id, [])

# ---------------------------------------------------------------------------
# Badge accessors
# ---------------------------------------------------------------------------

## Returns badge data by ID (e.g. "BOULDERBADGE").
func badge(id: String) -> Dictionary:
	return _badges.get(id, {})


func all_badges() -> Array:
	return _badges.values()


## Returns all badges belonging to the given region.
func badges_for_region(region_id: String) -> Array:
	return _badges.values().filter(
		func(b: Dictionary) -> bool: return b.get("region", "") == region_id)

# ---------------------------------------------------------------------------
# Town Map accessors
# ---------------------------------------------------------------------------

## Returns all Town Map points of interest for a given map ID.
func town_map_points_for(map_id: int) -> Array:
	return _town_map_points.get(map_id, [])


func all_town_map_points() -> Array:
	var result: Array = []
	for arr: Array in _town_map_points.values():
		result.append_array(arr)
	return result

# ---------------------------------------------------------------------------
# Z-Move accessors
# ---------------------------------------------------------------------------

## Returns Z-Move data for a base move ID (e.g. "TACKLE" → {z_move_id, z_crystal_id, …}).
## Returns {} if no Z-Move exists for that move.
func z_move(base_move_id: String) -> Dictionary:
	return _z_moves.get(base_move_id, {})


func all_z_moves() -> Array:
	return _z_moves.values()

# ---------------------------------------------------------------------------
# Contest move accessors
# ---------------------------------------------------------------------------

## Returns contest data for a move ID: {category, appeal, jam}.
func move_contest(move_id: String) -> Dictionary:
	return _move_contest.get(move_id, {})


func all_move_contest_data() -> Array:
	return _move_contest.values()

# ---------------------------------------------------------------------------
# Trainer-type / Ribbon accessors
# ---------------------------------------------------------------------------

## Returns trainer type data by ID (e.g. "LEADER_Brock").
func trainer_type(id: String) -> Dictionary:
	return _trainer_types.get(id, {})


func all_trainer_types() -> Array:
	return _trainer_types.values()


func ribbon(id: String) -> Dictionary:
	return _ribbons.get(id, {})


func all_ribbons() -> Array:
	return _ribbons.values()

# ---------------------------------------------------------------------------
# Runtime query helpers (dynamic / not cached)
# ---------------------------------------------------------------------------

## Returns a trainer's base data row by type, name, and rematch version.
## version_index: 0 = initial battle, 1+ = rematches.
func trainer_row(type_id: String, trainer_name: String, version_index: int = 0) -> Dictionary:
	return RPGDatabase.query_one(
		"SELECT * FROM trainers WHERE type_id = ? AND name = ? AND version_index = ?",
		[type_id, trainer_name, version_index])


## Returns a trainer's full team as an Array of trainer_pokemon Dictionaries.
## Each row includes the move list as a nested Array under the "moves" key.
func trainer_team(type_id: String, trainer_name: String, version_index: int = 0) -> Array:
	var trainer: Dictionary = trainer_row(type_id, trainer_name, version_index)
	if trainer.is_empty():
		return []

	var trainer_id: int     = trainer.get("id", -1)
	var pokemon:    Array   = RPGDatabase.query(
		"SELECT * FROM trainer_pokemon WHERE trainer_id = ? ORDER BY position",
		[trainer_id])

	## Attach explicit move overrides to each Pokémon slot
	for pk: Dictionary in pokemon:
		var tp_id:   int   = pk.get("id", -1)
		var pk_moves: Array = RPGDatabase.query(
			"SELECT move_id FROM trainer_pokemon_moves" +
			" WHERE trainer_pokemon_id = ? ORDER BY position",
			[tp_id])
		pk["moves"] = pk_moves.map(func(r: Dictionary) -> String: return r["move_id"])

	return pokemon


## Returns all encounter slots for a map and encounter type.
## encounter_type: "Land" | "LandNight" | "Water" | "OldRod" | etc.
func encounters_for_map(map_id: int, encounter_type: String) -> Array:
	return RPGDatabase.query(
		"SELECT * FROM encounter_slots" +
		" WHERE map_id = ? AND encounter_type = ?" +
		" ORDER BY slot_index",
		[map_id, encounter_type])


## Returns the phone data row for a trainer DB id.
## Fields: greeting_text, call_text, rematch_text, item_id, item_switch_id,
##         rematch_switch_id, call_rate.
func trainer_phone_data(trainer_id: int) -> Dictionary:
	return RPGDatabase.query_one(
		"SELECT * FROM trainer_phone_data WHERE trainer_id = ?",
		[trainer_id])


## Returns all shadow Pokémon slots assigned to a trainer.
## Each row includes: position, species_id, level, heart_gauge, purification_map_id.
func shadow_pokemon_for_trainer(trainer_id: int) -> Array:
	return RPGDatabase.query(
		"SELECT * FROM shadow_pokemon WHERE trainer_id = ? ORDER BY position",
		[trainer_id])


## Returns a Battle Facility row by its string ID (e.g. "BATTLE_TOWER").
func battle_facility(facility_id: String) -> Dictionary:
	return RPGDatabase.query_one(
		"SELECT * FROM battle_facilities WHERE id = ?",
		[facility_id])


## Returns all trainers of a given trainer type.
## Useful for building a list of available rematches or phone contacts.
func trainers_of_type(type_id: String) -> Array:
	return RPGDatabase.query(
		"SELECT * FROM trainers WHERE type_id = ? ORDER BY name, version_index",
		[type_id])


## Returns all evolution paths for a species.
## Equivalent to GameData.species(id).get("evolutions", []) but queries the DB
## directly — useful if evolutions were modified at runtime.
func evolutions_for(species_id: String) -> Array:
	return RPGDatabase.query(
		"SELECT * FROM pokemon_evolutions WHERE species_id = ?",
		[species_id])


## Returns all species that evolve INTO the given species.
## Useful for building pre-evolution chains.
func pre_evolutions_of(species_id: String) -> Array:
	return RPGDatabase.query(
		"SELECT * FROM pokemon_evolutions WHERE evolved_species_id = ?",
		[species_id])


## Returns a random wild Pokémon species ID from the encounter table.
## Slots are weighted: lower slot_index = more common (PE standard distribution).
## Returns "" if there are no encounters of this type on this map.
func random_encounter_species(map_id: int, encounter_type: String,
		rng: RandomNumberGenerator = null) -> String:
	if rng == null:
		rng = RandomNumberGenerator.new()

	var slots: Array = encounters_for_map(map_id, encounter_type)
	if slots.is_empty():
		return ""

	## Build a weighted pool from the slot order (slot 0 has the highest weight)
	## PE weight distribution for Land (12 slots): 20,20,10,10,10,10,5,5,4,4,1,1
	var weights: Array = [20, 20, 10, 10, 10, 10, 5, 5, 4, 4, 1, 1]
	var pool:    Array = []
	for i: int in slots.size():
		var w: int = weights[i] if i < weights.size() else 1
		for _j: int in w:
			pool.append(slots[i])

	var chosen: Dictionary = pool[rng.randi_range(0, pool.size() - 1)]
	return chosen.get("species_id", "")

# ---------------------------------------------------------------------------
# Status
# ---------------------------------------------------------------------------

## Returns true once all caches have been populated.
func is_loaded() -> bool:
	return _is_loaded
