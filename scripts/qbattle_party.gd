class_name QBattleParty
extends RefCounted
## Party-record conversion + data helpers for the Quetzal battle system.
##
## The Quetzal battle engine (scripts/qbattle/) works on int species/move ids
## and its own party-record shape; the rest of the port works on Pokewilds
## records (string species, move-name strings). This class is the boundary:
## it converts records both ways and reimplements the Pokewilds data helpers
## the menus/progression used to get from BattleEngine/BattleSession
## (ensure_pokemon, exp_for_level, learn_move, gain_level, evolutions,
## reference_level / wild_level, prepare_context, make_enemy) using the
## Quetzal adapter (BattleData/BattleMon/Evolution) and the Pokewilds data
## classes (PokemonData, PokemonState) — never the Pokewilds battle loop.
## Depends on: BattleData, BattleMon, Evolution, PokemonData, PokemonState.

## ---- Party-record conversion (Pokewilds -> Quetzal) ----

## Converts one Pokewilds party record to the Quetzal record shape that
## BattleMon.from_party reads. See WIRING.md "Party record conversion".
static func to_qbattle(bd: BattleData, p: Dictionary) -> Dictionary:
	var out := {}
	out["species"] = bd.species_id_by_name(str(p.get("species", "rattata")))
	out["name"] = str(p.get("name", bd.species_name(out["species"])))
	out["level"] = int(p.get("level", 1))
	out["ivs"] = (p.get("ivs", [31, 31, 31, 31, 31, 31]) as Array).duplicate()
	out["evs"] = (p.get("evs", [0, 0, 0, 0, 0, 0]) as Array).duplicate()
	out["nature"] = _nature_id(p)
	out["ability"] = -1
	out["item"] = 0
	var mv: Array = []
	var pp: Array = []
	var ppmap: Dictionary = p.get("pp", {})
	for mname in (p.get("moves", []) as Array):
		var mid := bd.move_id_by_name(str(mname))
		if mid > 0:
			mv.append([mid, str(mname)])
			pp.append(int(ppmap.get(str(mname), bd.move(mid).get("pp", 5))))
	out["moves"] = mv
	out["pp"] = pp
	out["hp"] = int(p.get("hp", 0))
	out["exp"] = int(p.get("exp", bd.exp_at(0, out["level"])))
	out["status"] = str(p.get("status", ""))
	out["status_turns"] = int(p.get("status_counter", 0))
	out["friendship"] = int(p.get("friendship", 70))
	out["pid"] = int(p.get("pid", 0))
	out["shiny"] = bool(p.get("shiny", false))
	return out

## Nature as a Quetzal int id (0-24), or -1 when the record has none/invalid
## (the engine then rolls one). Pokewilds stores nature as a name string.
static func _nature_id(p: Dictionary) -> int:
	var n := p.get("nature", -1)
	if n is int:
		return int(n) if int(n) >= 0 and int(n) < 25 else -1
	var names: Array[String] = ["HARDY", "LONELY", "BRAVE", "ADAMANT", "NAUGHTY",
		"BOLD", "DOCILE", "RELAXED", "IMPISH", "LAX", "TIMID", "HASTY",
		"SERIOUS", "JOLLY", "NAIVE", "MODEST", "MILD", "QUIET", "BASHFUL",
		"RASH", "CALM", "GENTLE", "SASSY", "CAREFUL", "QUIRKY"]
	var idx := names.find(str(n).to_upper())
	return idx if idx >= 0 else -1

## ---- Party-record conversion (Quetzal -> Pokewilds) ----

