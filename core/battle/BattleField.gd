## BattleField
## The shared arena state for an entire battle.
## Holds weather, terrain, room effects, gravity, turn counter,
## per-side hazards and screens, and the Combatant grid.
##
## Index convention for side arrays:
##   0 = Combatant.Side.PLAYER
##   1 = Combatant.Side.ENEMY
##
## Usage:
##   var field: BattleField = BattleField.new()
##   field.add_combatant(player_slot)
##   field.set_weather(BattleField.Weather.RAIN, 5)
##   field.tick()
##   var multiplier: float = field.weather_speed_multiplier()
class_name BattleField
extends RefCounted

# ---------------------------------------------------------------------------
# Enumerations
# ---------------------------------------------------------------------------

## Active weather condition.
enum Weather {
	NONE,
	SUNNY,         ## Harsh sunlight — boosts Fire, weakens Water
	RAIN,          ## Rain — boosts Water, weakens Fire
	SANDSTORM,     ## Damages non-Rock/Ground/Steel each turn
	HAIL,          ## Damages non-Ice each turn
	HEAVY_RAIN,    ## Primal Kyogre — cannot use Fire moves
	HARSH_SUN,     ## Primal Groudon — cannot use Water moves
	STRONG_WINDS,  ## Delta Stream — Flying-type takes neutral damage
}

## Active terrain condition (Gen 6+).
enum Terrain {
	NONE,
	ELECTRIC,  ## Boosts Electric moves; prevents sleep
	GRASSY,    ## Boosts Grass moves; restores HP each turn
	MISTY,     ## Halves Dragon damage; prevents status on grounded Pokémon
	PSYCHIC,   ## Boosts Psychic moves; prevents priority moves on grounded Pokémon
}

# ---------------------------------------------------------------------------
# Weather
# ---------------------------------------------------------------------------

var weather: Weather = Weather.NONE

## Turns of weather remaining. -1 = permanent (Desolate Land / Primordial Sea / Delta Stream).
var weather_turns: int = 0

# ---------------------------------------------------------------------------
# Terrain
# ---------------------------------------------------------------------------

var terrain: Terrain = Terrain.NONE

## Turns of terrain remaining. -1 = permanent.
var terrain_turns: int = 0

# ---------------------------------------------------------------------------
# Room effects
# ---------------------------------------------------------------------------

## Trick Room — turn order is reversed (slower Pokémon act first).
var trick_room_turns: int = 0

## Wonder Room — Defense and Special Defense are swapped.
var wonder_room_turns: int = 0

## Magic Room — held items have no effect.
var magic_room_turns: int = 0

# ---------------------------------------------------------------------------
# Gravity
# ---------------------------------------------------------------------------

## Strong Gravity — grounds all Pokémon; halves accuracy of some moves.
var gravity_turns: int = 0

# ---------------------------------------------------------------------------
# Turn counter
# ---------------------------------------------------------------------------

## Number of turns completed since the battle started.
var turn_count: int = 0

# ---------------------------------------------------------------------------
# Per-side screens (index 0 = PLAYER, 1 = ENEMY)
# ---------------------------------------------------------------------------

## Reflect — halves physical damage to the side.
var reflect_turns: Array[int]       = [0, 0]

## Light Screen — halves special damage to the side.
var light_screen_turns: Array[int]  = [0, 0]

## Aurora Veil — halves both physical and special damage (requires Hail).
var aurora_veil_turns: Array[int]   = [0, 0]

## Mist — protects the side from stat-lowering moves.
var mist_turns: Array[int]          = [0, 0]

## Tailwind — doubles Speed for all Pokémon on the side.
var tailwind_turns: Array[int]      = [0, 0]

## Lucky Chant — prevents critical hits against the side.
var lucky_chant_turns: Array[int]   = [0, 0]

# ---------------------------------------------------------------------------
# Per-side entry hazards (index 0 = PLAYER, 1 = ENEMY)
# ---------------------------------------------------------------------------

## Stealth Rock — deals damage to Pokémon switching in (Rock-type effectiveness).
var stealth_rock: Array[bool]  = [false, false]

## Spikes — 1 / 2 / 3 layers; damages non-Flying / Levitate switch-ins.
var spikes: Array[int]         = [0, 0]

## Toxic Spikes — 1 layer poisons; 2 layers badly poisons switch-ins.
var toxic_spikes: Array[int]   = [0, 0]

## Sticky Web — lowers Speed of non-Flying / Levitate switch-ins.
var sticky_web: Array[bool]    = [false, false]

# ---------------------------------------------------------------------------
# Combatant grid
# ---------------------------------------------------------------------------

## combatants[side_index][slot_index] → Combatant
## Populated by add_combatant(); do not write directly.
var combatants: Array = [[], []]

# ---------------------------------------------------------------------------
# Combatant management
# ---------------------------------------------------------------------------

## Adds a Combatant to the correct side array.
func add_combatant(c: Combatant) -> void:
	var side_idx: int = int(c.side)
	combatants[side_idx].append(c)


## Returns the Combatant at the given side and slot, or null.
func combatant(side: Combatant.Side, slot: int) -> Combatant:
	var side_idx: int = int(side)
	var arr: Array  = combatants[side_idx]
	if slot < 0 or slot >= arr.size():
		return null
	return arr[slot]


