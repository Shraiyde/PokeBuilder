## PlayerData
## Singleton that stores all persistent player data:
## trainer info, Pokémon party, bag, PC storage, Pokédex,
## badges, money, play time, and event variables.
##
## Equivalent to $Trainer + $PokemonBag + $PokemonStorage + $PokemonGlobal in PE.
##
## Data is initialised via new_game() and serialized / deserialized
## through SaveSystem.
##
## Usage:
##   PlayerData.money -= 500
##   PlayerData.add_to_party(my_pokemon)
##   PlayerData.bag_add("POTION", 3)
##   if PlayerData.has_badge(0, "BOULDER"): ...
extends Node

# ---------------------------------------------------------------------------
# Signals
# ---------------------------------------------------------------------------

signal money_changed(new_amount: int)
signal party_changed
signal bag_changed(item_id: String, new_count: int)
signal pokedex_updated(species_id: String)
signal badge_obtained(region: int, badge_id: String)
signal play_time_updated(seconds: int)

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

const MAX_PARTY_SIZE      := 6
const MAX_BOXES           := 32  ## PC storage boxes
const BOX_CAPACITY        := 30  ## Pokémon per box
const MAX_MONEY           := 9_999_999
const MAX_PHONE_CONTACTS  := 50

# ---------------------------------------------------------------------------
# Trainer data
# ---------------------------------------------------------------------------

var trainer_name:   String = ""  ## Player's name
var trainer_gender: int    = 0   ## 0 = male, 1 = female
var trainer_id:     int    = 0   ## Numeric trainer ID (16-bit)
var secret_id:      int    = 0   ## Secret ID (16-bit, used for shiny breeding)

var _money: int = 3000

var money: int:
	get: return _money
	set(v):
		_money = clamp(v, 0, MAX_MONEY)
		money_changed.emit(_money)

# ---------------------------------------------------------------------------
# Play time
# ---------------------------------------------------------------------------

var _play_time_seconds: int   = 0   ## Total seconds of play time
var _play_time_timer:   float = 0.0 ## Sub-second accumulator

func _process(delta: float) -> void:
	# Only counts time when the player is in control.
	if GameManager.is_player_in_control():
		_play_time_timer += delta
		if _play_time_timer >= 1.0:
			_play_time_seconds += int(_play_time_timer)
			_play_time_timer = fmod(_play_time_timer, 1.0)
			play_time_updated.emit(_play_time_seconds)


## Returns play time as a dictionary {hours, minutes, seconds}.
func play_time() -> Dictionary:
	var total: int = _play_time_seconds
	return {
		"hours":   total / 3600,
		"minutes": (total % 3600) / 60,
		"seconds": total % 60,
	}


## Returns play time formatted as "H:MM" (short=true) or "HH:MM:SS".
func play_time_string(short := true) -> String:
	var t: Dictionary = play_time()
	if short:
		return "%d:%02d" % [t.hours, t.minutes]
	return "%02d:%02d:%02d" % [t.hours, t.minutes, t.seconds]

# ---------------------------------------------------------------------------
# Pokémon party
# ---------------------------------------------------------------------------

## Up to 6 live Pokémon instances. Use PokemonFactory to create entries.
var party: Array[Pokemon] = []


## Adds a Pokémon to the party. If the party is full, sends it to the PC.
## Returns true if added to the party, false if sent to the PC.
func add_to_party(pokemon: Pokemon) -> bool:
	if party.size() < MAX_PARTY_SIZE:
		party.append(pokemon)
		party_changed.emit()
		return true
	# Party full: send to the first available PC slot
	send_to_box(pokemon, -1, -1)
	return false


## Removes a Pokémon from the party by index. Will not leave the party empty.
func remove_from_party(index: int) -> bool:
	if party.size() <= 1:
		push_warning("PlayerData: Cannot remove the last Pokémon from the party.")
		return false
	if index < 0 or index >= party.size():
		return false
	party.remove_at(index)
	party_changed.emit()
	return true


## Swaps the positions of two Pokémon in the party.
func swap_party(index_a: int, index_b: int) -> void:
	if index_a == index_b:
		return
	var tmp: Pokemon = party[index_a]
	party[index_a] = party[index_b]
	party[index_b] = tmp
	party_changed.emit()


