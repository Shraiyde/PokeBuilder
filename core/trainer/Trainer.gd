## Trainer
## Runtime trainer assembled from the database.
## Wraps a trainer DB row and builds a typed Array[Pokemon] team on demand.
##
## Usage:
##   var trainer: Trainer = Trainer.build("YOUNGSTER", "Ben", 0)
##   if trainer == null: return   # not found in DB
##   var lead: Pokemon = trainer.active_pokemon()
##   if trainer.all_fainted(): ...
class_name Trainer
extends RefCounted

# ---------------------------------------------------------------------------
# Properties — trainer identity
# ---------------------------------------------------------------------------

## Trainer class identifier (e.g. "YOUNGSTER").
var type_id: String = ""

## Trainer's display name (e.g. "Ben").
var trainer_name: String = ""

## Version index: 0 = initial fight, 1+ = rematches.
var version_index: int = 0

## Database surrogate key; -1 if not loaded from DB.
var db_id: int = -1

## AI skill level (1–5; from trainer_types.ai_skill).
var ai_skill: int = 1

## Prize money formula base (from trainer_types.base_money).
var base_money: int = 0

## Base BGM key (from trainer_types.battle_bgm; "" = use global default).
var battle_bgm: String = ""

## Raw flags string from trainer_types (e.g. "GymLeader", "EliteFour").
var flags: String = ""

## Items the trainer can use during battle (from trainers.items).
var items: Array[String] = []

# ---------------------------------------------------------------------------
# Properties — team
# ---------------------------------------------------------------------------

## Live Pokémon team. Populated by build() via PokemonFactory.
var team: Array[Pokemon] = []

## Index of the Pokémon currently on the field (-1 = not yet chosen).
var active_index: int = -1

# ---------------------------------------------------------------------------
# Factory
# ---------------------------------------------------------------------------

## Assembles and returns a Trainer from the database.
## Returns null if the trainer is not found.
static func build(
		p_type_id:     String,
		p_name:        String,
		p_version:     int    = 0) -> Trainer:

	# Fetch trainer row
	var row: Dictionary = RPGDatabase.query_one(
		"SELECT * FROM trainers WHERE type_id = ? AND name = ? AND version_index = ?",
		[p_type_id, p_name, p_version])
	if row.is_empty():
		push_warning("Trainer.build: not found [%s / %s / v%d]" % [p_type_id, p_name, p_version])
		return null

	# Fetch trainer type data
	var ttype: Dictionary = GameData.trainer_type(p_type_id)

	var t: Trainer       = Trainer.new()
	t.type_id            = p_type_id
	t.trainer_name       = p_name
	t.version_index      = p_version
	t.db_id              = row.get("id", -1)
	t.ai_skill           = ttype.get("ai_skill", 1)
	t.base_money         = ttype.get("base_money", 0)
	t.battle_bgm         = ttype.get("battle_bgm", "")
	t.flags              = ttype.get("flags", "")

	# Parse the comma-separated item list (may be NULL in DB)
	var items_raw: String = str(row.get("items", ""))
	if items_raw != "" and items_raw != "<null>":
		for item_id: String in items_raw.split(","):
			var trimmed: String = item_id.strip_edges()
			if trimmed != "":
				t.items.append(trimmed)

	# Build the Pokémon team
	var slots: Array = GameData.trainer_team(p_type_id, p_name, p_version)
	for slot: Dictionary in slots:
		var pk: Pokemon = PokemonFactory.create_from_trainer_slot(slot)
		if pk != null:
			t.team.append(pk)

	# Choose the first Pokémon as the lead
	if not t.team.is_empty():
		t.active_index = 0

	return t

# ---------------------------------------------------------------------------
# Team helpers
# ---------------------------------------------------------------------------

## Returns the Pokémon currently on the field, or null if none.
func active_pokemon() -> Pokemon:
	if active_index < 0 or active_index >= team.size():
		return null
	return team[active_index]


## Switches the active slot to the Pokémon at the given team index.
## Does nothing if the index is out of range or that Pokémon has fainted.
func switch_to(index: int) -> bool:
	if index < 0 or index >= team.size():
		return false
	if team[index].is_fainted():
		return false
	active_index = index
	return true


## Returns the first available (non-fainted) team index, or -1 if all fainted.
func next_available_index() -> int:
	for i: int in team.size():
		if not team[i].is_fainted():
			return i
	return -1


## Advances active_index to the next non-fainted Pokémon.
## Returns true if a replacement was found.
func send_next() -> bool:
	var idx: int = next_available_index()
	if idx == -1:
		return false
	active_index = idx
	return true


## Returns true when every Pokémon on the team has fainted.
func all_fainted() -> bool:
	for pk: Pokemon in team:
		if not pk.is_fainted():
			return false
	return true


## Returns the total prize money awarded when this trainer is defeated.
## Standard formula: base_money × (highest level Pokémon on team).
func prize_money() -> int:
	var highest_level: int = 0
	for pk: Pokemon in team:
		if pk.level > highest_level:
			highest_level = pk.level
	return base_money * highest_level


## Returns true if the trainer's flags string contains the given flag.
func has_flag(flag: String) -> bool:
	return flags.contains(flag)
