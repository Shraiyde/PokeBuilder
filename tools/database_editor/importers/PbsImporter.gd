## PbsImporter
## Parses Pokemon Essentials PBS text files and imports data into the database.
##
## Supported PBS types and their target tables:
##   pokemon   → pokemon_species
##   moves     → moves
##   items     → items
##   abilities → abilities
##   natures   → natures
##   types     → types
##
## All methods are static — no instantiation needed.

# ── PBS type registry ─────────────────────────────────────────────────────────

const PBS_REGISTRY: Dictionary = {
	"pokemon":   {"hints": ["pokemon.txt", "pokemon"],   "table": "pokemon_species"},
	"moves":     {"hints": ["moves.txt", "moves"],       "table": "moves"},
	"items":     {"hints": ["items.txt", "items"],       "table": "items"},
	"abilities": {"hints": ["abilities.txt","abilities"],"table": "abilities"},
	"natures":   {"hints": ["natures.txt", "natures"],   "table": "natures"},
	"types":     {"hints": ["types.txt", "types"],       "table": "types"},
}


static func get_supported_types() -> Array[String]:
	var out: Array[String] = []
	for k: String in PBS_REGISTRY:
		out.append(k)
	return out


static func get_target_table(pbs_type: String) -> String:
	return PBS_REGISTRY.get(pbs_type, {}).get("table", "")


## Guesses the PBS type from the file name. Returns "" if unknown.
static func detect_type(path: String) -> String:
	var fname: String = path.get_file().to_lower().get_basename()
	for pbs_type: String in PBS_REGISTRY:
		for hint: String in PBS_REGISTRY[pbs_type]["hints"]:
			if fname == hint.get_basename().to_lower():
				return pbs_type
	return ""


# ── File parsing ──────────────────────────────────────────────────────────────

## Parses a PBS file. Returns {ok, sections: Array[{id, fields}], error}.
static func parse_file(path: String) -> Dictionary:
	var fa := FileAccess.open(path, FileAccess.READ)
	if fa == null:
		return {"ok": false, "error": "Cannot open file.", "sections": []}
	var content := fa.get_as_text()
	fa.close()
	return parse_string(content)


## Parses PBS text into sections. Returns {ok, sections, error}.
static func parse_string(content: String) -> Dictionary:
	var sections: Array    = []
	var current_id: String = ""
	var current_fields: Dictionary = {}

	for raw: String in content.split("\n"):
		var line: String = raw.strip_edges()
		if line.is_empty() or line.begins_with("#"):
			continue

		if line.begins_with("[") and line.ends_with("]"):
			if current_id != "":
				sections.append({"id": current_id, "fields": current_fields})
			current_id     = line.substr(1, line.length() - 2).strip_edges()
			current_fields = {}
			continue

		var eq: int = line.find("=")
		if eq < 0 or current_id.is_empty():
			continue

		var key: String   = line.left(eq).strip_edges()
		var value: String = line.substr(eq + 1).strip_edges()
		# Strip inline comment (must be preceded by two spaces to avoid false positives)
		var hash_pos: int = value.find("  #")
		if hash_pos >= 0:
			value = value.left(hash_pos).strip_edges()
		current_fields[key] = value

	if not current_id.is_empty():
		sections.append({"id": current_id, "fields": current_fields})

	return {"ok": true, "sections": sections, "error": ""}


# ── Import ─────────────────────────────────────────────────────────────────────

## Full pipeline: parse → convert → INSERT OR REPLACE into target table.
## Returns {ok, imported, skipped, error}.
static func import_file(path: String, pbs_type: String) -> Dictionary:
	var parsed: Dictionary = parse_file(path)
	if not parsed["ok"]:
		return parsed

	var table: String = get_target_table(pbs_type)
	if table.is_empty():
		return {"ok": false, "imported": 0, "skipped": 0, "error": "Unknown PBS type: %s" % pbs_type}

	var imported   := 0
	var skipped    := 0
	var first_err  := ""

	RPGDatabase.execute("BEGIN")
	for section: Dictionary in parsed["sections"]:
		var row: Dictionary = _convert_section(section["id"], section["fields"], pbs_type)
		if row.is_empty():
			skipped += 1
			continue

		var cols := PackedStringArray()
		var ph   := PackedStringArray()
		var vals: Array = []
		for col: String in row:
			cols.append('"%s"' % col)
			ph.append("?")
			vals.append(row[col])

		var sql := 'INSERT OR REPLACE INTO "%s" (%s) VALUES (%s)' % [
			table, ", ".join(cols), ", ".join(ph)
		]
		if RPGDatabase.execute(sql, vals):
			imported += 1
		else:
			if first_err.is_empty():
				first_err = RPGDatabase.last_error()
			skipped += 1

	if first_err.is_empty():
		RPGDatabase.execute("COMMIT")
	else:
		RPGDatabase.execute("ROLLBACK")

	return {"ok": first_err.is_empty(), "imported": imported, "skipped": skipped, "error": first_err}


