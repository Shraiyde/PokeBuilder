## TextManager
## Singleton that handles all text processing in the game:
##   - Variable substitution in strings ([player_name], [pokemon_name], etc.)
##   - Integration with Godot's translation system (tr())
##   - Number, time, and stat formatting
##   - BBCode colour and style support for RichTextLabel
##
## Equivalent to Pokémon Essentials' escape codes (\PN, \TN, \TP, etc.)
##
## Usage:
##   TextManager.parse("Hello, [player_name]! How are your Pokémon?")
##   TextManager.t("MSG_BATTLE_WIN")
##   TextManager.t("MSG_TRAINER_DEFEAT", {"trainer": "Brock"})
extends Node

# ---------------------------------------------------------------------------
# Signals
# ---------------------------------------------------------------------------

## Emitted when the active language changes.
signal language_changed(locale: String)

# ---------------------------------------------------------------------------
# Global context variables
## Updated by the corresponding systems before any text is parsed.
# ---------------------------------------------------------------------------

## Battle context (set when a battle starts).
var battle_context: Dictionary = {
	"enemy_trainer_name":  "",   ## Enemy trainer's name
	"enemy_trainer_class": "",   ## Enemy trainer's class (e.g. "Pokémon Trainer")
	"enemy_pokemon_name":  "",   ## Name of the enemy's active Pokémon
	"own_pokemon_name":    "",   ## Name of the player's active Pokémon
	"move_name":           "",   ## Name of the move just used
	"item_name":           "",   ## Name of the item just used
}

## Event context (map / dialogue).
var event_context: Dictionary = {
	"npc_name":  "",  ## Name of the NPC currently speaking
	"location":  "",  ## Name of the current location
}

# ---------------------------------------------------------------------------
# Language
# ---------------------------------------------------------------------------

## Active locale (e.g. "en", "es", "ja").
var current_locale: String:
	get: return TranslationServer.get_locale()
	set(v): _set_locale(v)


func _set_locale(locale: String) -> void:
	if TranslationServer.get_locale() == locale:
		return
	TranslationServer.set_locale(locale)
	GameManager.set_setting("language", locale)
	language_changed.emit(locale)


## Returns the available locales (those with loaded .po files).
func available_locales() -> Array:
	return TranslationServer.get_loaded_locales()

# ---------------------------------------------------------------------------
# Translation + variable substitution
# ---------------------------------------------------------------------------

## Translates a message key and substitutes context variables.
## vars_extra: additional variables specific to this message.
##
## Example:
##   TextManager.t("MSG_CAUGHT", {"species": "Pikachu"})
##   → "You caught Pikachu!"
func t(key: String, vars_extra: Dictionary = {}) -> String:
	var raw: String = tr(key)
	return parse(raw, vars_extra)


## Parses an already-localised string, replacing all variable markers.
## vars_extra: additional variables with higher priority than the global context.
##
## Example:
##   TextManager.parse("Hello, [player_name]! You have [money]₽.")
func parse(text: String, vars_extra: Dictionary = {}) -> String:
	var vars: Dictionary = _build_context(vars_extra)
	return _substitute(text, vars)

# ---------------------------------------------------------------------------
# Context building
# ---------------------------------------------------------------------------

func _build_context(extra: Dictionary) -> Dictionary:
	var ctx: Dictionary = {}

	# ── Player ──
	ctx["player_name"]  = PlayerData.trainer_name
	ctx["money"]        = format_number(PlayerData.money)
	ctx["play_time"]    = PlayerData.play_time_string()
	ctx["badge_count"]  = str(PlayerData.badge_count(0))
	ctx["seen_count"]   = str(PlayerData.pokedex_seen_count())
	ctx["caught_count"] = str(PlayerData.pokedex_caught_count())

	# ── Player's lead Pokémon ──
	if not PlayerData.party.is_empty():
		var lead: Pokemon          = PlayerData.party[0]
		ctx["lead_pokemon"]        = lead.full_name()
		ctx["lead_pokemon_level"]  = str(lead.level)
		ctx["lead_pokemon_hp"]     = str(lead.current_hp)
		ctx["lead_pokemon_maxhp"]  = str(lead.max_hp())
	else:
		ctx["lead_pokemon"]       = ""
		ctx["lead_pokemon_level"] = "1"
		ctx["lead_pokemon_hp"]    = "0"
		ctx["lead_pokemon_maxhp"] = "1"

	# ── Battle context ──
	ctx.merge(battle_context)

	# ── Event context ──
	ctx.merge(event_context)

	# ── Extra variables (highest priority) ──
	ctx.merge(extra, true)

	return ctx


