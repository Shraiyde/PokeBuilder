class_name BattleData
extends RefCounted
## BattleData (Pokewilds adapter) — read-only access to the battle data for the
## PokeBuilder port, loaded from the port's own data files instead of a Quetzal
## ROM cache. This file IS the data adapter: it keeps the exact public interface
## the Quetzal battle engine expects (BattleData.load_from, move(), species(),
## type_mult(), exp_at(), effect_of(), ability_hook(), trainer(), learnset(),
## evolutions(), ...) but every value comes from Pokewilds' pokemon_db.json
## (res://data/pokemon_db.json), source_move_categories.json and
## battle_effect_map.json, plus embedded universal tables (the Gen 6+ type
## chart, the six EXP formulas). Nothing here reads a ROM.
##
## ID assignment (Quetzal uses int ids everywhere; Pokewilds uses string ids):
##   species: int ids 1..N assigned in (dex, id) order. Use
##     BattleData.species_id_by_name("abomasnow") to convert a Pokewilds
##     species string to the int id the engine takes.
##   moves: int ids 1..M assigned in name order. Use move_id_by_name("POUND").
##   types: the TypeChart consts (NORMAL=0 .. FAIRY=18). Use type_id_by_name("GRASS").
##   growth: 0 MEDIUM_FAST, 1 ERRATIC, 2 FLUCTUATING, 3 MEDIUM_SLOW, 4 FAST, 5 SLOW.
##
## Known gaps (documented in battle-port-design.md):
##   - Species have NO abilities in pokemon_db.json, so every species reports
##     abilities [0,0,0] and ability_hook() always returns {} (no ability).
##   - Move flags (contact, high_crit, punch, bite, ...) are not in the data;
##     all default false. Moves that rely on a flag for their effect still deal
##     damage, but flag-gated interactions (Rough Skin, Iron Barbs, etc.) do not fire.
##   - Moves have no target data; every move targets the single chosen foe
##     (spread moves do not hit both foes).
##   - No trainer table in pokemon_db.json, so trainer() returns {} and
##     trainer battles must be started with an explicit foe party (see WIRING.md).
##   - No item table; ball() maps the standard ball names and item_hook() is {}.
##   - EV yield is not in the data (all zero). Wild held items are not in the data.
##   - 12 Pokewilds move effects have no Quetzal equivalent and map to
##     {"k": "unknown"} (plain damage or nothing; see battle_effect_map.json).
##
## Depends on: TypeChart (consts), the port's data/*.json files. Used by:
## everything under battle/, ui/battle_screen.gd.

const STAT_KEYS := ["hp", "atk", "def", "spe", "spa", "spd"]

## Data files (port paths).
const DB_PATH := "res://data/pokemon_db.json"
const CATS_PATH := "res://data/source_move_categories.json"
const EFFECT_MAP_PATH := "res://scripts/qbattle/data/battle_effect_map.json"

## Growth-rate ids.
const GROWTH_MEDIUM_FAST := 0
const GROWTH_ERRATIC := 1
const GROWTH_FLUCTUATING := 2
const GROWTH_MEDIUM_SLOW := 3
const GROWTH_FAST := 4
const GROWTH_SLOW := 5

## Gender-ratio byte from a Pokewilds gender_ratio string.
const GENDER_RATIO := {
	"GENDER_F0": 0, "GENDER_F12_5": 31, "GENDER_F25": 63, "GENDER_F50": 127,
	"GENDER_F75": 191, "GENDER_F100": 254, "GENDER_UNKNOWN": 255,
}

## Growth-rate string -> growth id.
const GROWTH_IDS := {
	"GROWTH_MEDIUM_FAST": 0, "GROWTH_ERRATIC": 1, "GROWTH_FLUCTUATING": 2,
	"GROWTH_MEDIUM_SLOW": 3, "GROWTH_FAST": 4, "GROWTH_SLOW": 5,
}

## Pokewilds evolution method -> Quetzal Evolution method id (see evolution.gd).
## Methods with no Quetzal equivalent map to 0 (never triggers in after_level_up).
const EVO_METHODS := {
	"EVOLVE_LEVEL": 4, "EVOLVE_TRADE": 5, "EVOLVE_TRADEITEM": 6, "EVOLVE_ITEM": 7,
	"EVOLVE_ATTACKGREATER": 8, "EVOLVE_ATKDEFEQUAL": 9, "EVOLVE_DEFENSEGREATER": 10,
	"EVOLVE_NINJASK": 13, "EVOLVE_SHEDINJA": 14, "EVOLVE_BEAUTY": 15,
	"EVOLVE_LEVELFEMALE": 16, "EVOLVE_MOVE": 23,
	"EVOLVE_LEVELRAIN": 28, "EVOLVE_HASINPARTY": 29, "EVOLVE_LEVELDARKINPARTY": 30,
	"EVOLVE_SILCOON": 45, "EVOLVE_CASCOON": 46,
	"EVOLVE_LEVELDAY": 4, "EVOLVE_LEVELNIGHT": 4,
	"EVOLVE_HAPPINESS": 0, "EVOLVE_LOCATION": 0, "EVOLVE_NONE": 0,
	"EVOLVE_DAYHOLDITEM": 7, "EVOLVE_NIGHTHOLDITEM": 7, "EVOLVE_SWEETITEM": 7,
}