## Returns true if at least one party Pokémon has HP remaining.
func has_conscious_pokemon() -> bool:
	return party.any(func(p: Pokemon) -> bool: return p.is_alive())

# ---------------------------------------------------------------------------
# PC storage (boxes)
# ---------------------------------------------------------------------------

## Array of MAX_BOXES boxes; each box is an Array of BOX_CAPACITY slots (null = empty).
var pc_boxes: Array = []

## Box display names.
var box_names: Array = []

## Box wallpaper indices (0–25).
var box_wallpapers: Array = []

## Index of the currently selected box in the PC.
var current_box: int = 0


func _init_boxes() -> void:
	pc_boxes.clear()
	box_names.clear()
	box_wallpapers.clear()
	for i: int in MAX_BOXES:
		pc_boxes.append([])
		pc_boxes[i].resize(BOX_CAPACITY)
		pc_boxes[i].fill(null)
		box_names.append("Box %d" % (i + 1))
		box_wallpapers.append(0)


## Sends a Pokémon to the PC. If box_index is -1, finds the first free slot.
## Returns {box, slot} with the stored position, or {} if the PC is full.
func send_to_box(pokemon: Pokemon, box_index := -1, slot_index := -1) -> Dictionary:
	if box_index == -1:
		# Search for the first free slot in any box
		for b: int in MAX_BOXES:
			for s: int in BOX_CAPACITY:
				if pc_boxes[b][s] == null:
					pc_boxes[b][s] = pokemon
					return {"box": b, "slot": s}
		push_warning("PlayerData: PC storage is full.")
		return {}

	# Specific slot
	if pc_boxes[box_index][slot_index] != null:
		push_warning("PlayerData: PC slot (%d, %d) is already occupied." % [box_index, slot_index])
		return {}
	pc_boxes[box_index][slot_index] = pokemon
	return {"box": box_index, "slot": slot_index}


## Removes a Pokémon from the PC and returns it (or null if the slot is empty).
func take_from_box(box_index: int, slot_index: int) -> Variant:
	var pkmn: Variant = pc_boxes[box_index][slot_index]
	pc_boxes[box_index][slot_index] = null
	return pkmn


## Returns the total number of Pokémon stored in the PC.
func pc_count() -> int:
	var count: int = 0
	for box: Array in pc_boxes:
		for slot: Variant in box:
			if slot != null:
				count += 1
	return count

# ---------------------------------------------------------------------------
# Bag
# ---------------------------------------------------------------------------

## Dictionary: item_id → quantity.
var bag: Dictionary = {}


## Adds `count` units of an item to the bag.
func bag_add(item_id: String, count := 1) -> void:
	bag[item_id] = bag.get(item_id, 0) + count
	bag_changed.emit(item_id, bag[item_id])


## Removes `count` units of an item. Returns false if there are not enough.
func bag_remove(item_id: String, count := 1) -> bool:
	var current: int = bag.get(item_id, 0)
	if current < count:
		return false
	current -= count
	if current == 0:
		bag.erase(item_id)
	else:
		bag[item_id] = current
	bag_changed.emit(item_id, current)
	return true


## Returns the quantity of an item in the bag.
func bag_count(item_id: String) -> int:
	return bag.get(item_id, 0)


## Returns true if the player has at least `count` units of the item.
func has_item(item_id: String, count := 1) -> bool:
	return bag_count(item_id) >= count

# ---------------------------------------------------------------------------
# Pokédex
# ---------------------------------------------------------------------------

## Species IDs the player has seen.
var pokedex_seen: Dictionary = {}    ## species_id → true

## Species IDs the player has caught (or received).
var pokedex_caught: Dictionary = {}  ## species_id → true


func register_seen(species_id: String) -> void:
	if not pokedex_seen.has(species_id):
		pokedex_seen[species_id] = true
		pokedex_updated.emit(species_id)


func register_caught(species_id: String) -> void:
	register_seen(species_id)
	if not pokedex_caught.has(species_id):
		pokedex_caught[species_id] = true
		pokedex_updated.emit(species_id)


func has_seen(species_id: String) -> bool:
	return pokedex_seen.has(species_id)