## Converts one Quetzal party record (as returned in BattleController's
## result["party"] / result["caught"]) back to a Pokewilds record. Species
## int -> name, move [[id, name]] -> name strings, PP list -> pp dict.
## HP, PP, status, level, exp and the move list carry over; battle-only
## `stages` / `volatile` are dropped (as in the Quetzal source).
static func from_qbattle(bd: BattleData, q: Dictionary) -> Dictionary:
	var species_name := str(bd.species_name(int(q.get("species", 0)))).to_lower()
	var moves: Array[String] = []
	var pp := {}
	var qmoves: Array = q.get("moves", [])
	var qpp: Array = q.get("pp", [])
	for i in qmoves.size():
		var e = qmoves[i]
		var mid := int(e[0]) if e is Array else int(e)
		var mname := ""
		if e is Array and e.size() > 1:
			mname = str(e[1]).to_upper().replace(" ", "_")
		else:
			mname = str(bd.move_name(mid)).to_upper().replace(" ", "_")
		if mname.is_empty() or bd.move(mid).is_empty():
			continue
		moves.append(mname)
		pp[mname] = int(qpp[i]) if i < qpp.size() else int(bd.move(mid).get("pp", 5))
	var seed := {
		"species": species_name,
		"level": int(q.get("level", 1)),
		"moves": moves,
		"pp": pp,
		"exp": int(q.get("exp", 0)),
		"status": str(q.get("status", "")),
		"status_counter": int(q.get("status_turns", 0)),
		"toxic_counter": 0,
		"friendship": int(q.get("friendship", 70)),
		"pid": int(q.get("pid", 0)),
		"shiny": bool(q.get("shiny", false)),
		"name": str(q.get("name", "")),
	}
	if q.has("ivs"):
		seed["ivs"] = (q.get("ivs") as Array).duplicate()
	if q.has("evs"):
		seed["evs"] = (q.get("evs") as Array).duplicate()
	var rec := make_pokemon(species_name, int(q.get("level", 1)), null, seed)
	# make_pokemon rebuilds stats; pin the battle's exact HP/EXP/status.
	rec["hp"] = clampi(int(q.get("hp", 0)), 0, int(rec.get("max_hp", 1)))
	rec["exp"] = int(q.get("exp", rec.get("exp", 0)))
	rec["status"] = str(q.get("status", ""))
	rec["status_counter"] = int(q.get("status_turns", 0))
	return rec

## ---- Record factory (replaces BattleEngine.make_pokemon) ----

static func default_stages() -> Dictionary:
	return {"attack": 0, "defense": 0, "speed": 0, "sp_attack": 0,
		"sp_defense": 0, "accuracy": 0, "evasion": 0}

## Builds a complete Pokewilds Pokemon record (same semantics as
## BattleEngine.make_pokemon): ensure_core + legal move list + PP + EXP +
## types + status + stages/volatile + stats. `overrides` are merged in.
static func make_pokemon(species: String, level: int,
		rng: RandomNumberGenerator = null, overrides: Dictionary = {}) -> Dictionary:
	var seed_record := overrides.duplicate(true)
	seed_record["species"] = species.to_lower()
	seed_record["level"] = clampi(level, 1, 100)
	var result := PokemonState.ensure_core(seed_record, rng)
	var data := PokemonData.info(species)
	var moves: Array[String] = []
	var removed_moves: Array = result.get("unsupported_moves_removed", []).duplicate()
	var supplied_moves = result.get("moves", [])
	if typeof(supplied_moves) == TYPE_ARRAY and not (supplied_moves as Array).is_empty():
		for raw_move in supplied_moves:
			var normalized := String(raw_move).to_upper().replace(" ", "_")
			if not PokemonData.move_info(normalized).is_empty():
				moves.append(normalized)
			elif not removed_moves.has(normalized):
				removed_moves.append(normalized)
	if not removed_moves.is_empty():
		result["unsupported_moves_removed"] = removed_moves
	if moves.is_empty():
		for learned in data.get("learnset", []):
			if int(learned.get("level", 1)) <= level:
				moves.append(String(learned.get("move", "TACKLE")))
	if moves.is_empty():
		moves.append("TACKLE")
	if moves.size() > 4:
		moves = moves.slice(moves.size() - 4)
	var pp := {}
	var supplied_pp: Dictionary = result.get("pp", {}) if typeof(result.get("pp", {})) == TYPE_DICTIONARY else {}
	for move_name in moves:
		pp[move_name] = clampi(int(supplied_pp.get(move_name,
			PokemonData.move_info(move_name).get("pp", 35))), 0,
			int(PokemonData.move_info(move_name).get("pp", 35)))
	result["exp"] = int(result.get("exp", exp_for_level(species, level)))
	result["types"] = (data.get("types", ["NORMAL"]) as Array).duplicate()
	result["moves"] = moves
	result["pp"] = pp
	result["status"] = String(result.get("status", ""))
	result["status_counter"] = int(result.get("status_counter", 0))
	result["toxic_counter"] = int(result.get("toxic_counter", 0))
	result["stages"] = (overrides.get("stages", {}) as Dictionary).duplicate(true) \
		if typeof(overrides.get("stages", {})) == TYPE_DICTIONARY else default_stages()
	if (result["stages"] as Dictionary).is_empty():
		result["stages"] = default_stages()
	result["volatile"] = (overrides.get("volatile", {}) as Dictionary).duplicate(true) \
		if typeof(overrides.get("volatile", {})) == TYPE_DICTIONARY else {}
	var custom_base: Array = result.get("base_stats", []) if typeof(result.get("base_stats", [])) == TYPE_ARRAY else []
	PokemonState.apply_stats(result, overrides.has("max_hp"), custom_base)
	return result