## Standard Gen 6+ type chart: attacking type id -> {defending type id: multiplier}.
## Only non-1.0 entries are listed; anything absent is 1.0. Type ids are the
## TypeChart consts (NORMAL 0, FIGHTING 1, FLYING 2, POISON 3, GROUND 4, ROCK 5,
## BUG 6, GHOST 7, STEEL 8, MYSTERY 9, FIRE 10, WATER 11, GRASS 12, ELECTRIC 13,
## PSYCHIC 14, ICE 15, DRAGON 16, DARK 17, FAIRY 18).
const TYPE_CHART := {
	0: {5: 0.5, 7: 0.0, 8: 0.5},
	1: {0: 2.0, 2: 0.5, 3: 0.5, 5: 2.0, 6: 0.5, 7: 0.0, 8: 2.0, 14: 0.5, 15: 2.0, 17: 2.0, 18: 0.5},
	2: {1: 2.0, 5: 0.5, 6: 2.0, 8: 0.5, 12: 2.0, 13: 0.5},
	3: {12: 2.0, 3: 0.5, 4: 0.5, 5: 0.5, 7: 0.5, 8: 0.0, 18: 2.0},
	4: {2: 0.0, 3: 2.0, 5: 2.0, 6: 0.5, 8: 2.0, 10: 2.0, 12: 0.5, 13: 2.0},
	5: {1: 0.5, 2: 2.0, 4: 0.5, 6: 2.0, 8: 0.5, 10: 2.0, 15: 2.0},
	6: {1: 0.5, 2: 0.5, 3: 0.5, 7: 0.5, 8: 0.5, 10: 0.5, 12: 2.0, 14: 2.0, 17: 2.0, 18: 0.5},
	7: {0: 0.0, 7: 2.0, 14: 2.0, 17: 0.5},
	8: {5: 2.0, 8: 0.5, 10: 0.5, 11: 0.5, 13: 0.5, 15: 2.0, 18: 2.0},
	10: {5: 0.5, 6: 2.0, 8: 2.0, 10: 0.5, 11: 0.5, 12: 2.0, 15: 2.0, 16: 0.5},
	11: {4: 2.0, 5: 2.0, 10: 2.0, 11: 0.5, 12: 0.5, 16: 0.5},
	12: {2: 0.5, 3: 0.5, 4: 2.0, 5: 2.0, 6: 0.5, 8: 0.5, 10: 0.5, 11: 2.0, 12: 0.5, 16: 0.5},
	13: {2: 2.0, 4: 0.0, 11: 2.0, 12: 0.5, 13: 0.5, 16: 0.5},
	14: {1: 2.0, 3: 2.0, 8: 0.5, 14: 0.5, 17: 0.0},
	15: {2: 2.0, 4: 2.0, 8: 0.5, 10: 0.5, 11: 0.5, 12: 2.0, 15: 0.5, 16: 2.0},
	16: {8: 0.5, 16: 2.0, 18: 0.0},
	17: {1: 0.5, 7: 2.0, 14: 2.0, 17: 0.5, 18: 0.5},
	18: {1: 2.0, 3: 0.5, 8: 0.5, 10: 0.5, 16: 2.0, 17: 2.0},
}

## Ball keys by Pokewilds ball name (upper-case). The engine only needs the
## multiplier; "basic" is a plain 1.0x ball. See BattleRules.ball_mult.
const BALLS := {
	"POKE_BALL": {"k": "basic"}, "GREAT_BALL": {"k": "basic", "mult": 1.5},
	"ULTRA_BALL": {"k": "basic", "mult": 2.0}, "MASTER_BALL": {"k": "master"},
	"PREMIER_BALL": {"k": "basic"}, "HEAL_BALL": {"k": "basic"},
	"NET_BALL": {"k": "net"}, "DIVE_BALL": {"k": "dive"}, "NEST_BALL": {"k": "nest"},
	"DUSK_BALL": {"k": "dusk"}, "TIMER_BALL": {"k": "timer"},
	"REPEAT_BALL": {"k": "repeat"}, "LUXURY_BALL": {"k": "basic"},
	"QUICK_BALL": {"k": "quick"}, "CHERISH_BALL": {"k": "basic"},
	"FAST_BALL": {"k": "fast"}, "LEVEL_BALL": {"k": "level"},
	"LURE_BALL": {"k": "lure"}, "MOON_BALL": {"k": "moon"},
	"FRIEND_BALL": {"k": "basic"}, "LOVE_BALL": {"k": "love"},
	"HEAVY_BALL": {"k": "heavy"}, "SPORT_BALL": {"k": "basic"},
	"SAFARI_BALL": {"k": "basic"}, "PARK_BALL": {"k": "basic"},
	"DREAM_BALL": {"k": "basic"}, "BEAST_BALL": {"k": "beast"},
}