# ── Section converters ────────────────────────────────────────────────────────

static func _convert_section(id: String, f: Dictionary, pbs_type: String) -> Dictionary:
	match pbs_type:
		"pokemon":   return _conv_pokemon(id, f)
		"moves":     return _conv_move(id, f)
		"items":     return _conv_item(id, f)
		"abilities": return _conv_ability(id, f)
		"natures":   return _conv_nature(id, f)
		"types":     return _conv_type(id, f)
	return {}


static func _conv_pokemon(id: String, f: Dictionary) -> Dictionary:
	var r: Dictionary = {"id": id}

	_copy_str(r, f, "Name",       "name")
	_copy_str(r, f, "Category",   "category")
	_copy_str(r, f, "Pokedex",    "pokedex_entry")
	_copy_str(r, f, "Color",      "color")
	_copy_str(r, f, "Habitat",    "habitat")
	_copy_str(r, f, "GenderRatio","gender_ratio")
	_copy_flt(r, f, "Height",     "height")
	_copy_flt(r, f, "Weight",     "weight")
	_copy_int(r, f, "Generation", "generation")
	_copy_int(r, f, "CatchRate",  "catch_rate")
	_copy_int(r, f, "Happiness",  "happiness")
	_copy_int(r, f, "BaseExp",    "exp_yield")
	_copy_int(r, f, "HatchSteps", "egg_steps")
	_copy_str(r, f, "Flags",      "flags")

	# GrowthRate — "Parabolic" is legacy alias for MediumSlow
	if "GrowthRate" in f:
		r["exp_growth"] = "MediumSlow" if f["GrowthRate"] == "Parabolic" else f["GrowthRate"]

	# Types
	if "Types" in f:
		var t := _csv(f["Types"])
		if t.size() >= 1: r["type1_id"] = t[0]
		if t.size() >= 2: r["type2_id"] = t[1]

	# BaseStats: PBS order = HP, Atk, Def, Spe, SpA, SpD  (note: Spe is index 3!)
	if "BaseStats" in f:
		var s := _csv(f["BaseStats"])
		if s.size() >= 6:
			r["stat_hp"]  = int(s[0])
			r["stat_atk"] = int(s[1])
			r["stat_def"] = int(s[2])
			r["stat_spe"] = int(s[3])
			r["stat_spa"] = int(s[4])
			r["stat_spd"] = int(s[5])

	# EVs: "STAT,val,STAT,val,..." pairs
	if "EVs" in f:
		const EV_MAP := {
			"HP": "ev_hp", "ATTACK": "ev_atk", "DEFENSE": "ev_def",
			"SPEED": "ev_spe", "SPECIAL_ATTACK": "ev_spa", "SPECIAL_DEFENSE": "ev_spd",
		}
		var parts := _csv(f["EVs"])
		var i := 0
		while i + 1 < parts.size():
			var col: String = EV_MAP.get(parts[i], "")
			if col != "":
				r[col] = int(parts[i + 1])
			i += 2

	# Abilities
	if "Abilities" in f:
		var ab := _csv(f["Abilities"])
		if ab.size() >= 1: r["ability1_id"] = ab[0]
		if ab.size() >= 2: r["ability2_id"] = ab[1]
	if "HiddenAbilities" in f:
		var ha := _csv(f["HiddenAbilities"])
		if not ha.is_empty(): r["hidden_ability_id"] = ha[0]

	# Egg groups
	if "EggGroups" in f:
		var eg := _csv(f["EggGroups"])
		if eg.size() >= 1: r["egg_group1"] = eg[0]
		if eg.size() >= 2: r["egg_group2"] = eg[1]

	# Wild held items
	_copy_str(r, f, "WildItemCommon",   "wild_item_common")
	_copy_str(r, f, "WildItemUncommon", "wild_item_uncommon")
	_copy_str(r, f, "WildItemRare",     "wild_item_rare")

	# Shape name → integer
	if "Shape" in f:
		const SHAPE_MAP := {
			"Round": 1, "BallTail": 2, "Blob": 3, "Bipedal": 4,
			"BipedalTail": 5, "Humanoid": 6, "MultiWing": 7, "Wings": 8,
			"Quadruped": 9, "MultiBody": 10, "Multiple": 11, "MultiLimb": 12,
			"Fish": 13, "Serpentine": 14, "WingedFish": 13, "Finned": 14,
		}
		var sv: String = f["Shape"]
		r["shape"] = SHAPE_MAP.get(sv, int(sv) if sv.is_valid_int() else 0)

	# national_dex_number when section header is numeric (e.g. [001])
	if id.is_valid_int():
		r["national_dex_number"] = int(id)

	return r


