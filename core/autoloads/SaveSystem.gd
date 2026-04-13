## SaveSystem
## Singleton that serialises and deserialises the complete game state.
## Supports multiple save slots and detects corrupted files.
##
## Format: JSON compressed with FileAccess (Zstd).
## Files are stored at user://saves/slot_N.sav
##
## Usage:
##   SaveSystem.save(0)                  # Save to slot 0
##   var ok = SaveSystem.load_game(0)    # Load slot 0
##   var info = SaveSystem.slot_info(0)  # Read metadata without loading the full save
extends Node

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

const SAVE_DIR     := "user://saves/"
const SAVE_EXT     := ".sav"
const MAX_SLOTS    := 3
const SAVE_VERSION := 1  ## Save format version for forward-compatibility

# ---------------------------------------------------------------------------
# Signals
# ---------------------------------------------------------------------------

signal save_started(slot: int)
signal save_completed(slot: int)
signal save_failed(slot: int, reason: String)

signal load_started(slot: int)
signal load_completed(slot: int)
signal load_failed(slot: int, reason: String)

# ---------------------------------------------------------------------------
# Lifecycle
# ---------------------------------------------------------------------------

func _ready() -> void:
	_ensure_save_dir()

# ---------------------------------------------------------------------------
# Save
# ---------------------------------------------------------------------------

## Saves the game to the given slot (0 to MAX_SLOTS-1).
## Returns true if the save was successful.
func save(slot: int) -> bool:
	if not _valid_slot(slot):
		return false

	save_started.emit(slot)

	var data: Dictionary    = _collect_save_data(slot)
	var json_str: String    = JSON.stringify(data)
	var path: String        = _slot_path(slot)
	var file: FileAccess    = FileAccess.open_compressed(path, FileAccess.WRITE, FileAccess.COMPRESSION_ZSTD)
	if not file:
		var reason: String = "Could not open '%s' for writing (error %d)" % [path, FileAccess.get_open_error()]
		push_error("SaveSystem: " + reason)
		save_failed.emit(slot, reason)
		return false

	file.store_string(json_str)
	file.close()

	save_completed.emit(slot)
	return true


## Collects all data to save into a single serialisable Dictionary.
func _collect_save_data(slot: int) -> Dictionary:
	return {
		"_version":  SAVE_VERSION,
		"_slot":     slot,
		"_date":     Time.get_datetime_string_from_system(),
		"player":    PlayerData.serialize(),
		"settings":  GameManager.settings.duplicate(),
		"features":  GameManager.features.duplicate(),
		"map_state": _collect_map_state(),
	}


## Placeholder: the map system will populate this when implemented.
func _collect_map_state() -> Dictionary:
	return {}

# ---------------------------------------------------------------------------
# Load
# ---------------------------------------------------------------------------

## Loads the game from the given slot.
## Returns true if the load was successful.
func load_game(slot: int) -> bool:
	if not _valid_slot(slot):
		return false

	load_started.emit(slot)

	var path: String = _slot_path(slot)
	if not FileAccess.file_exists(path):
		var reason: String = "Save file '%s' does not exist." % path
		load_failed.emit(slot, reason)
		return false

	var file: FileAccess = FileAccess.open_compressed(path, FileAccess.READ, FileAccess.COMPRESSION_ZSTD)
	if not file:
		var reason: String = "Could not open '%s' for reading (error %d)" % [path, FileAccess.get_open_error()]
		push_error("SaveSystem: " + reason)
		load_failed.emit(slot, reason)
		return false

	var json_str: String = file.get_as_text()
	file.close()

	var parsed: Variant = JSON.parse_string(json_str)
	if parsed == null:
		var reason: String = "File '%s' is corrupted or not valid JSON." % path
		push_error("SaveSystem: " + reason)
		load_failed.emit(slot, reason)
		return false

	var data: Dictionary = parsed

	# Format version check
	var version: int = data.get("_version", 0)
	if version != SAVE_VERSION:
		push_warning("SaveSystem: Save version %d, expected %d. Attempting migration..." % [version, SAVE_VERSION])
		data = _migrate(data, version)

	# Restore data
	if data.has("player"):
		PlayerData.deserialize(data["player"])
	if data.has("settings"):
		GameManager.load_settings(data["settings"])
	if data.has("features"):
		GameManager.load_features(data["features"])

	load_completed.emit(slot)
	return true

# ---------------------------------------------------------------------------
# Slot info (without loading the full save)
# ---------------------------------------------------------------------------

## Returns slot metadata without loading the full save:
##   {exists, date, trainer_name, play_time, badge_count, version}
## Returns {exists: false} if the slot is empty.
func slot_info(slot: int) -> Dictionary:
	if not _valid_slot(slot):
		return {"exists": false}

	var path: String = _slot_path(slot)
	if not FileAccess.file_exists(path):
		return {"exists": false}

	var file: FileAccess = FileAccess.open_compressed(path, FileAccess.READ, FileAccess.COMPRESSION_ZSTD)
	if not file:
		return {"exists": false, "corrupted": true}

	var json_str: String = file.get_as_text()
	file.close()

	var parsed: Variant = JSON.parse_string(json_str)
	if parsed == null:
		return {"exists": true, "corrupted": true}

	var data: Dictionary   = parsed
	var player: Dictionary = data.get("player", {})

	# Count total badges across all regions
	var badge_total: int = 0
	for region_badges: Array in player.get("badges", {}).values():
		badge_total += region_badges.size()

	return {
		"exists":       true,
		"corrupted":    false,
		"version":      data.get("_version", 0),
		"date":         data.get("_date", ""),
		"trainer_name": player.get("trainer_name", ""),
		"play_time":    player.get("play_time", 0),
		"badge_count":  badge_total,
	}


## Returns true if a save exists in the given slot.
func slot_exists(slot: int) -> bool:
	return slot_info(slot).get("exists", false)

# ---------------------------------------------------------------------------
# Delete slot
# ---------------------------------------------------------------------------

## Deletes the save file for the given slot.
func delete_slot(slot: int) -> bool:
	if not _valid_slot(slot):
		return false
	var path: String = _slot_path(slot)
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(path)
		return true
	return false

# ---------------------------------------------------------------------------
# Version migration
# ---------------------------------------------------------------------------

## Applies migrations when the save format changes between versions.
func _migrate(data: Dictionary, from_version: int) -> Dictionary:
	# Add migrations here as the format evolves:
	# if from_version < 2: data = _migrate_v1_to_v2(data)
	push_warning("SaveSystem: No migration available from v%d to v%d." % [from_version, SAVE_VERSION])
	return data

# ---------------------------------------------------------------------------
# Private helpers
# ---------------------------------------------------------------------------

func _slot_path(slot: int) -> String:
	return SAVE_DIR + "slot_%d" % slot + SAVE_EXT


func _valid_slot(slot: int) -> bool:
	if slot < 0 or slot >= MAX_SLOTS:
		push_error("SaveSystem: Slot %d is out of range (0–%d)." % [slot, MAX_SLOTS - 1])
		return false
	return true


func _ensure_save_dir() -> void:
	if not DirAccess.dir_exists_absolute(SAVE_DIR):
		DirAccess.make_dir_recursive_absolute(SAVE_DIR)