## Item names in all_items order (ItemData ITEMS + BALLS + MATERIALS + KEY_ITEMS + MEDICINE).
## Item id = index + 1 (1-based, so 0 stays "no item"). 124 items.
const ITEM_NAMES: Array[String] = [
	"OLD AMBER", "HELIX FOSSIL", "DOME FOSSIL", "CLAW FOSSIL",
	"ROOT FOSSIL", "SHIELD FOSSIL", "SKULL FOSSIL", "SWEET APPLE",
	"WATER STONE", "FIRE STONE", "LEAF STONE", "THUNDERSTONE",
	"MOON STONE", "SUN STONE", "ICE STONE", "DAWN STONE",
	"DUSK STONE", "SHINY STONE", "MAX REPEL", "REPEL",
	"RARE CANDY", "BERRY SEED", "POKE DOLL", "POKE BALL",
	"GREAT BALL", "ULTRA BALL", "LOVE BALL", "FAST BALL",
	"LURE BALL", "MOON BALL", "FRIEND BALL", "HEAVY BALL",
	"MASTER BALL", "DUSK BALL", "NET BALL", "DIVE BALL",
	"QUICK BALL", "HEAL BALL", "NEST BALL", "DREAM BALL",
	"TIMER BALL", "LEVEL BALL", "PARK BALL", "LOG",
	"GRASS", "DRY SAND", "LIGHT CLAY", "FLOWERS",
	"CURSED SOIL", "ASHEN SOIL", "DRY SOIL", "MANURE",
	"PSI ENERGY", "STAR PIECE", "DARK ENERGY", "LIFE FORCE",
	"ANCIENTPOWDER", "HONEY", "SOFT WOOL", "MAGNET",
	"NEVERMELTICE", "DRAGON SCALE", "DRAGON FANG", "STARDUST",
	"BINDING BAND", "METAL COAT", "SOFT SAND", "POISON BARB",
	"MIRACLE SEED", "CHARCOAL", "HARD STONE", "SOFT FEATHER",
	"HARD SHELL", "SILKY THREAD", "MYSTIC SOIL", "DAMP SOIL",
	"THIN PAPER", "SOFT BEDDING", "CLEAR GLASS", "BIG PEARL",
	"SPELL TAG", "BLACK APRICORN", "BLUE APRICORN", "GREEN APRICORN",
	"PINK APRICORN", "RED APRICORN", "WHITE APRICORN", "YELLOW APRICORN",
	"SCRAP METAL", "MYSTIC WATER", "CONCRETE", "SLEEPING BAG",
	"ESCAPE ROPE", "SILPH SCOPE", "OLD ROD", "GOOD ROD",
	"SUPER ROD", "SECRET KEY", "BLANK DISC", "UPGRADE",
	"DUBIOUS DISC", "POTION", "SUPER POTION", "HYPER POTION",
	"MAX POTION", "FULL RESTORE", "FULL HEAL", "ANTIDOTE",
	"BURN HEAL", "ICE HEAL", "AWAKENING", "PARLYZ HEAL",
	"LUM BERRY", "PECHA BERRY", "CHERI BERRY", "ASPEAR BERRY",
	"CHESTO BERRY", "RAWST BERRY", "PERSIM BERRY", "BERRY JUICE",
	"MOOMOO MILK", "RAGECANDYBAR", "REVIVE", "MAX REVIVE",
]

## Pocket index per item id range: ITEMS 1-23 -> 0, BALLS 24-43 -> 1,
## MATERIALS 44-91 -> 2, KEY_ITEMS 92-101 -> 3, MEDICINE 102-124 -> 4.
const ITEM_POCKETS: Array[int] = [
	0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
	0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1,
	1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
	1, 1, 1, 1, 1, 1, 1, 2, 2, 2, 2, 2,
	2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2,
	2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2,
	2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2,
	2, 2, 2, 2, 2, 2, 2, 3, 3, 3, 3, 3,
	3, 3, 3, 3, 3, 4, 4, 4, 4, 4, 4, 4,
	4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4,
	4, 4, 4, 4,
]