func has_caught(species_id: String) -> bool:
	return pokedex_caught.has(species_id)


func pokedex_seen_count() -> int:
	return pokedex_seen.size()


func pokedex_caught_count() -> int:
	return pokedex_caught.size()

# ---------------------------------------------------------------------------
# Badges
# ---------------------------------------------------------------------------

## Badges per region: region_index → Array[String] (badge_ids).
var badges: Dictionary = {}


## Records a badge being obtained.
func add_badge(region: int, badge_id: String) -> void:
	if not badges.has(region):
		badges[region] = []
	if badge_id not in badges[region]:
		badges[region].append(badge_id)
		badge_obtained.emit(region, badge_id)


func has_badge(region: int, badge_id: String) -> bool:
	return badges.has(region) and badge_id in badges[region]


func badge_count(region: int) -> int:
	return badges.get(region, []).size()

# ---------------------------------------------------------------------------
# Event variables (equivalent to $game_switches and $game_variables in RMXP)
# ---------------------------------------------------------------------------

## Boolean switches: id → bool
var switches: Dictionary = {}

## Numeric / string variables: id → Variant
var variables: Dictionary = {}

## Local event self-switches: {map_id, event_id, key} → bool
var self_switches: Dictionary = {}


func switch_on(id: int) -> void:   switches[id] = true
func switch_off(id: int) -> void:  switches[id] = false
func get_switch(id: int) -> bool:  return switches.get(id, false)

func set_variable(id: int, value: Variant) -> void: variables[id] = value
func get_variable(id: int, default: Variant = 0) -> Variant: return variables.get(id, default)

func set_self_switch(map_id: int, event_id: int, key: String, value: bool) -> void:
	self_switches[[map_id, event_id, key]] = value

func get_self_switch(map_id: int, event_id: int, key: String) -> bool:
	return self_switches.get([map_id, event_id, key], false)

# ---------------------------------------------------------------------------
# Phone contacts
# ---------------------------------------------------------------------------

## Array of dictionaries: {trainer_type, trainer_name, map_id}
var phone_contacts: Array = []


func add_phone_contact(trainer_type: String, trainer_name: String, map_id: int) -> void:
	for c: Dictionary in phone_contacts:
		if c.trainer_type == trainer_type and c.trainer_name == trainer_name:
			return  # Already registered
	if phone_contacts.size() < MAX_PHONE_CONTACTS:
		phone_contacts.append({
			"trainer_type": trainer_type,
			"trainer_name": trainer_name,
			"map_id":       map_id,
		})


func has_phone_contact(trainer_type: String, trainer_name: String) -> bool:
	return phone_contacts.any(func(c: Dictionary) -> bool: return c.trainer_type == trainer_type and c.trainer_name == trainer_name)

# ---------------------------------------------------------------------------
# Player map position
# ---------------------------------------------------------------------------

var map_id:    int = 1  ## Current map ID
var map_x:     int = 0  ## X position in tiles
var map_y:     int = 0  ## Y position in tiles
var direction: int = 2  ## Direction (2=S, 4=W, 6=E, 8=N)

# ---------------------------------------------------------------------------
# New game initialisation
# ---------------------------------------------------------------------------

## Resets all data for a new game.
func new_game() -> void:
	trainer_name   = ""
	trainer_gender = 0
	trainer_id     = randi() % 65536
	secret_id      = randi() % 65536
	money          = GameManager.game_meta.get("start_money", 3000)

	party.clear()
	_init_boxes()
	bag.clear()
	pokedex_seen.clear()
	pokedex_caught.clear()
	badges.clear()
	switches.clear()
	variables.clear()
	self_switches.clear()
	phone_contacts.clear()

	map_id    = GameManager.game_meta.get("start_map", 1)
	map_x     = GameManager.game_meta.get("start_x",  7)
	map_y     = GameManager.game_meta.get("start_y",  5)
	direction = GameManager.game_meta.get("start_dir", 2)

	_play_time_seconds = 0
	_play_time_timer   = 0.0

# ---------------------------------------------------------------------------
# Serialisation (used by SaveSystem)
# ---------------------------------------------------------------------------