## Normalises a possibly-incomplete record (same semantics as
## BattleEngine.ensure_pokemon): rebuild via make_pokemon, clamp HP, ensure
## stages/volatile exist.
static func ensure_pokemon(source: Dictionary) -> Dictionary:
	var fresh := make_pokemon(String(source.get("species", "rattata")),
		int(source.get("level", 1)), null, source)
	fresh["hp"] = clampi(int(fresh.get("hp", fresh.max_hp)), 0, int(fresh.max_hp))
	if typeof(fresh.get("stages", {})) != TYPE_DICTIONARY:
		fresh.stages = default_stages()
	else:
		for key in default_stages().keys():
			if not fresh.stages.has(key):
				fresh.stages[key] = 0
	if typeof(fresh.get("volatile", {})) != TYPE_DICTIONARY:
		fresh.volatile = {}
	return fresh

## Resets the battle-only state of a record (same semantics as
## BattleEngine.reset_battle_state): restores a mimicked/original form,
## restores mimicked moves/PP, clears stages and volatile.
static func reset_battle_state(pokemon: Dictionary) -> void:
	var original = (pokemon.get("volatile", {}) as Dictionary).get("original_form", {})
	if typeof(original) == TYPE_DICTIONARY and not (original as Dictionary).is_empty():
		for key in (original as Dictionary).keys():
			pokemon[key] = (original as Dictionary)[key]
	var mimic_moves = (pokemon.get("volatile", {}) as Dictionary).get("mimic_original_moves", [])
	if typeof(mimic_moves) == TYPE_ARRAY and not (mimic_moves as Array).is_empty():
		pokemon.moves = (mimic_moves as Array).duplicate()
		var mimic_pp = (pokemon.get("volatile", {}) as Dictionary).get("mimic_original_pp", {})
		if typeof(mimic_pp) == TYPE_DICTIONARY and not (mimic_pp as Dictionary).is_empty():
			pokemon.pp = (mimic_pp as Dictionary).duplicate(true)
	pokemon.stages = default_stages()
	pokemon.volatile = {}

## Refills every known move's PP to its max (same semantics as
## BattleEngine.refill_pp).
static func refill_pp(pokemon: Dictionary) -> void:
	var restored: Dictionary = {}
	var raw_moves = pokemon.get("moves", [])
	if typeof(raw_moves) != TYPE_ARRAY:
		pokemon["pp"] = restored
		return
	for raw_move in raw_moves as Array:
		var move_name: String = String(raw_move).to_upper().replace(" ", "_")
		if move_name.is_empty():
			continue
		var move_data: Dictionary = PokemonData.move_info(move_name)
		restored[move_name] = maxi(0, int(move_data.get("pp", 35)))
	pokemon["pp"] = restored

## ---- EXP / level / moves (replaces BattleEngine data helpers) ----