## Item descriptions, keyed by item name (Pokewilds ItemData DESCRIPTIONS).
const ITEM_DESCS := {
	"OLD AMBER": "Amber containing DNA of ancient POKEMON.",
	"HELIX FOSSIL": "A fossil of an ancient POKEMON.",
	"DOME FOSSIL": "A fossil of an ancient POKEMON.",
	"CLAW FOSSIL": "A fossil of an ancient POKEMON.",
	"ROOT FOSSIL": "A fossil of an ancient POKEMON.",
	"SHIELD FOSSIL": "A fossil of an ancient POKEMON.",
	"SKULL FOSSIL": "A fossil of an ancient POKEMON.",
	"SWEET APPLE": "Can evolve certain POKEMON.",
	"WATER STONE": "Can evolve certain POKEMON.",
	"FIRE STONE": "Can evolve certain POKEMON.",
	"LEAF STONE": "Can evolve certain POKEMON.",
	"THUNDERSTONE": "Can evolve certain POKEMON.",
	"MOON STONE": "Can evolve certain POKEMON.",
	"SUN STONE": "Can evolve certain POKEMON.",
	"ICE STONE": "Can evolve certain POKEMON.",
	"DAWN STONE": "Can evolve certain POKEMON.",
	"DUSK STONE": "Can evolve certain POKEMON.",
	"SHINY STONE": "Can evolve certain POKEMON.",
	"MAX REPEL": "A spray that repels weak POKEMON.",
	"REPEL": "A spray that repels weak POKEMON.",
	"RARE CANDY": "Raises a POKEMON's level by 1.",
	"BERRY SEED": "Can be planted to grow BERRIES.",
	"POKE DOLL": "A cute plushie.",
	"POKE BALL": "A tool for catching POKEMON.",
	"GREAT BALL": "A good tool for catching POKEMON.",
	"ULTRA BALL": "An excellent tool for catching POKEMON.",
	"LOVE BALL": "Catch POKEMON of the opposite gender.",
	"FAST BALL": "Most effective on fast POKEMON.",
	"LURE BALL": "Most effective while fishing.",
	"MOON BALL": "For POKEMON that evolve by Moon Stone.",
	"FRIEND BALL": "A ball that raises FRIENDSHIP.",
	"HEAVY BALL": "Most effective on heavy POKEMON.",
	"MASTER BALL": "The best BALL. It never misses.",
	"DUSK BALL": "Most effective in dark areas.",
	"NET BALL": "Best for BUG and WATER type POKEMON.",
	"DIVE BALL": "Catch POKEMON underwater.",
	"QUICK BALL": "Best when used at start of encounter.",
	"HEAL BALL": "Heals the POKEMON it contains.",
	"NEST BALL": "Most effective on weaker POKEMON.",
	"DREAM BALL": "Catch sleeping POKEMON.",
	"TIMER BALL": "Most effective in a longer battle.",
	"LEVEL BALL": "Most effective on low-level POKEMON.",
	"PARK BALL": "A special BALL used in the Park.",
	"LOG": "A sturdy LOG.",
	"GRASS": "Freshly cut GRASS.",
	"DRY SAND": "Hot, dry sand from the desert.",
	"LIGHT CLAY": "Soft clay from the mountains.",
	"FLOWERS": "Small, beautiful flowers.",
	"CURSED SOIL": "Soil taken from a graveyard.",
	"ASHEN SOIL": "Soil found near a volcano.",
	"DRY SOIL": "Dry soil from the savannah.",
	"MANURE": "A smelly fertilizer.",
	"PSI ENERGY": "An energy exuded by PSYCHIC types.",
	"STAR PIECE": "A sparkling gem.",
	"DARK ENERGY": "An energy exuded by DARK types.",
	"LIFE FORCE": "An energy exuded by GHOST types.",
	"ANCIENTPOWDER": "A mysterious and rare powder.",
	"HONEY": "A sweet and sticky treat.",
	"SOFT WOOL": "A held item that raises SPECIAL DEFENSE.",
	"MAGNET": "A held item that boosts ELECTRIC moves.",
	"NEVERMELTICE": "A held item that boosts ICE moves.",
	"DRAGON SCALE": "A scale from a DRAGON type.",
	"DRAGON FANG": "A held item that boosts DRAGON moves.",
	"STARDUST": "A sparkling powder.",
	"BINDING BAND": "A held item that strengthens trapping moves.",
	"METAL COAT": "A held item that boosts STEEL moves.",
	"SOFT SAND": "A held item that boosts GROUND moves.",
	"POISON BARB": "A held item that boosts POISON moves.",
	"MIRACLE SEED": "Plant it, or hold it to boost GRASS moves.",
	"CHARCOAL": "A held item that boosts FIRE moves.",
	"HARD STONE": "A held item that boosts ROCK moves.",
	"SOFT FEATHER": "A held item that boosts FLYING moves.",
	"HARD SHELL": "A held item that raises DEFENSE.",
	"SILKY THREAD": "A held item that boosts BUG moves.",
	"MYSTIC SOIL": "Soil from the Forest.",
	"DAMP SOIL": "Soil from the Lake.",
	"THIN PAPER": "A soft paper good for making posters.",
	"SOFT BEDDING": "For a comfy bed and faster healing.",
	"CLEAR GLASS": "Clear, delicate glass.",
	"BIG PEARL": "A big, beautiful pearl.",
	"SPELL TAG": "A held item that boosts GHOST moves.",
	"BLACK APRICORN": "A black APRICORN.",
	"BLUE APRICORN": "A blue APRICORN.",
	"GREEN APRICORN": "A green APRICORN.",
	"PINK APRICORN": "A pink APRICORN.",
	"RED APRICORN": "A red APRICORN.",
	"WHITE APRICORN": "A white APRICORN.",
	"YELLOW APRICORN": "A yellow APRICORN.",
	"SCRAP METAL": "Discarded metal useful for crafting.",
	"MYSTIC WATER": "A held item that boosts WATER moves.",
	"CONCRETE": "A strong building material.",
	"SLEEPING BAG": "Slowly restores party HP.",
	"ESCAPE ROPE": "Takes you to a nearby shore.",
	"SILPH SCOPE": "An item that identifies ghosts.",
	"OLD ROD": "Use by water to fish for POKEMON.",
	"GOOD ROD": "Use by water to fish for POKEMON.",
	"SUPER ROD": "Use by water to fish for POKEMON.",
	"SECRET KEY": "A mysterious key.",
	"BLANK DISC": "A worn disc with no recorded move.",
	"UPGRADE": "A transparent device filled with data.",
	"DUBIOUS DISC": "A device filled with dubious data.",
	"POTION": "Restores 20 HP.",
	"SUPER POTION": "Restores 50 HP.",
	"HYPER POTION": "Restores 200 HP.",
	"MAX POTION": "Fully restores a POKEMON's HP.",
	"FULL RESTORE": "Fully restores HP and status.",
	"FULL HEAL": "Cures all status conditions.",
	"ANTIDOTE": "Cures a POKEMON of POISON.",
	"BURN HEAL": "Cures a POKEMON of BURN.",
	"ICE HEAL": "Cures a POKEMON of FREEZE.",
	"AWAKENING": "Awakens a sleeping POKEMON.",
	"PARLYZ HEAL": "Cures a POKEMON of PARALYSIS.",
	"LUM BERRY": "Cures a POKEMON of STATUS EFFECTS.",
	"PECHA BERRY": "Cures a POKEMON of POISON.",
	"CHERI BERRY": "Cures a POKEMON of PARALYSIS.",
	"ASPEAR BERRY": "Cures a POKEMON of FREEZE.",
	"CHESTO BERRY": "Cures a POKEMON of SLEEP.",
	"RAWST BERRY": "Cures a POKEMON of BURN.",
	"PERSIM BERRY": "Cures a POKEMON of CONFUSION.",
	"BERRY JUICE": "A healing drink that restores HP.",
	"MOOMOO MILK": "A nutritious drink that restores HP.",
	"RAGECANDYBAR": "A candy bar that can restore HP.",
	"REVIVE": "Restores a fainted POKEMON to half HP.",
	"MAX REVIVE": "Fully restores a fainted POKEMON.",
}