static func _conv_move(id: String, f: Dictionary) -> Dictionary:
	var r: Dictionary = {"id": id}
	_copy_str(r, f, "Name",         "name")
	_copy_str(r, f, "Type",         "type_id")
	_copy_str(r, f, "Category",     "category")
	_copy_int(r, f, "Power",        "power")
	_copy_int(r, f, "Accuracy",     "accuracy")
	_copy_int(r, f, "TotalPP",      "total_pp")
	_copy_str(r, f, "Target",       "target")
	_copy_int(r, f, "Priority",     "priority")
	_copy_str(r, f, "FunctionCode", "function_code")
	_copy_str(r, f, "Flags",        "flags")
	_copy_int(r, f, "EffectChance", "effect_chance")
	_copy_str(r, f, "Description",  "description")
	return r


static func _conv_item(id: String, f: Dictionary) -> Dictionary:
	var r: Dictionary = {"id": id}
	_copy_str(r, f, "Name",              "name")
	_copy_str(r, f, "NamePlural",        "plural_name")
	_copy_int(r, f, "Pocket",            "pocket")
	_copy_int(r, f, "Price",             "price")
	_copy_int(r, f, "SellPrice",         "sell_price")
	_copy_str(r, f, "FieldUse",          "field_use")
	_copy_str(r, f, "BattleUse",         "battle_use")
	_copy_str(r, f, "FunctionCode",      "function_code")
	_copy_str(r, f, "Move",              "move_id")
	_copy_str(r, f, "FlingEffect",       "fling_effect")
	_copy_int(r, f, "NaturalGiftPower",  "natural_gift_power")
	_copy_str(r, f, "NaturalGiftType",   "natural_gift_type_id")
	_copy_str(r, f, "Flags",             "flags")
	_copy_str(r, f, "Description",       "description")
	return r


static func _conv_ability(id: String, f: Dictionary) -> Dictionary:
	var r: Dictionary = {"id": id}
	_copy_str(r, f, "Name",        "name")
	_copy_str(r, f, "Description", "description")
	_copy_str(r, f, "Flags",       "flags")
	return r


static func _conv_nature(id: String, f: Dictionary) -> Dictionary:
	const STAT_MAP := {
		"ATTACK": "atk", "DEFENSE": "def",
		"SPEED": "spe", "SPECIAL_ATTACK": "spa", "SPECIAL_DEFENSE": "spd",
	}
	var r: Dictionary = {"id": id}
	_copy_str(r, f, "Name",           "name")
	_copy_str(r, f, "LikedFlavor",    "flavor_likes")
	_copy_str(r, f, "DislikedFlavor", "flavor_dislikes")
	if "StatUp" in f:
		r["stat_up"] = STAT_MAP.get(f["StatUp"], f["StatUp"].to_lower())
	if "StatDown" in f:
		r["stat_down"] = STAT_MAP.get(f["StatDown"], f["StatDown"].to_lower())
	return r


static func _conv_type(id: String, f: Dictionary) -> Dictionary:
	var r: Dictionary = {"id": id}
	_copy_str(r, f, "Name",      "name")
	_copy_str(r, f, "ColorHex",  "color_hex")
	_copy_int(r, f, "IconPosition", "icon_position")
	if "IsPseudoType" in f:
		r["is_pseudo_type"] = 1 if f["IsPseudoType"].to_lower() in ["true", "1", "yes"] else 0
	# Note: Weaknesses/Resistances/Immunities write to type_effectiveness,
	# which requires a two-pass import — not handled here.
	return r


# ── Helpers ───────────────────────────────────────────────────────────────────

static func _csv(s: String) -> Array[String]:
	var out: Array[String] = []
	for p: String in s.split(","):
		out.append(p.strip_edges())
	return out


static func _copy_str(row: Dictionary, f: Dictionary, pbs_key: String, db_col: String) -> void:
	if pbs_key in f:
		row[db_col] = f[pbs_key]


static func _copy_int(row: Dictionary, f: Dictionary, pbs_key: String, db_col: String) -> void:
	if pbs_key in f and f[pbs_key].is_valid_int():
		row[db_col] = int(f[pbs_key])


static func _copy_flt(row: Dictionary, f: Dictionary, pbs_key: String, db_col: String) -> void:
	if pbs_key in f:
		row[db_col] = float(f[pbs_key])
