## DatabaseEditorConstants
## Shared constants for the PokeBuilder database editor tool.
## Access via: const C = preload("res://tools/database_editor/DatabaseEditorConstants.gd")

# ── Tables that must never be edited (engine/registry metadata) ───────────────
const PROTECTED_TABLES: Array[String] = [
	"db_metadata",
	"custom_tables",
]

# ── Built-in tables defined in the PokeBuilder schema ────────────────────────
# Rows are editable, but schema (columns) is fixed.
const BUILTIN_TABLES: Array[String] = [
	"game_settings",
	"types", "type_effectiveness",
	"abilities", "natures", "ribbons",
	"moves", "z_move_data", "move_contest_data",
	"items", "berry_plants",
	"pokemon_species", "pokemon_forms", "pokemon_metrics", "pokemon_form_metrics",
	"pokemon_level_moves", "pokemon_tutor_moves", "pokemon_egg_moves", "pokemon_evolutions",
	"badges",
	"trainer_types", "trainers", "trainer_pokemon", "trainer_pokemon_moves", "trainer_phone_data",
	"maps", "map_connections",
	"encounters", "encounter_slots",
	"regional_dex_entries", "town_map_points",
	"shadow_pokemon", "battle_facilities",
]

# ── SQLite views (always read-only) ──────────────────────────────────────────
const BUILTIN_VIEWS: Array[String] = [
	"v_species_full",
	"v_trainer_full",
	"v_encounter_full",
	"v_moves_full",
]

# ── Category groupings for the sidebar tree ───────────────────────────────────
const TABLE_CATEGORIES: Dictionary = {
	"Configuration": ["game_settings"],
	"Types & Battle": ["types", "type_effectiveness", "abilities", "natures", "ribbons"],
	"Moves": ["moves", "z_move_data", "move_contest_data"],
	"Items": ["items", "berry_plants"],
	"Pokemon Species": [
		"pokemon_species", "pokemon_forms",
		"pokemon_metrics", "pokemon_form_metrics",
	],
	"Pokemon Learning": [
		"pokemon_level_moves", "pokemon_tutor_moves",
		"pokemon_egg_moves", "pokemon_evolutions",
	],
	"Trainers": [
		"trainer_types", "trainers",
		"trainer_pokemon", "trainer_pokemon_moves",
		"trainer_phone_data", "badges",
	],
	"World": [
		"maps", "map_connections",
		"encounters", "encounter_slots",
		"regional_dex_entries", "town_map_points",
	],
	"Special Features": ["shadow_pokemon", "battle_facilities"],
}

# ── Human-readable display names ──────────────────────────────────────────────
const TABLE_DISPLAY_NAMES: Dictionary = {
	"db_metadata":          "DB Metadata",
	"custom_tables":        "Custom Tables Registry",
	"game_settings":        "Game Settings",
	"types":                "Types",
	"type_effectiveness":   "Type Chart",
	"abilities":            "Abilities",
	"natures":              "Natures",
	"ribbons":              "Ribbons",
	"moves":                "Moves",
	"z_move_data":          "Z-Move Data",
	"move_contest_data":    "Contest Move Data",
	"items":                "Items",
	"berry_plants":         "Berry Plants",
	"pokemon_species":      "Pokemon Species",
	"pokemon_forms":        "Pokemon Forms",
	"pokemon_metrics":      "Pokemon Metrics",
	"pokemon_form_metrics": "Form Metrics",
	"pokemon_level_moves":  "Level-Up Moves",
	"pokemon_tutor_moves":  "Tutor Moves",
	"pokemon_egg_moves":    "Egg Moves",
	"pokemon_evolutions":   "Evolutions",
	"badges":               "Badges",
	"trainer_types":        "Trainer Types",
	"trainers":             "Trainers",
	"trainer_pokemon":      "Trainer Pokemon",
	"trainer_pokemon_moves":"Trainer Moves",
	"trainer_phone_data":   "Phone Data",
	"maps":                 "Maps",
	"map_connections":      "Map Connections",
	"encounters":           "Encounter Tables",
	"encounter_slots":      "Encounter Slots",
	"regional_dex_entries": "Regional Dex",
	"town_map_points":      "Town Map",
	"shadow_pokemon":       "Shadow Pokemon",
	"battle_facilities":    "Battle Facilities",
	"v_species_full":       "Species (full view)",
	"v_trainer_full":       "Trainers (full view)",
	"v_encounter_full":     "Encounters (full view)",
	"v_moves_full":         "Moves (full view)",
}


static func get_display_name(table_name: String) -> String:
	return TABLE_DISPLAY_NAMES.get(table_name, table_name.replace("_", " ").capitalize())


## True for sqlite_* tables and the protected registry tables.
static func is_protected(table_name: String) -> bool:
	return (table_name in PROTECTED_TABLES) or table_name.begins_with("sqlite_")


## True for read-only tables (protected + views).
static func is_readonly(table_name: String) -> bool:
	return is_protected(table_name) or is_view(table_name)


## True for tables defined in the built-in schema (includes protected).
static func is_builtin(table_name: String) -> bool:
	return (table_name in BUILTIN_TABLES) or is_protected(table_name)


## True for SQLite views.
static func is_view(table_name: String) -> bool:
	return (table_name in BUILTIN_VIEWS) or table_name.begins_with("v_")


## True for user-created custom tables.
static func is_custom(table_name: String) -> bool:
	return not is_builtin(table_name) and not is_protected(table_name) and not is_view(table_name)