static var _cache: BattleData = null

var _db: Dictionary = {}
var _cats: Dictionary = {}
var _effect_map: Dictionary = {}
var _species_by_int: Array = []
var _species_int_by_name := {}
var _moves_by_int: Array = []
var _move_int_by_name := {}
var _type_id_by_name := {}

## Medicine table: port item id (as a string) -> {k, ...} effect record.
## Same shape the Quetzal profile "bag" table had, but keyed by the port's
## item ids and holding the port's medicine effects (see _load).
var item_kinds: Dictionary = {}

## Loads (once) and returns the data. The `dir` argument is kept for
## source-compatibility with the Quetzal call sites and is ignored: the port
## reads the fixed data paths above.
static func load_from(dir: String = "") -> BattleData:
	if _cache != null:
		return _cache
	var bd := BattleData.new()
	bd._load()
	_cache = bd
	return bd

func _load() -> void:
	_db = _read_json(DB_PATH)
	_cats = _read_json(CATS_PATH)
	_effect_map = _read_json(EFFECT_MAP_PATH)
	# Medicine table (port item ids, ItemData index+1). Heal amounts are the
	# port's own (ItemData DESCRIPTIONS); Moomoo Milk / Berry Juice /
	# RageCandyBar are the standard values (the port gives no amount).
	item_kinds = {
		"102": {"k": "heal", "hp": 20},
		"103": {"k": "heal", "hp": 50},
		"104": {"k": "heal", "hp": 200},
		"105": {"k": "heal", "hp": 9999},
		"106": {"k": "heal", "hp": 9999, "cure": true},
		"107": {"k": "cure", "s": ["psn", "tox", "brn", "par", "slp", "frz", "confusion"]},
		"108": {"k": "cure", "s": ["psn", "tox"]},
		"109": {"k": "cure", "s": ["brn"]},
		"110": {"k": "cure", "s": ["frz"]},
		"111": {"k": "cure", "s": ["slp"]},
		"112": {"k": "cure", "s": ["par"]},
		"113": {"k": "cure", "s": ["psn", "tox", "brn", "par", "slp", "frz", "confusion"]},
		"114": {"k": "cure", "s": ["psn", "tox"]},
		"115": {"k": "cure", "s": ["par"]},
		"116": {"k": "cure", "s": ["frz"]},
		"117": {"k": "cure", "s": ["slp"]},
		"118": {"k": "cure", "s": ["brn"]},
		"119": {"k": "cure", "s": ["confusion"]},
		"120": {"k": "heal", "hp": 20},
		"121": {"k": "heal", "hp": 100},
		"122": {"k": "heal", "hp": 20},
		"123": {"k": "revive", "frac": 2},
		"124": {"k": "revive", "frac": 1},
	}
	# Type name -> TypeChart id.
	_type_id_by_name = {
		"NORMAL": 0, "FIGHTING": 1, "FLYING": 2, "POISON": 3, "GROUND": 4,
		"ROCK": 5, "BUG": 6, "GHOST": 7, "STEEL": 8, "FIRE": 10,
		"WATER": 11, "GRASS": 12, "ELECTRIC": 13, "PSYCHIC": 14, "ICE": 15,
		"DRAGON": 16, "DARK": 17, "FAIRY": 18,
	}
	# Species int ids in (dex, id) order.
	var sp: Dictionary = _db.get("species", {})
	var names: Array = sp.keys()
	names.sort_custom(func(a, b):
		var da := int(sp[a].get("dex", 0))
		var db := int(sp[b].get("dex", 0))
		if da != db:
			return da < db
		return str(a) < str(b))
	_species_by_int = [null]
	for n in names:
		_species_int_by_name[str(n).to_lower()] = _species_by_int.size()
		_species_by_int.append(sp[n])
	# Move int ids in name order.
	var mv: Dictionary = _db.get("moves", {})
	var mnames: Array = mv.keys()
	mnames.sort()
	_moves_by_int = [null]
	for n in mnames:
		_move_int_by_name[str(n).to_upper()] = _moves_by_int.size()
		_moves_by_int.append(mv[n])