## Returns all Combatants on the given side.
func side_combatants(side: Combatant.Side) -> Array:
	return combatants[int(side)]


## Returns all Combatants on the opposite side from `c`.
func opponents_of(c: Combatant) -> Array:
	var opp_side: int = 1 - int(c.side)
	return combatants[opp_side]


## Returns all Combatants on the same side as `c`, excluding `c` itself.
func allies_of(c: Combatant) -> Array:
	var result: Array = []
	for ally: Combatant in combatants[int(c.side)]:
		if ally != c:
			result.append(ally)
	return result


## Returns every Combatant on the field (both sides).
func all_combatants() -> Array:
	var result: Array = []
	result.append_array(combatants[0])
	result.append_array(combatants[1])
	return result

# ---------------------------------------------------------------------------
# Weather helpers
# ---------------------------------------------------------------------------

## Sets the weather and its duration.
## Pass turns = -1 for a permanent weather (Desolate Land / Primordial Sea / Delta Stream).
func set_weather(new_weather: Weather, turns: int) -> void:
	weather       = new_weather
	weather_turns = turns


## Clears the weather immediately.
func clear_weather() -> void:
	weather       = Weather.NONE
	weather_turns = 0


## Returns true if the given weather is currently active.
func has_weather(w: Weather) -> bool:
	return weather == w


## Returns true if any weather other than NONE is active.
func weather_active() -> bool:
	return weather != Weather.NONE

# ---------------------------------------------------------------------------
# Terrain helpers
# ---------------------------------------------------------------------------

## Sets the terrain and its duration (-1 = permanent).
func set_terrain(new_terrain: Terrain, turns: int) -> void:
	terrain       = new_terrain
	terrain_turns = turns


## Clears the terrain immediately.
func clear_terrain() -> void:
	terrain       = Terrain.NONE
	terrain_turns = 0


## Returns true if the given terrain is currently active.
func has_terrain(t: Terrain) -> bool:
	return terrain == t

# ---------------------------------------------------------------------------
# Side-condition helpers
# ---------------------------------------------------------------------------

## Returns true if Reflect is active on the given side.
func has_reflect(side: Combatant.Side) -> bool:
	return reflect_turns[int(side)] > 0


## Returns true if Light Screen is active on the given side.
func has_light_screen(side: Combatant.Side) -> bool:
	return light_screen_turns[int(side)] > 0


## Returns true if Aurora Veil is active on the given side.
func has_aurora_veil(side: Combatant.Side) -> bool:
	return aurora_veil_turns[int(side)] > 0


## Returns true if Mist is active on the given side.
func has_mist(side: Combatant.Side) -> bool:
	return mist_turns[int(side)] > 0


## Returns true if Tailwind is active on the given side.
func has_tailwind(side: Combatant.Side) -> bool:
	return tailwind_turns[int(side)] > 0


## Returns the physical damage multiplier from screens on the given side.
## Reflect halves it; Aurora Veil halves it (cannot stack).
func physical_screen_multiplier(side: Combatant.Side) -> float:
	if has_aurora_veil(side) or has_reflect(side):
		return 0.5
	return 1.0


## Returns the special damage multiplier from screens on the given side.
func special_screen_multiplier(side: Combatant.Side) -> float:
	if has_aurora_veil(side) or has_light_screen(side):
		return 0.5
	return 1.0


## Removes all entry hazards from the given side (Rapid Spin / Defog).
func clear_entry_hazards(side: Combatant.Side) -> void:
	var s: int         = int(side)
	stealth_rock[s]    = false
	spikes[s]          = 0
	toxic_spikes[s]    = 0
	sticky_web[s]      = false

# ---------------------------------------------------------------------------
# Room / gravity helpers
# ---------------------------------------------------------------------------

func trick_room_active() -> bool:
	return trick_room_turns > 0

func wonder_room_active() -> bool:
	return wonder_room_turns > 0

func magic_room_active() -> bool:
	return magic_room_turns > 0

func gravity_active() -> bool:
	return gravity_turns > 0

# ---------------------------------------------------------------------------
# Turn tick — call once at the end of each turn
# ---------------------------------------------------------------------------

## Decrements all active turn counters by 1.
## Does NOT handle expiry messages or effects — those belong in the battle engine.
func tick() -> void:
	turn_count += 1

	# Weather
	if weather_turns > 0:
		weather_turns -= 1
		if weather_turns == 0:
			weather = Weather.NONE

	# Terrain
	if terrain_turns > 0:
		terrain_turns -= 1
		if terrain_turns == 0:
			terrain = Terrain.NONE

	# Room effects
	if trick_room_turns  > 0: trick_room_turns  -= 1
	if wonder_room_turns > 0: wonder_room_turns -= 1
	if magic_room_turns  > 0: magic_room_turns  -= 1

	# Gravity
	if gravity_turns > 0: gravity_turns -= 1

	# Per-side screens and conditions
	for s: int in 2:
		if reflect_turns[s]      > 0: reflect_turns[s]      -= 1
		if light_screen_turns[s] > 0: light_screen_turns[s] -= 1
		if aurora_veil_turns[s]  > 0: aurora_veil_turns[s]  -= 1
		if mist_turns[s]         > 0: mist_turns[s]         -= 1
		if tailwind_turns[s]     > 0: tailwind_turns[s]     -= 1
		if lucky_chant_turns[s]  > 0: lucky_chant_turns[s]  -= 1