## EXP needed to be at `level` for `species` (same values as
## BattleEngine.exp_for_level): growth id from the adapter, then exp_at.
static func exp_for_level(species: String, level: int) -> int:
	var bd := BattleData.load_from()
	var sid := bd.species_id_by_name(species)
	var growth := 0
	if sid > 0:
		growth = int(bd.species(sid).get("growth", 0))
	return bd.exp_at(growth, level)

## Move names learned at exactly `level` (same semantics as
## BattleEngine.moves_learned_at_level): the adapter's learnset filtered
## by level, mapped back to move-name strings.
static func moves_learned_at_level(species: String, level: int) -> Array[String]:
	var bd := BattleData.load_from()
	var sid := bd.species_id_by_name(species)
	var result: Array[String] = []
	if sid <= 0:
		return result
	for e in bd.learnset(sid):
		if int(e[1]) != level:
			continue
		var mname := str(bd.move_name(int(e[0]))).to_upper().replace(" ", "_")
		if mname.is_empty() or bd.move(int(e[0])).is_empty():
			continue
		if not result.has(mname):
			result.append(mname)
	return result

## Teaches `move_name` to `pokemon` (same semantics as BattleEngine.learn_move):
## returns false when the move is unknown/already known/the party is full
## and no replace_index was given; otherwise adds or replaces the move and
## sets its PP. `replace_index` -1 means "only if a free slot exists".
static func learn_move(pokemon: Dictionary, move_name: String,
		replace_index: int = -1) -> bool:
	var normalized := move_name.to_upper().replace(" ", "_")
	if normalized.is_empty() or PokemonData.move_info(normalized).is_empty():
		return false
	var moves: Array = pokemon.get("moves", [])
	if moves.has(normalized):
		return false
	if moves.size() < 4:
		moves.append(normalized)
	elif replace_index >= 0 and replace_index < moves.size():
		var forgotten := String(moves[replace_index])
		moves[replace_index] = normalized
		var existing_pp: Dictionary = pokemon.get("pp", {})
		existing_pp.erase(forgotten)
		pokemon["pp"] = existing_pp
	else:
		return false
	pokemon["moves"] = moves
	var pp: Dictionary = pokemon.get("pp", {})
	pp[normalized] = int(PokemonData.move_info(normalized).get("pp", 35))
	pokemon["pp"] = pp
	return true

## Levels `pokemon` up by one (same semantics as BattleEngine.gain_level):
## increments the level, reapplies stats, refills PP, and returns the
## old/new level + stats + moves learned at the new level.
static func gain_level(pokemon: Dictionary) -> Dictionary:
	var old_level = int(pokemon.get("level", 1))
	var old_stats = (pokemon.get("stats", {}) as Dictionary).duplicate(true)
	var old_max_hp = int(pokemon.get("max_hp", 1))
	if old_level >= 100:
		return {
			"old_level": old_level, "new_level": old_level,
			"old_stats": old_stats, "new_stats": old_stats.duplicate(true),
			"old_max_hp": old_max_hp, "new_max_hp": old_max_hp,
			"moves": []
		}
	pokemon["level"] = old_level + 1
	PokemonState.apply_stats(pokemon, true)
	refill_pp(pokemon)
	return {
		"old_level": old_level,
		"new_level": int(pokemon.level),
		"old_stats": old_stats,
		"new_stats": (pokemon.get("stats", {}) as Dictionary).duplicate(true),
		"old_max_hp": old_max_hp,
		"new_max_hp": int(pokemon.get("max_hp", old_max_hp)),
		"moves": moves_learned_at_level(String(pokemon.species), int(pokemon.level))
	}

## ---- Evolutions (replaces BattleEngine evolution helpers) ----

## Resolves the evolution target species for a record (same semantics as
## BattleEngine.resolved_evolution_species): only the Meowstic gender split
## is special; everything else passes through lowercased.
static func resolved_evolution_species(pokemon: Dictionary, target: String) -> String:
	if target.to_lower() == "meowstic":
		return "meowstic_female" if String(pokemon.get("gender", "male")) == "female" else "meowstic_male"
	return target.to_lower()