static func _read_json(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var d = JSON.parse_string(FileAccess.get_file_as_string(path))
	return d if d is Dictionary else {}

## True when the data loaded.
func ok() -> bool:
	return not _db.is_empty() and _species_by_int.size() > 1

## Pokewilds species string ("abomasnow") -> int id for the engine. 0 if unknown.
func species_id_by_name(species_name: String) -> int:
	return int(_species_int_by_name.get(species_name.to_lower(), 0))

## Pokewilds move string ("POUND") -> int id for the engine. 0 if unknown.
func move_id_by_name(move_name: String) -> int:
	return int(_move_int_by_name.get(move_name.to_upper(), 0))

## Pokewilds type string ("GRASS") -> TypeChart id. -1 if unknown.
func type_id_by_name(type_name: String) -> int:
	return int(_type_id_by_name.get(type_name.to_upper(), -1))

## Move record as a dictionary (same shape the Quetzal engine expects).
## acc 0 means "never misses" (used for EFFECT_ALWAYS_HIT moves). cat: 0 physical,
## 1 special, 2 status. target 0 = the single chosen foe (no spread data in Pokewilds).
## Flags default false (not in the data; see the header gaps).
func move(id: int) -> Dictionary:
	if id <= 0 or id >= _moves_by_int.size():
		return {}
	var m: Dictionary = _moves_by_int[id]
	var effect_name := str(m.get("effect", "EFFECT_NORMAL_HIT"))
	var cat := 2
	match str(_cats.get(str(m.get("name", "")).to_upper(), "STATUS")).to_upper():
		"PHYSICAL":
			cat = 0
		"SPECIAL":
			cat = 1
		_:
			cat = 2
	var acc := int(m.get("accuracy", 100))
	if effect_name == "EFFECT_ALWAYS_HIT":
		acc = 0
	var pri := 1 if effect_name == "EFFECT_PRIORITY_HIT" else 0
	return {"id": id, "eff": id, "effect_name": effect_name,
		"power": int(m.get("power", 0)), "type": type_id_by_name(str(m.get("type", "NORMAL"))),
		"acc": acc, "pp": int(m.get("pp", 5)), "chance": int(m.get("effect_chance", 0)),
		"target": 0, "pri": pri, "cat": cat,
		"contact": false, "high_crit": false, "reflectable": false, "snatch": false,
		"charge": false, "punch": false, "has_secondary": int(m.get("effect_chance", 0)) > 0,
		"bite": false, "pulse": false, "sound": false, "bullet": false, "powder": false,
		"dance": false, "wind": false, "slicing": false, "minimize": false, "thaws": false,
		"bypass_sub": false, "gravity_ban": false, "healing": false,
		"name": str(m.get("name", "MOVE"))}

## Number of move ids.
func move_count() -> int:
	return _moves_by_int.size()

## Move name from the id, or "Move <id>".
func move_name(id: int) -> String:
	if id <= 0 or id >= _moves_by_int.size():
		return "Move %d" % id
	return str(_moves_by_int[id].get("name", "MOVE"))

## Species record: {id, base{hp..spd}, types[2], catch, exp_yield, growth,
## abilities[3], gender, ev_yield{...}, name, friendship, wild_items, weight}.
## abilities is always [0,0,0] (no ability data in pokemon_db.json).
func species(id: int) -> Dictionary:
	if id <= 0 or id >= _species_by_int.size():
		return {}
	var s: Dictionary = _species_by_int[id]
	var st: Array = s.get("stats", [1, 1, 1, 1, 1, 1])
	var base := {}
	for i in 6:
		base[STAT_KEYS[i]] = int(st[i]) if i < st.size() else 1
	var types: Array = s.get("types", ["NORMAL"])
	var t0 := type_id_by_name(str(types[0])) if types.size() > 0 else 0
	var t1 := type_id_by_name(str(types[1])) if types.size() > 1 else t0
	if t0 < 0:
		t0 = 0
	if t1 < 0:
		t1 = t0
	var ev := {}
	for k in STAT_KEYS:
		ev[k] = 0
	return {"id": id, "base": base, "types": [t0, t1],
		"catch": int(s.get("catch_rate", 45)), "exp_yield": int(s.get("base_exp", 64)),
		"growth": int(GROWTH_IDS.get(str(s.get("growth_rate", "GROWTH_MEDIUM_FAST")), 0)),
		"abilities": [0, 0, 0],
		"gender": int(GENDER_RATIO.get(str(s.get("gender_ratio", "GENDER_UNKNOWN")), 255)),
		"ev_yield": ev, "name": str(s.get("name", "?")),
		"friendship": int(s.get("base_happiness", 70)),
		"wild_items": [0, 0],
		"weight": int(float(s.get("weight_kg", 0.0)) * 10.0)}

## Evolutions of a species: [[method, param, target species int id], ...].
func evolutions(id: int) -> Array:
	if id <= 0 or id >= _species_by_int.size():
		return []
	var out: Array = []
	for e in _species_by_int[id].get("evolutions", []):
		var meth := int(EVO_METHODS.get(str(e.get("method", "")), 0))
		var to := species_id_by_name(str(e.get("species", "")))
		if to <= 0:
			continue
		var par := 0
		var raw_par := str(e.get("parameter", ""))
		if raw_par.is_valid_int():
			par = int(raw_par)
		elif str(e.get("method", "")) in ["EVOLVE_ITEM", "EVOLVE_DAYHOLDITEM", "EVOLVE_NIGHTHOLDITEM", "EVOLVE_SWEETITEM"]:
			# Stone / held-item name -> port item id (ItemData index+1), so
			# Evolution.by_item() can match and stones can evolve.
			var idx := ITEM_NAMES.find(raw_par.to_upper())
			par = idx + 1 if idx >= 0 else 0
		elif str(e.get("method", "")) == "EVOLVE_MOVE":
			par = move_id_by_name(raw_par)
		elif str(e.get("method", "")) == "EVOLVE_HASINPARTY":
			par = species_id_by_name(raw_par)
		elif str(e.get("method", "")) == "EVOLVE_SHEDINJA":
			par = 20
		out.append([meth, par, to])
	return out

## True if some species evolves into nothing more from `id`.
func can_evolve(id: int) -> bool:
	return not evolutions(id).is_empty()

## Held-item hook for an item id. No held-item battle data in the port, so {}.
func item_hook(id: int) -> Dictionary:
	return {}

## Ball entry for an item id. `id` may be an int (Pokewilds item id) or a
## ball name string; unknown balls fall back to a plain 1.0x ball so catching
## still works. See BattleRules.ball_mult.
func ball(id) -> Dictionary:
	var nm := ""
	if id is String:
		nm = str(id).to_upper().replace(" ", "_")
	else:
		nm = item_name(int(id)).to_upper().replace(" ", "_")
	return BALLS.get(nm, {})

## Species name from the id, or "#<id>".
func species_name(id: int) -> String:
	if id <= 0 or id >= _species_by_int.size():
		return "#%d" % id
	return str(_species_by_int[id].get("name", "?"))

## Level-up learnset [[move int id, level], ...] in Pokewilds order.
func learnset(id: int) -> Array:
	if id <= 0 or id >= _species_by_int.size():
		return []
	var out: Array = []
	for e in _species_by_int[id].get("learnset", []):
		var mid := move_id_by_name(str(e.get("move", "")))
		if mid > 0:
			out.append([mid, int(e.get("level", 1))])
	return out

## Type name from the id.
func type_name(t: int) -> String:
	for n in _type_id_by_name:
		if int(_type_id_by_name[n]) == t:
			return n
	return "?"

## Ability name. No ability data in the port.
func ability_name(id: int) -> String:
	return "-"

## Item name from the port's ItemData (id = all_items index + 1).
func item_name(id: int) -> String:
	if id >= 1 and id <= ITEM_NAMES.size():
		return ITEM_NAMES[id - 1]
	return "Item %d" % id

## Item description from the port's ItemData DESCRIPTIONS; "" when unknown.
func item_desc(id: int) -> String:
	return str(ITEM_DESCS.get(item_name(id), ""))

## Port pocket index 0-4 for an item id (0 when unknown).
func item_pocket(id: int) -> int:
	if id >= 1 and id <= ITEM_POCKETS.size():
		return ITEM_POCKETS[id - 1]
	return 0

## Number of species int ids (1..N).
func species_count() -> int:
	return _species_by_int.size() - 1

## Multiplier of one attacking type against one defending type.
func type_mult1(atk: int, def: int) -> float:
	var row: Dictionary = TYPE_CHART.get(atk, {})
	return float(row.get(def, 1.0))

## Total multiplier against a defender's types (a repeated type counts once).
func type_mult(atk: int, def_types: Array) -> float:
	var m := type_mult1(atk, int(def_types[0]))
	if def_types.size() > 1 and int(def_types[1]) != int(def_types[0]):
		m *= type_mult1(atk, int(def_types[1]))
	return m

## Total experience needed to be at `level` for a growth-rate id.
## Standard Gen 3+ formulas (integer math).
func exp_at(growth: int, level: int) -> int:
	level = clampi(level, 1, 100)
	var l := level
	match growth:
		GROWTH_FAST:
			return (4 * l * l * l) / 5
		GROWTH_MEDIUM_FAST:
			return l * l * l
		GROWTH_MEDIUM_SLOW:
			return (6 * l * l * l) / 5 - 15 * l * l + 100 * l - 140
		GROWTH_SLOW:
			return (5 * l * l * l) / 4
		GROWTH_ERRATIC:
			if l <= 50:
				return (l * l * l * (100 - l)) / 50
			if l <= 68:
				return (l * l * l * (150 - l)) / 100
			if l <= 98:
				return (l * l * l * ((1911 - 10 * l) / 3)) / 500
			return (l * l * l * (160 - l)) / 100
		GROWTH_FLUCTUATING:
			if l <= 15:
				return (l * l * l * ((l + 1) / 3 + 24)) / 50
			if l <= 36:
				return (l * l * l * (l + 14)) / 50
			return (l * l * l * (l / 2 + 32)) / 50
	return l * l * l

## Our effect entry for a move ({k, ...params}); {"k": "unknown"} when the
## move's Pokewilds effect has no Quetzal equivalent (see battle_effect_map.json).
func effect_of(m: Dictionary) -> Dictionary:
	var eff_name := str(m.get("effect_name", ""))
	if eff_name == "":
		# Fall back to the effect map by move name (for callers that pass a
		# bare move dict without effect_name).
		return {"k": "unknown"}
	return _effect_map.get(eff_name, {"k": "unknown"})

## Our hook entry for an ability id. No ability data in the port.
func ability_hook(id: int) -> Dictionary:
	return {}

## Trainer record. No trainer table in pokemon_db.json; trainer battles must
## be started with an explicit foe party (see WIRING.md). Returns {}.
func trainer(id: int, table: int = 0) -> Dictionary:
	return {}

## Universal spawn pools (kept for interface compatibility; the port's spawns
## come from its own world generator, not this). Returns the species ids by
## type: water = any species with Water in either type slot, land = the rest.
func universal_pools() -> Dictionary:
	var land: Array = []
	var water: Array = []
	var seen := {}
	for id in range(1, _species_by_int.size()):
		var s := species(id)
		if s.is_empty():
			continue
		var nm := str(s.get("name", ""))
		if nm == "" or seen.has(nm):
			continue
		seen[nm] = true
		if 11 in (s.get("types", []) as Array):
			water.append(id)
		else:
			land.append(id)
	return {"land": land, "water": water}