## Replaces all [key] markers in the text with values from the dictionary.
func _substitute(text: String, vars: Dictionary) -> String:
	var result: String = text
	for key: String in vars:
		result = result.replace("[%s]" % key, str(vars[key]))
	return result

# ---------------------------------------------------------------------------
# Value formatting
# ---------------------------------------------------------------------------

## Formats a large number with a thousands separator appropriate to the locale.
## e.g. 9999999 → "9,999,999" (en) or "9.999.999" (es)
func format_number(n: int) -> String:
	var sep: String    = "." if current_locale.begins_with("es") else ","
	var s: String      = str(abs(n))
	var result: String = ""
	var count: int     = 0
	for i: int in range(s.length() - 1, -1, -1):
		if count > 0 and count % 3 == 0:
			result = sep + result
		result = s[i] + result
		count += 1
	return ("-" if n < 0 else "") + result


## Formats a Pokémon stat value with colour based on its stage modifier.
## Intended for use with RichTextLabel BBCode.
func format_stat(value: int, stage: int) -> String:
	if stage > 0:
		return "[color=green]%d[/color]" % value
	elif stage < 0:
		return "[color=red]%d[/color]" % value
	return str(value)


## Returns a localised string for a type effectiveness multiplier.
func format_effectiveness(multiplier: float) -> String:
	match multiplier:
		0.0:  return tr("EFF_IMMUNE")     # "It doesn't affect…"
		0.25: return tr("EFF_QUARTER")    # "It's not very effective…"
		0.5:  return tr("EFF_HALF")       # "It's not very effective…"
		2.0:  return tr("EFF_DOUBLE")     # "It's super effective!"
		4.0:  return tr("EFF_QUADRUPLE")  # "It's super effective!"
		_:    return ""


## Returns the display name of a Pokémon, using its nickname if it has one.
## If show_species=true, formats as "Nickname (Species)" when a nickname exists.
func format_pokemon_name(pokemon: Dictionary, show_species := false) -> String:
	var species_id:   String = pokemon.get("species_id", "")
	var species_name: String = GameData.species(species_id).get("name", species_id)
	var nickname:     String = pokemon.get("nickname", "")

	if nickname.is_empty() or nickname == species_name:
		return species_name
	if show_species:
		return "%s (%s)" % [nickname, species_name]
	return nickname


## Returns the correct possessive form of a name for the active locale.
func possessive(name: String, _gender: int) -> String:
	# English: append 's
	return name + "'s"


## Returns the appropriate definite article for a Pokémon based on gender.
func article(gender: int, plural := false) -> String:
	match current_locale:
		"es":
			if plural: return "los" if gender == 0 else "las"
			return "el" if gender == 0 else "la"
		_:
			return "the"

# ---------------------------------------------------------------------------
# String utilities
# ---------------------------------------------------------------------------

## Capitalises only the first letter of a string.
func capitalize_first(s: String) -> String:
	if s.is_empty():
		return s
	return s[0].to_upper() + s.substr(1)


## Truncates a string to max_len characters, appending "…" if necessary.
func truncate(s: String, max_len: int) -> String:
	if s.length() <= max_len:
		return s
	return s.left(max_len - 1) + "…"


## Strips BBCode markup from a string to produce plain text.
## e.g. "[color=red]Hello[/color]" → "Hello"
func strip_bbcode(s: String) -> String:
	var regex := RegEx.new()
	regex.compile("\\[.*?\\]")
	return regex.sub(s, "", true)