## Applies an evolution to a Pokewilds record (same semantics as
## BattleEngine.apply_evolution): rebuilds the record as `new_species`,
## preserving the level, the HP proportion and the move list, clearing the
## status. Returns false when the target species has no data.
static func apply_evolution(pokemon: Dictionary, new_species: String) -> bool:
	new_species = resolved_evolution_species(pokemon, new_species)
	if new_species.is_empty() or PokemonData.info(new_species).is_empty():
		return false
	var old_hp := int(pokemon.get("hp", 1))
	var old_max := maxi(1, int(pokemon.get("max_hp", 1)))
	var evolution_seed := pokemon.duplicate(true)
	evolution_seed["species"] = new_species
	for erased_key in ["stats", "max_hp", "hp", "types", "ability",
			"ability_slot", "base_stats"]:
		evolution_seed.erase(erased_key)
	var rebuilt := make_pokemon(new_species, int(pokemon.get("level", 1)), null,
		evolution_seed)
	pokemon["species"] = new_species
	for key in ["types", "stats", "max_hp", "moves", "pp", "ability",
			"ability_slot"]:
		if rebuilt.has(key):
			pokemon[key] = rebuilt[key]
	var damage := maxi(0, old_max - old_hp)
	pokemon["hp"] = clampi(int(pokemon.max_hp) - damage, 0, int(pokemon.max_hp))
	pokemon["status"] = ""
	pokemon["status_counter"] = 0
	return true

## Quetzal-side evolution check for an overworld (non-battle) level-up:
## converts the record, asks Evolution.after_level_up for the target, and
## returns the target species name ("" when nothing evolves). The
## BattleController already calls this itself after a battle, so this is
## only for overworld-triggered evolutions.
static func evolution_after_level_up(pokemon: Dictionary, ctx: Dictionary = {}) -> String:
	var bd := BattleData.load_from()
	var q := to_qbattle(bd, pokemon)
	var to := Evolution.after_level_up(bd, q, ctx)
	if to <= 0:
		return ""
	return str(bd.species_name(to)).to_lower()

## ---- Level scaling (replaces BattleSession level helpers) ----

## Median level of the party (eggs excluded), or 5 when empty.
static func reference_level(player_party: Array) -> int:
	var levels: Array[int] = []
	for raw_pokemon in player_party:
		if typeof(raw_pokemon) != TYPE_DICTIONARY:
			continue
		var pokemon := raw_pokemon as Dictionary
		if bool(pokemon.get("is_egg", false)):
			continue
		levels.append(maxi(1, int(pokemon.get("level", 1))))
	if levels.is_empty():
		return 5
	levels.sort()
	var middle := levels.size() / 2
	if levels.size() % 2 == 1:
		return levels[middle]
	return (levels[middle - 1] + levels[middle]) / 2

## Wild level for a party of reference level `reference` and a source level.
static func wild_level_at(reference: int, source_level: int) -> int:
	return clampi(maxi(1, source_level), maxi(2, reference - 3), mini(100, reference + 1))

static func wild_level(player_party: Array, source_level: int) -> int:
	return wild_level_at(reference_level(player_party), source_level)

## ---- Context preparation (replaces BattleSession.prepare_context) ----

## Normalises a battle context for a single-player battle: wild foes get
## their level scaled to the player's party (unless the context is fixed
## level / Unown / a night event, which supply authored levels). Non-wild
## contexts pass through unchanged.
static func prepare_context(source: Dictionary, player_party: Array) -> Dictionary:
	var prepared := source.duplicate(true)
	if bool(prepared.get("fixed_level", false)) or bool(prepared.get("source_unown", false)) or String(prepared.get("id", "")).begins_with("source_night_"):
		return prepared
	if String(prepared.get("kind", "wild")) != "wild":
		return prepared
	var raw_party = prepared.get("party", [])
	if typeof(raw_party) != TYPE_ARRAY:
		return prepared
	var scaled_party: Array = []
	var scaled_any := false
	for raw_member in raw_party as Array:
		if typeof(raw_member) != TYPE_DICTIONARY:
			continue
		var member := (raw_member as Dictionary).duplicate(true)
		var source_level := maxi(1, int(member.get("level", 1)))
		var scaled_level := wild_level(player_party, source_level)
		member["level"] = scaled_level
		if scaled_level != source_level:
			member.erase("moves")
			member.erase("pp")
			member["met_level"] = scaled_level
			scaled_any = true
		scaled_party.append(member)
	prepared["party"] = scaled_party
	prepared["_wild_level_scaled"] = scaled_any
	return prepared