## Returns all player data as a serializable Dictionary.
func serialize() -> Dictionary:
	return {
		"trainer_name":   trainer_name,
		"trainer_gender": trainer_gender,
		"trainer_id":     trainer_id,
		"secret_id":      secret_id,
		"money":          money,
		"play_time":      _play_time_seconds,
		"party":          _serialize_party(),
		"pc_boxes":       _serialize_pc_boxes(),
		"box_names":      box_names.duplicate(),
		"box_wallpapers": box_wallpapers.duplicate(),
		"current_box":    current_box,
		"bag":            bag.duplicate(),
		"pokedex_seen":   pokedex_seen.duplicate(),
		"pokedex_caught": pokedex_caught.duplicate(),
		"badges":         badges.duplicate(true),
		"switches":       switches.duplicate(),
		"variables":      variables.duplicate(),
		"self_switches":  _serialize_self_switches(),
		"phone_contacts": phone_contacts.duplicate(true),
		"map_id":         map_id,
		"map_x":          map_x,
		"map_y":          map_y,
		"direction":      direction,
	}


func _serialize_party() -> Array:
	var result: Array = []
	for pk: Pokemon in party:
		result.append(pk.serialize())
	return result


func _serialize_pc_boxes() -> Array:
	var result: Array = []
	for box: Array in pc_boxes:
		var box_data: Array = []
		for slot: Variant in box:
			if slot is Pokemon:
				box_data.append(slot.serialize())
			else:
				box_data.append(null)
		result.append(box_data)
	return result


## Restores player data from a serialized Dictionary.
func deserialize(data: Dictionary) -> void:
	trainer_name       = data.get("trainer_name",   "")
	trainer_gender     = data.get("trainer_gender", 0)
	trainer_id         = data.get("trainer_id",     0)
	secret_id          = data.get("secret_id",      0)
	money              = data.get("money",          3000)
	_play_time_seconds = data.get("play_time",      0)

	_deserialize_party(data.get("party", []))
	_deserialize_pc_boxes(data.get("pc_boxes", []))

	box_names      = data.get("box_names",      []).duplicate()
	box_wallpapers = data.get("box_wallpapers", []).duplicate()
	current_box    = data.get("current_box",    0)
	bag            = data.get("bag",            {}).duplicate()
	pokedex_seen   = data.get("pokedex_seen",   {}).duplicate()
	pokedex_caught = data.get("pokedex_caught", {}).duplicate()
	badges         = data.get("badges",         {}).duplicate(true)
	switches       = data.get("switches",       {}).duplicate()
	variables      = data.get("variables",      {}).duplicate()
	phone_contacts = data.get("phone_contacts", []).duplicate(true)
	map_id         = data.get("map_id",         1)
	map_x          = data.get("map_x",          0)
	map_y          = data.get("map_y",          0)
	direction      = data.get("direction",      2)

	_deserialize_self_switches(data.get("self_switches", {}))

	# Ensure the PC has the correct number of boxes (save format compatibility)
	if pc_boxes.size() < MAX_BOXES:
		_init_boxes()


func _deserialize_party(party_data: Array) -> void:
	party.clear()
	for d: Variant in party_data:
		if d is Dictionary:
			party.append(PokemonFactory.restore(d))


func _deserialize_pc_boxes(boxes_data: Array) -> void:
	pc_boxes.clear()
	for box_data: Variant in boxes_data:
		var box: Array = []
		box.resize(BOX_CAPACITY)
		box.fill(null)
		if box_data is Array:
			for i: int in mini(box_data.size(), BOX_CAPACITY):
				var slot: Variant = box_data[i]
				if slot is Dictionary:
					box[i] = PokemonFactory.restore(slot)
		pc_boxes.append(box)


## Self-switch keys are Arrays, which do not serialise well to JSON.
## They are converted to the String "map_id,event_id,key".
func _serialize_self_switches() -> Dictionary:
	var result: Dictionary = {}
	for key: Array in self_switches:
		result["%d,%d,%s" % [key[0], key[1], key[2]]] = self_switches[key]
	return result


func _deserialize_self_switches(data: Dictionary) -> void:
	self_switches.clear()
	for k: String in data:
		var parts: Array = k.split(",")
		if parts.size() == 3:
			self_switches[[parts[0].to_int(), parts[1].to_int(), parts[2]]] = data[k]