## ---- Enemy construction (replaces BattleSession.make_enemy / apply_wild_record) ----

## Builds the foe's Pokewilds record from a context party member (same
## semantics as BattleSession.make_enemy): the record is stamped with the
## trainer/location metadata and built via make_pokemon; a Silph Scope
## context marks unrevealed ghosts.
static func make_enemy(member: Dictionary, context: Dictionary,
		rng: RandomNumberGenerator = null) -> Dictionary:
	var species := String(member.get("species", "rattata")).to_lower()
	var level := maxi(1, int(member.get("level", 1)))
	var prepared := member.duplicate(true)
	prepared["original_trainer"] = String(prepared.get("original_trainer",
		context.get("trainer_name", "WILD")))
	prepared["met_location"] = String(prepared.get("met_location",
		context.get("id", "WILDERNESS")))
	var made := make_pokemon(species, level, rng, prepared)
	if bool(context.get("requires_silph_scope", false)):
		made["is_ghost"] = not bool(context.get("ghost_revealed", false))
	return made

## Applies the overworld wild record to a made foe (same semantics as
## BattleSession.apply_wild_record): when the battle did not scale the
## level, the foe keeps the overworld record's shininess, gender, nature,
## IVs, moves and other properties.
static func apply_wild_record(made: Dictionary, level: int, context: Dictionary,
		world_record: Dictionary) -> Dictionary:
	if String(context.get("kind", "wild")) != "wild":
		return made
	var source_record: Dictionary = world_record
	var source_properties = [
		"shiny", "is_shiny", "gender", "generation", "personality",
		"nature", "ability", "ability_slot", "ivs", "evs", "held_item",
		"friendship", "happiness", "nickname",
		"original_trainer", "trainer_id", "met_location",
		"pokeball", "ribbons", "markings", "pokerus"
	]
	var wild_level_scaled = bool(context.get("_wild_level_scaled", false))
	if not wild_level_scaled:
		source_properties.append_array(["moves", "pp", "met_level"])
	if source_record.is_empty():
		return made
	for key in source_properties:
		if source_record.has(key):
			made[key] = source_record[key]
	return made

## ---- Trainer foe party (for BattleController.start_trainer) ----

## Builds the foe-party array BattleController.start_trainer expects from a
## prepared context's party: one {sp, lv, iv, moves, nat, abs, item, evs}
## dict per foe mon. Species/move names are converted to int ids via the
## adapter; missing data falls back to the engine defaults (random nature,
## auto ability, learned moves, no item).
static func foe_party(bd: BattleData, prepared_context: Dictionary) -> Array:
	var out: Array = []
	for raw_member in (prepared_context.get("party", []) as Array):
		if typeof(raw_member) != TYPE_DICTIONARY:
			continue
		var member := raw_member as Dictionary
		var sp := bd.species_id_by_name(str(member.get("species", "rattata")))
		if sp <= 0:
			continue
		var mv: Array = []
		for mname in (member.get("moves", []) as Array):
			var mid := bd.move_id_by_name(str(mname))
			if mid > 0:
				mv.append(mid)
		var iv := 0
		var ivs = member.get("ivs", member.get("iv", 0))
		if ivs is Array and not (ivs as Array).is_empty():
			iv = int((ivs as Array)[0])
		elif ivs is int:
			iv = int(ivs)
		var nat := -1
		var n = member.get("nature", -1)
		if n is int and int(n) >= 0 and int(n) < 25:
			nat = int(n)
		out.append({
			"sp": sp,
			"lv": maxi(1, int(member.get("level", 1))),
			"iv": iv,
			"moves": mv,
			"nat": nat,
			"abs": int(member.get("ability_slot", -1)),
			"item": 0,
			"evs": (member.get("evs", [0, 0, 0, 0, 0, 0]) as Array).duplicate(),
		})
	return out
